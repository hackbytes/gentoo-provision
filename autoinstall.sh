#!/bin/sh
# Licensed under GPL-3
#
# Sets the environment variable based on kernel boot paramters. This is used for
# determing whether a node is a KVM host or guest, as the kernel is configured
# differently for each.
#
# There are several states that this script keeps track of. Each state is
# executed after each reboot that occurs during provisioning. The states are as
# follows:
#
# - PREDISK - In this state, the provision script is being executed from the
# ramdisk. The script must create and format the disk partitions and mount them.
# The script is then copied onto the persistent disk and this state is complete.
#
# - POSTDISK - In this state, the provision script is being executed from the
# actual hard drive via the mounts

# Install selinux?
INSTALL_SELINUX=0
INSTALL_CONFIGURE=0

source ./helpers/common.lib.sh;

# The absolute path the program is stored in within the livedisk's filesystem.
# This is a read-only filesystem (image.squashfs) so we need to move it to
# temporary disk in order to run the disk partitioning setup. Then we need to
# move the program to the hard disk to keep track of states!
WORKDIR="/mnt/livecd/autoinstall"
# TODO: Set this to match the workdir of the proper config file so that we don't
# have to dupe and keep track of this value in 2 different configs.
#
# The destination this program will install itself in within the persistent
# storage media relative to being booted into the live cd
DESTDIR="/mnt/gentoo/autoinstall"
# The final destination directory once booted into the hard drive. This is used
# if further installations are configured (eg. selinux)
FINALDESTDIR="/autoinstall"
# the call to this script takes provision type as an argument (host or guest)
PROVISION="$1"
TMPDIR="/autoinstall"

# If workdir does not exist, it means the autoinstall was not provided via a 
# modded boot image. Therefore, the autoinstall script was already uploaded to 
# the root dir (/autoinstall) by other means (eg. packer).
if [ ! -e "${WORKDIR}" ];
then
  WORKDIR=""
fi

# Trap for when the program is killed. Just displays a message.
trap 'message_error "\n\nAutoinstall aborted\n"; exit' SIGINT SIGTERM

# States
PREDISKSTATE=0
POSTDISKSTATE=1
SELINUXASTATE=2
SELINUXBSTATE=3
SELINUXCSTATE=4
CONFIGURESTATE=0
FINISHEDSTATE=6

# State files
predisk_statefile="install-kernel.sh"
postdisk_statefile=".state-postdisk"
selinuxa_statefile=".state-selinuxa"
selinuxb_statefile=".state-selinuxb"
selinuxc_statefile=".state-selinuxc"
configure_statefile=".state-configure"
finished_statefile=".state-finished"

# Only needed when we are not booted into the main hard drive as root.
function mount_disks () {
  # Determine the proper configuration to use.
  if [ -n "$PROVISION" ];
  then
    printf "Mounting disks for KVM ${PROVISION} provisioning program...\n"
    /bin/sh install-kernel.sh configs/gentoo.${PROVISION}.conf mount mount
  else
    printf "Provision type not passed as kernel parameter (provision=TYPE).\n"
    printf "Aborting provision.\n"
    exit 1;
  fi
}

# partitions disk, creates filesystems and lvs. does not reboot.
function run_predisk_phase () {
  if [ -e "${WORKDIR}" ];
  then
    # FIRST COPY PROGRAM TO RAMDISK TMPDIR SO IT CAN CREATE THE PARTITIONS
    # rsync slash == copy contents into dest as opposed to copy folder into dest
    rsync -avug $WORKDIR/ $TMPDIR
  fi

  cd $TMPDIR;

  # Determine the proper configuration to use and run the script from the
  # writeable TMPDIR. This is volatile, so we're gonna have to move the program
  # to the persistent drive after creating the partitions.
  if [ -n "$PROVISION" ];
  then
    printf "Injecting KVM ${PROVISION} provisioning program into hard drive...\n"
    /bin/sh install-kernel.sh configs/gentoo.${PROVISION}.conf disk mount
  else
    printf "Provision type not passed as kernel parameter (provision=TYPE).\n"
    printf "Aborting provision.\n"
    exit 1;
  fi

  # Once the file systems are created and mounted, rsync the autoinstall scripts
  # to the persistent drive. Now we can keep track of states!
  # rsync slash == copy contents into dest as opposed to copy folder into dest
  rsync -avug $TMPDIR/ $DESTDIR
}

# installs kernel and bootloader to the hard disk. does not reboot.
function run_postdisk_phase () {
  # Determine the proper configuration to use.
  if [ -n "$PROVISION" ];
  then
    printf "Running KVM ${PROVISION} provisioning program...\n"
    /bin/sh install-kernel.sh configs/gentoo.${PROVISION}.conf extract cleanup
  else
    printf "Provision type not passed as kernel parameter (provision=TYPE).\n"
    printf "Aborting provision.\n"
    exit 1;
  fi
}

# Injects autoinstallation of the setup scripts (the same local.d startup script
# used to begin autoinstall from the livecd).
function inject_startup_program () {
  # Injection only currently works if using a bootmodded image.
  # TODO: find an alternate/better solution for situations where a bootmodded 
  # image is not used (eg. packer)
  if [ -e "${WORKDIR}" ];
  then
    src_program_path="/etc/local.d/00provision.start";
    dest_program_path="/mnt/gentoo/etc/local.d/00provision.start";
    cp -f $src_program_path $dest_program_path;
    # Change path of program to execute
    sed -i 's:/mnt/livecd/autoinstall:/autoinstall:g' $dest_program_path;
  fi
}

function run_selinuxa_phase () {
  printf "Running KVM host provisioning program...\n"
  /bin/sh install-selinux.sh mountcontext selinux
}

function run_selinuxb_phase () {
  printf "Running KVM host provisioning program...\n"
  /bin/sh install-selinux.sh label label
}

function run_selinuxc_phase () {
  printf "Running KVM host provisioning program...\n"
  /bin/sh install-selinux.sh booleans booleans
}

function run_configure_phase () {
  printf "Running configuration management program...\n"
  /bin/sh configure.sh
}

function run_finished_phase () {
  printf "Cleaning up installation files...\n";
  rm -rf $FINALDESTDIR
  rm -f /etc/local.d/00provision.start
}

function run_state_check () {

  # The predisk state is only BEFORE the program has been copied, so the only
  # check is to see if the progran is accessible.
  if [ -f "$WORKDIR/$predisk_statefile" ];
  then
    state=$PREDISKSTATE;
  # also check the tmpdir in case the autoinstall scripts are uploaded (and not 
  # through a modded boot image)
  elif [ -f "$TMPDIR/$predisk_statefile" ];
  then
    state=$PREDISKSTATE;
  fi
  # Determine state based on the existence of state files. Both directories need
  # to bec checked because this autoinstall script will be executed both during a
  # livecd-type mount AND after installation during the typical hard-drive mount
  if [ -f "$DESTDIR/$postdisk_statefile" ] || [ -f "$FINALDESTDIR/$postdisk_statefile" ];
  then
    state=$POSTDISKSTATE;
  fi
  if [ -f "$DESTDIR/$selinuxa_statefile" ] || [ -f "$FINALDESTDIR/$selinuxa_statefile" ];
  then
    state=$SELINUXASTATE
  fi
  if [ -f "$DESTDIR/$selinuxb_statefile" ] || [ -f "$FINALDESTDIR/$selinuxb_statefile" ];
  then
    state=$SELINUXBSTATE
  fi
  if [ -f "$DESTDIR/$selinuxc_statefile" ] || [ -f "$FINALDESTDIR/$selinuxc_statefile" ];
  then
    state=$SELINUXCSTATE
  fi
  if [ -f "$DESTDIR/$configure_statefile" ] || [ -f "$FINALDESTDIR/$configure_statefile" ];
  then
    state=$CONFIGURESTATE
  fi
  if [ -f "$DESTDIR/$finished_statefile" ] || [ -f "$FINALDESTDIR/$finished_statefile" ];
  then
    state=$FINISHEDSTATE
  fi
}

# run first state check
run_state_check;

message ">>> Running gentoo installation for node on the niteLite.io network...\n\n";

message ">>> Waiting 10 seconds before starting...\n";
# TODO: See if there is a way to signal a kill for a local.d script. Right now, 
# this doesn't work :(
message ">>> (Control-C to abort)...\n";
message ">>> Performing autoinstall in:"; countdown 10;

message ">>> Performing autoinstall...\n\n"

# EXECUTED FROM ramfs /autoinstall
# Run the appropriate commands based on the current state.
if [ "$state" = $PREDISKSTATE ];
then
  # this phase will create the and format the partions. Prior to this, the
  # persistent file systems cannot be mounted.
  message ">>> Starting PREDISK phase...\n\n"
  run_predisk_phase;

  touch $DESTDIR/$postdisk_statefile;

  run_state_check;
fi

# EXECUTED FROM hard disk /mnt/gentoo/autoinstall
# TODO: run a check before switching to the dir for all these.
cd $DESTDIR;
if [ "$state" = $POSTDISKSTATE ];
then
  message ">>> Starting POSTDISK phase...\n\n"
  run_postdisk_phase;

  # Inject the startup program into the hard disk prior to running the kernel
  # install so that on restart, the rest of the process can take place.
  inject_startup_program;
  touch $selinuxa_statefile;

  # Now we can unmount
  if [ -n "$PROVISION" ];
  then
    /bin/sh install-kernel.sh configs/gentoo.${PROVISION}.conf umount umount
  else
    printf "Provision type not passed as kernel parameter (provision=TYPE).\n"
    printf "Aborting provision.\n"
    exit 1;
  fi

  run_state_check;

  # The reboot happens regardless of whether or not further setup is needed. The
  # installed startup script will invoke cleanup (this script).
  reboot;
fi

if [ "$INSTALL_SELINUX" = 0 ];
then
  message ">>> Skipping selinux setup...\n\n"
  touch $FINALDESTDIR/$selinuxb_statefile;
  touch $FINALDESTDIR/$selinuxc_statefile;
  run_state_check;
fi

if [ "$INSTALL_CONFIGURE" = 0 ];
then
  message ">>> Skipping configuration step...\n\n"
  touch $FINALDESTDIR/$configure_statefile;
  touch $FINALDESTDIR/$finished_statefile;
  run_state_check;
fi

# EXECUTED FROM hard disk /autoinstall
cd $FINALDESTDIR;
if [ "$state" = $SELINUXASTATE ];
then
  message ">>> Starting SELINUXA phase...\n\n"
  run_selinuxa_phase;

  # signal transition to next state
  touch $selinuxb_statefile;

  run_state_check;
  reboot;
fi

# EXECUTED FROM hard disk /autoinstall
cd $FINALDESTDIR;
if [ "$state" = $SELINUXBSTATE ];
then
  message ">>> Starting SELINUXB phase...\n\n"
  run_selinuxb_phase;

  # signal transition to next state
  touch $selinuxc_statefile;

  run_state_check;
  reboot;
fi

# EXECUTED FROM hard disk /autoinstall
cd $FINALDESTDIR;
if [ "$state" = $SELINUXCSTATE ];
then
  message ">>> Starting SELINUXC phase...\n\n"
  run_selinuxc_phase;

  touch $configure_statefile;

  run_state_check;
fi

# EXECUTED FROM hard disk /autoinstall
cd $FINALDESTDIR;
if [ "$state" = $CONFIGURESTATE ];
then
  message ">>> Starting CONFIGURE phase...\n\n"
  run_configure_phase;

  touch $finished_statefile;

  run_state_check;
fi


# EXECUTED FROM hard disk /autoinstall
cd $FINALDESTDIR;

# EXECUTED FROM hard disk /autoinstall
if [ "$state" = $FINISHEDSTATE ];
then
  message ">>> Starting FINISHED phase...\n\n"
  run_finished_phase;
  run_state_check;
fi

