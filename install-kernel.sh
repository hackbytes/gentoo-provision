#!/bin/sh
# Licensed under GPL-3
#
# The base gentoo installation.

SCRIPTDIR="`pwd`"

DATA=$1;
echo "${DATA}" | grep '^/' > /dev/null 2>&1;
if [ $? -ne 0 ];
then
  DATA="$(pwd)/${DATA}";
fi

STEPS=" disk mount extract setup configure tools bootloader kernel umount reboot"

# Error handling
if [ ! -f "${DATA}" ];
then
  echo "Usage: $0 <datafile> [<stepfrom> [<stepto>]]";
  echo "";
  echo "If <stepto> is given, the step itself is also executed.";
  echo "Supported steps: ${STEPS}";
  exit 1;
fi

source ./master.lib.sh;
# initTools;

##
## Global variables
##

cat ${DATA} | grep -v '^#' | sed -e 's:#.*::g' > ${DATA}.parsed;
DATA=${DATA}.parsed;
CONFFILE=${DATA};

STEPFROM=$2;
STEPTO=$3

LOG=$(awk -F'=' '/logfile/ {print $2}' ${DATA});
WORKDIR=$(awk -F'=' '/workdir/ {print $2}' ${DATA});
WORKDIR=$(echo ${WORKDIR} | sed -e 's:/$::g');
FAILED=$(mktemp);

# Empty log file
[ -f ${LOG}.2 ] && rm -f ${LOG}.2;
[ -f ${LOG}.1 ] && mv ${LOG}.1 ${LOG}.2;
[ -f ${LOG} ] && mv -f ${LOG} ${LOG}.1;

##
## Helper commands
##

runChrootCommand() {
  chroot ${WORKDIR} sh -c "source /etc/profile; $*";
};

logPrint() {
  echo ">>> $(date +%Y%m%d-%H%M%S): $*";
}

updateEtcConfFile() {
  SECTION="$1";
  LASTSECTION=$(echo ${SECTION} | awk -F'.' '{print $NF}');

  updateConfFile $1 ${WORKDIR}/etc/conf.d/${LASTSECTION};
}

##
## Installation functions/steps
##

# Initialize the storage
setupDisks() {
  ## 1. Create partitions
  ## 2. Format partitions
  ## 3. Create volume groups
  ##    For each VG
  ##    4. Create logical volumes
  ##    5. Format the logical volume


  DISKS=$(awk -F'.' '/disk./ {print $2}' ${DATA} | sort | uniq | grep -v lvm);
  for DISK in ${DISKS};
  do
    # Create partitions
    SFDISKOUT=""
    PARTS=$(awk -F'.' "/disk.${DISK}./ {print \$3}" ${DATA} | sort | uniq);
    for PART in ${PARTS};
    do
      SIZE=$(awk -F'=' "/disk.${DISK}.${PART}.size/ {print \$2}" ${DATA});
      TYPE=$(awk -F'=' "/disk.${DISK}.${PART}.type/ {print \$2}" ${DATA});
      SFDISKOUT="${SFDISKOUT},${SIZE},${TYPE}\n";
    done
    printf "Creating partitions for device /dev/${DISK}... "; 
    logPrint "Creating partitions for device /dev/${DISK}." >> ${LOG};
    printf ${SFDISKOUT} | sfdisk --no-reread -uM /dev/${DISK} >> ${LOG} 2>&1;
    printf "done\n"; 

    # Wait for partitions to settle
    sync;
    sleep 2;

    # Format partitions
    for PART in ${PARTS};
    do
      FORMAT=$(awk -F'=' "/disk.${DISK}.${PART}.format/ {print \$2}" ${DATA});
      printf "  - Formatting partition /dev/${DISK}${PART} with ${FORMAT}... ";
      logPrint "Formatting partition /dev/${DISK}${PART} with ${FORMAT}." >> ${LOG};
      ${FORMAT} /dev/${DISK}${PART} >> ${LOG} 2>&1;
      printf "done\n";
    done
  done

  sleep 2; # Wait for device settings to settle

  # Create volume groups
  LVMGROUPS=$(awk -F'=' '/disk.lvm.creategroup/ {print $2}' ${DATA} | sort | uniq);
  for LVMGROUP in ${LVMGROUPS};
  do
    _PV=$(awk -F'.' "/.purpose=lvm:${LVMGROUP}/ {print \$2\$3}" ${DATA} | sort | uniq | sed -e 's:^:/dev/:g');
    PV="";
    for _PVI in ${_PV}; do PV="${PV} ${_PVI}"; done
    printf "Creating volume group ${LVMGROUP}... ";
    logPrint "Creating volume group ${LVMGROUP} with devices ${PV}." >> ${LOG};
    vgcreate ${LVMGROUP} ${PV} >> ${LOG} 2>&1 || die "Could not create volume group ${LVMGROUP}";
    printf "done\n";

    sleep 2; # Wait for VG to settle

    # Create logical volumes and format.
    LVS=$(awk -F'.' "/disk.lvm.${LVMGROUP}/ {print \$4}" ${DATA} | sort | uniq);
    for LV in ${LVS};
    do
      SIZE=$(awk -F'=' "/disk.lvm.${LVMGROUP}.${LV}.size/ {print \$2}" ${DATA});
      FORMAT=$(awk -F'=' "/disk.lvm.${LVMGROUP}.${LV}.format/ {print \$2}" ${DATA});

      printf "  - Creating logical volume ${LV} in volume group ${LVMGROUP}... ";
      logPrint "  - Creating logical volume ${LV} in volume group ${LVMGROUP}." >> ${LOG};
      RC=5; while [ ${RC} -eq 5 ] && [ ${SIZE} -gt 0 ]; do lvcreate -L${SIZE}M -n${LV} ${LVMGROUP} >> ${LOG} 2>&1; RC=$?; SIZE=$((${SIZE}-1)); done
      printf "done\n";
      if [ ${RC} -ne 0 ];
      then
        printf "Error: Creating logical volume failed. Bailing out...";
	exit 1;
      fi

      printf "  - Formatting logical volume ${LV} in volume group ${LVMGROUP} with ${FORMAT}... ";
      logPrint "  - Formatting logical volume ${LV} in volume group ${LVMGROUP} with ${FORMAT}." >> ${LOG};
      ${FORMAT} /dev/${LVMGROUP}/${LV} >> ${LOG} 2>&1;
      printf "done\n";
    done
  done
}

mountDisks() {
  vgchange -a y >> ${LOG};
  # Swap first
  SWAPS=$(awk -F'.' "/disk.*.purpose=swap/ {print \$2\$3}" ${DATA} | grep -v '^lvm');
  LVMSWAPS=$(awk -F'.' '/disk.lvm.*.purpose=swap/ {print $3"/"$4}' ${DATA});
  printf "Enabling swap space (${SWAPS} ${LVMSWAPS})... ";
  logPrint "Enabling swap space (${SWAPS} ${LVMSWAPS})." >> ${LOG};
  for SWAP in ${SWAPS} ${LVMSWAPS};
  do
    swapon /dev/${SWAP} >> ${LOG} 2>&1;
  done
  printf "done\n";

  # Root next
  [ ! -d ${WORKDIR} ] && mkdir -p ${WORKDIR};

  printf "Mounting partitions:\n";
  logPrint "Mounting partitions:" >> ${LOG};

  ROOT=$(awk -F'.' '/disk.*.purpose=root/ {print $2$3}' ${DATA} | grep -v lvm);
  ROOT="${ROOT}$(awk -F'.' '/disk.lvm.*.purpose=root/ {print $3"/"$4}' ${DATA})";
  printf " - /dev/${ROOT} @ ${WORKDIR}\n";
  logPrint " - /dev/${ROOT} @ ${WORKDIR}" >> ${LOG};
  mount /dev/${ROOT} ${WORKDIR} || die "Failed to mount /dev/${ROOT} on ${WORKDIR}";

  PURPOSES=$(awk -F'=' "/disk.*.purpose=\// {print \$2}" ${DATA});
  MAXNUMSLASH=$(echo ${PURPOSES} | sed -e 's: :\n:g' | sed -e 's:[^/]::g' | sort | tail -1 | wc -c);
  NUMSLASH=1;
  while [ ${NUMSLASH} -lt ${MAXNUMSLASH} ];
  do
    PURPOSESSET=$(echo ${PURPOSES} | sed -e 's: :\n:g' | sed -r -e "s:^(/[^/]*){$((${NUMSLASH}+1)),}$::g" | sed -r -e "s:^(/[^/]*){,$((${NUMSLASH}-1))}$::g" | grep -v '^$');
    for PURPOSE in ${PURPOSESSET};
    do
      AWKPURPOSE=$(echo ${PURPOSE} | sed -e 's:/:\\\/:g');
      DISK=$(awk -F'.' "/disk.*.purpose=${AWKPURPOSE}$/ {print \$2\$3}" ${DATA} | grep -v lvm);
      [ -z "${DISK}" ] && DISK="$(awk -F'.' "/disk.lvm.*.purpose=${AWKPURPOSE}$/ {print \$3}" ${DATA})/$(awk -F'.' "/disk.lvm.*.purpose=${AWKPURPOSE}$/ {print \$4}" ${DATA})";
      mkdir -p ${WORKDIR}${PURPOSE} > /dev/null 2>&1;
      printf " - /dev/${DISK} @ ${WORKDIR}${PURPOSE}\n";
      logPrint " - /dev/${DISK} @ ${WORKDIR}${PURPOSE}" >> ${LOG};
      mount /dev/${DISK} ${WORKDIR}${PURPOSE};
    done
    NUMSLASH=$((${NUMSLASH}+1));
  done

  printf "Performing other mounts (proc/dev/tmp/...)... ";
  logPrint "Performing other mounts (proc/dev/tmp/...)." >> ${LOG};
  [ -d ${WORKDIR}/proc ] || mkdir ${WORKDIR}/proc; mount -t proc proc ${WORKDIR}/proc;
  [ -d ${WORKDIR}/dev ] || mkdir ${WORKDIR}/dev; mount --rbind /dev ${WORKDIR}/dev;
  [ -d ${WORKDIR}/sys ] || mkdir ${WORKDIR}/sys; mount --rbind /sys ${WORKDIR}/sys;
  [ -d ${WORKDIR}/var/tmp ] || mkdir -p ${WORKDIR}/var/tmp; chmod 1777 ${WORKDIR}/var/tmp;
  [ -d ${WORKDIR}/tmp ] || mkdir ${WORKDIR}/tmp; mount -t tmpfs tmpfs ${WORKDIR}/tmp;
  printf "done\n";
};

extractFiles() {
  printf "Setting time correct (using ntpdate)... ";
  logPrint "Setting time correct (using ntpdate)." >> ${LOG};
  ntpdate ntp.belnet.be >> ${LOG} 2>&1;
  printf "done\n";

  cd ${WORKDIR};
  MIRROR=$(getValue weblocation | awk '{print $1}');
  SNAP=$(awk -F'=' '/snapshot/ {print $2}' ${DATA});
  STAGESTATUS=$(awk -F'=' '/stagestatus/ {print $2}' ${DATA});
  printf "Downloading stage... ";
  logPrint "Downloading stage." >> ${LOG};

  if [ "$STAGESTATUS" = "latest" ];
  then
    STAGEPATTERN=$(awk -F'=' '/stagepattern/ {print $2}' ${DATA});
    STAGEFILE="$(basename $STAGEPATTERN)"
    STAGEPATH="${STAGEPATTERN%/*}"
    wget -r -l1 --no-parent -A"${STAGEFILE}" ${MIRROR}/${STAGEPATH};
    STAGEDESTPATH="$(find . -iname "${STAGEFILE}")";
    STAGEDESTFILE="$(basename ${STAGEDESTPATH})"
    mv ${STAGEDESTPATH} ${STAGEDESTFILE};
    FETCH=${STAGEDESTFILE}
  else
    FETCH=$(awk -F'=' '/stage/ {print $2}' ${DATA});
    wget ${MIRROR}/${FETCH} >> ${LOG} 2>&1;
  fi

  if [ $? -ne 0 ];
  then
    printf "failed!\n";
    die "Failed to fetch stage from the given location." 
  else
    printf "done\n";
  fi

  printf "Extracting stage ${FETCH##*/}... ";
  logPrint "Extracting stage ${FETCH##*/}." >> ${LOG};
  tar xjpf ${FETCH##*/} --exclude='./dev/*' >> ${LOG} 2>&1;
  printf "done\n";

  printf "Extracting /dev files to root filesystem... ";
  logPrint "Extracting /dev files to root filesystem... " >> ${LOG};
  test -d ${WORKDIR}/mnt || mkdir ${WORKDIR}/mnt;
  mount --bind ${WORKDIR} ${WORKDIR}/mnt;
  tar xjpf ${FETCH##*/} -C ${WORKDIR}/mnt './dev/' >> ${LOG} 2>&1;
  rm -f ${FETCH##*/} >> ${LOG} 2>&1;
  umount ${WORKDIR}/mnt;
  printf "done\n";

  printf "Removing stage ${FETCH##*/} from system... ";
  rm -f ${FETCH##*/};
  printf "done\n";

  printf "Downloading portage snapshot... ";
  logPrint "Downloading portage snapshot." >> ${LOG};
  cd ${WORKDIR}/usr;
  wget ${MIRROR}/${SNAP} >> ${LOG} 2>&1;
  if [ $? -ne 0 ];
  then
    printf "failed!\n";
    die "Failed to fetch snapshot from the given location." 
  else
    printf "done\n";
  fi

  printf "Extracting portage snapshot... ";
  logPrint "Extracting portage snapshot." >> ${LOG};
  tar xf ${SNAP##*/} >> ${LOG} 2>&1;
  printf "done\n";

  printf "Removing snapshot ${SNAP##*/}... ";
  rm -f ${SNAP##*/};
  printf "done\n";
};

setupSystem() {
  printf "Setup make.conf... ";
  logPrint "Setup make.conf." >> ${LOG};
  updateConfFile makeconf ${WORKDIR}/etc/portage/make.conf;
  printf "done\n";

  printf "  - Setup repos.conf...\n";
  logPrint "  - Setup repos.conf..." >> ${LOG};
  REPOS=$(listSectionOverview reposconf);
  for REPO in ${REPOS};
  do
    reposconftitle="[$REPO]";
    echo "$reposconftitle" >> ${WORKDIR}/etc/portage/repos.conf;

    REPOCONFIGS=$(listSectionOverview reposconf.${REPO});
    for REPOCONFIG in ${REPOCONFIGS};
    do
      value=$(awk -F'=' "/reposconf.${REPO}.${REPOCONFIG}=/ {print \$2}" ${DATA});
      reposconfsetting="${REPOCONFIG}=$value";
      echo "$reposconfsetting" >> ${WORKDIR}/etc/portage/repos.conf;
    done

    echo -e "" >> ${WORKDIR}/etc/portage/repos.conf;
  done

  printf "Prepare chroot... ";
  logPrint "Prepare chroot." >> ${LOG};
  test -d ${WORKDIR}/etc || (mkdir ${WORKDIR}/etc && chmod 755 ${WORKDIR}/etc; )
  cp -L /etc/resolv.conf ${WORKDIR}/etc;
  ZONE=$(awk -F'=' '/setup.etc.timezone=/ {print $2}' ${DATA});
  cp ${WORKDIR}/usr/share/zoneinfo/${ZONE} ${WORKDIR}/etc/localtime;
  printf "done\n";

  GENPROFILE=$(getValue profile);
  printf "Selecting profile (${GENPROFILE})... ";
  runChrootCommand eselect profile set ${GENPROFILE} >> ${LOG} 2>&1;
  printf "done\n";
};

umountDisks() {
  printf "Synchronizing changes... ";
  logPrint "Synchronizing changes" >> ${LOG};
  sync;
  sleep 5;
  sync;
  printf "done\n";

  printf "Umounting all mounted filesystems at ${WORKDIR}... ";
  logPrint "Umounting all mounted filesystems at ${WORKDIR}." >> ${LOG};
  MFSYSES=$(mount | awk '{print $3}' | grep "^${WORKDIR}");
  DEVSYSES=$(mount | awk '{print $3}' | grep "^/dev" | sed -e "s:^:${WORKDIR}:g");
  RC=1;
  COUNT=0;
  while [ ${RC} -gt 0 ] && [ ${COUNT} -lt 10 ];
  do
    RC=0;
    COUNT=$((${COUNT}+1));
    for DEVSYS in ${DEVSYSES};
    do
      mount | awk '{print $3}' | grep "${DEVSYS}$" > /dev/null 2>&1;
      [ $? -eq 0 ] || continue;
      umount -l ${DEVSYS} >> ${LOG} 2>&1;
      RC=$((${RC}+$?));
    done
  done
  RC=1;
  COUNT=0;
  while [ ${RC} -gt 0 ] && [ ${COUNT} -lt 10 ];
  do
    RC=0;
    COUNT=$((${COUNT}+1));
    for MFSYS in ${MFSYSES};
    do
      mount | awk '{print $3}' | grep "${MFSYS}$" > /dev/null 2>&1;
      [ $? -eq 0 ] || continue;
      umount ${MFSYS} >> ${LOG} 2>&1;
      RC=$((${RC}+$?));
    done
  done
  mount -o remount,ro ${WORKDIR} >> ${LOG} 2>&1;
  sync >> ${LOG} 2>&1;
  sleep 1;
  sync >> ${LOG} 2>&1;
  umount -l ${WORKDIR} >> ${LOG} 2>&1;
  printf "done\n";
};

generateFstab() {
  ROOT=$(awk -F'.' '/disk.*.purpose=root/ {print $2$3}' ${DATA} | grep -v lvm);
  ROOT="${ROOT}$(awk -F'.' '/disk.lvm.*.purpose=root/ {print $3"/"$4}' ${DATA})";
  ROOTLABEL=$(grep '.purpose=root' ${DATA} | sed -e 's:.purpose=root.*::g');
  ROOTFS=$(awk -F'=' "/${ROOTLABEL}.filesystem/ {print \$2}" ${DATA});
  echo "/dev/${ROOT}	/		${ROOTFS}	noatime		1 2"

  SWAP=$(awk -F'.' '/disk.*.purpose=swap/ {print $2$3}' ${DATA} | grep -v lvm);
  SWAPLABEL=$(grep '.purpose=swap' ${DATA} | sed -e 's:.purpose=swap.*::g');
  SWAPFS=$(awk -F'=' "/${SWAPLABEL}.filesystem/ {print \$2}" ${DATA});
  echo "/dev/${SWAP}    none            ${SWAPFS}       sw,pri=1               0 0"

  PURPOSES=$(awk -F'=' "/disk.*.purpose=\// {print \$2}" ${DATA});
  MAXNUMSLASH=$(echo ${PURPOSES} | sed -e 's: :\n:g' | sed -e 's:[^/]::g' | sort | tail -1 | wc -c);
  NUMSLASH=1;
  while [ ${NUMSLASH} -lt ${MAXNUMSLASH} ];
  do
    PURPOSESSET=$(echo ${PURPOSES} | sed -e 's: :\n:g' | sed -r -e "s:^(/[^/]*){$((${NUMSLASH}+1)),}$::g" | sed -r -e "s:^(/[^/]*){,$((${NUMSLASH}-1))}$::g" | grep -v '^$');
    for PURPOSE in ${PURPOSESSET};
    do
      AWKPURPOSE=$(echo ${PURPOSE} | sed -e 's:/:\\\/:g');
      DISK=$(awk -F'.' "/disk.*.purpose=${AWKPURPOSE}$/ {print \$2\$3}" ${DATA} | grep -v lvm);
      [ -z "${DISK}" ] && DISK="$(awk -F'.' "/disk.lvm.*.purpose=${AWKPURPOSE}$/ {print \$3}" ${DATA})/$(awk -F'.' "/disk.lvm.*.purpose=${AWKPURPOSE}$/ {print \$4}" ${DATA})";
      IDDISK=$(grep ".purpose=${AWKPURPOSE}" ${DATA} | sed -e 's:.purpose=.*::g');
      FILESYS=$(grep "${IDDISK}.filesystem" ${DATA} | awk -F'=' '{print $2}');
      echo "/dev/${DISK}	${PURPOSE}	${FILESYS}	noatime		0 0"
    done
    NUMSLASH=$((${NUMSLASH}+1));
  done
  echo "tmpfs		/tmp		tmpfs		defaults,noexec,nosuid	0 0"
};

configureSystem() {
  HOSTNM=$(awk -F'=' '/setup.conf.hostname.hostname=/ {print $2}' ${DATA});
  DOMNM=$(awk -F'=' '/setup.domainname=/ {print $2}' ${DATA});
  LOCALGEN=$(getValue setup.localegen.numentries);
  printf "Setting system specific configuration items:\n";
  logPrint "Setting system specific configuration items:" >> ${LOG};

  printf "  - Setup /etc/hosts\n";
  logPrint "  - Setup /etc/hosts" >> ${LOG};
  echo "127.0.0.1   ${HOSTNM}.${DOMNM} ${HOSTNM}" > ${WORKDIR}/etc/hosts;

  ETCHOSTS=$(listSectionOverview setup.hosts);
  for ETCHOST in ${ETCHOSTS};
  do
    IPVALUE=$(awk -F'=' "/setup.hosts.${ETCHOST}=/ {print \$2}" ${DATA});
    echo "${IPVALUE}   ${ETCHOST}.${DOMNM} ${ETCHOST}" >> ${WORKDIR}/etc/hosts
  done

  printf "  - Setup /etc/timezone... ";
  logPrint "  - Setup /etc/timezone" >> ${LOG};
  getValue setup.etc.timezone > ${WORKDIR}/etc/timezone;
  printf "done\n";

  FILES=$(listSectionOverview setup.conf);
  for FILE in ${FILES};
  do
    printf "  - Setup /etc/conf.d/${FILE}\n";
    updateEtcConfFile setup.conf.${FILE};
  done

  printf "  - Setup /etc/fstab\n";
  logPrint "  - Setup /etc/fstab" >> ${LOG};
  generateFstab > ${WORKDIR}/etc/fstab;

  printf "  - Preparing chroot environment\n";
  logPrint "  - Preparing chroot environment" >> ${LOG};
  runChrootCommand env-update >> ${LOG} 2>&1;

  # Determine the network interface name based on what was passed to
  # setup.conf.net
  INTERFACENM=$(awk -F'[._=]' '/setup.conf.net.config_/ {print $5}' ${DATA} );

  printf "  - Enabling ${INTERFACENM}\n";
  logPrint "  - Enabling ${INTERFACENM}" >> ${LOG};
  runChrootCommand ln -sf /etc/init.d/net.lo /etc/init.d/net.${INTERFACENM} >> ${LOG} 2>&1;
  runChrootCommand rc-update add net.${INTERFACENM} default >> ${LOG} 2>&1;

  printf "  - Enabling sshd\n";
  logPrint "  - Enabling sshd" >> ${LOG};
  runChrootCommand rc-update add sshd default >> ${LOG} 2>&1;

  printf "  - Setup root password\n";
  logPrint "  - Setup root password" >> ${LOG};
  ROOTPASS=$(awk -F'=' '/setup.rootpassword=/ {print $2}' ${DATA});
  runChrootCommand "yes \"${ROOTPASS}\" | passwd" >> ${LOG} 2>&1;

  printf "  - Setup /etc/portage/* directories and files\n";
  logPrint "  - Setup /etc/portage/* directories and files" >> ${LOG};
  PACKAGEFILES=$(listSectionOverview portage.package | grep -v "portage.package.env");
  for PACKAGEFILE in ${PACKAGEFILES};
  do
    mkdir -p ${WORKDIR}/etc/portage/package.${PACKAGEFILE};
    FILELIST=$(listSectionOverview portage.package.${PACKAGEFILE});
    for FILE in ${FILELIST};
    do
      VALUES=$(getValue portage.package.${PACKAGEFILE}.${FILE} | sed -e 's:\\ :_SPACE_:g');
      for VALUE in ${VALUES};
      do
        echo "${VALUE}" | sed -e 's:_SPACE_: :g' >> ${WORKDIR}/etc/portage/package.${PACKAGEFILE}/${FILE};
      done
    done
  done

  printf "  - Setup /etc/portage/env directories and files\n";
  logPrint "  - Setup /etc/portage/env directories and files" >> ${LOG};
  mkdir -p ${WORKDIR}/etc/portage/env
  PACKAGEENVFILES=$(listSectionOverview portage.env);
  for PACKAGEENVFILE in ${PACKAGEENVFILES};
  do
    PACKAGEENVVARS=$(listSectionOverview portage.env.${PACKAGEENVFILE});
    for PACKAGEENVVAR in ${PACKAGEENVVARS};
    do
      VARVALUE=$(awk -F'=' "/portage.env.${PACKAGEENVFILE}.${PACKAGEENVVAR}=/ {print \$2}" ${DATA});
      VARDEF="${PACKAGEENVVAR}=\"${VARVALUE}\""
      ENVFILE="env_${PACKAGEENVFILE}"
      echo "${VARDEF}" >> ${WORKDIR}/etc/portage/env/${ENVFILE}
    done
  done

  printf "  - Setup /etc/portage/package.env listings\n";
  logPrint "  - Setup /etc/portage/package.env listings" >> ${LOG};
  ENVAPPS=$(listSectionOverview portage.package.env);
  for ENVAPP in ${ENVAPPS};
  do
    OVERRIDES=$(listSectionOverview portage.package.env.${ENVAPP});
    for OVERRIDE in ${OVERRIDES};
    do
      OVERRIDEDEF="${ENVAPP} ${OVERRIDE}"
      echo "${OVERRIDEDEF}" >> ${WORKDIR}/etc/portage/package.env
    done
  done

  printf "  - Setup /etc/locale.gen\n";
  logPrint "  - Setup /etc/locale.gen" >> ${LOG};
  test -f ${WORKDIR}/etc/locale.gen && rm ${WORKDIR}/etc/locale.gen;
  for NUM in $(seq ${LOCALGEN});
  do
    LOCGENENTRY=$(getValue setup.localegen.${NUM}); 
    echo "${LOCGENENTRY}" >> ${WORKDIR}/etc/locale.gen;
  done
};

installTools() {
  PACKAGES=$(awk -F'=' '/tools.install.packages=/ {print $2}' ${DATA});
  DRUNLEVEL=$(awk -F'=' '/tools.install.runlevel.default=/ {print $2}' ${DATA});
  BRUNLEVEL=$(awk -F'=' '/tools.install.runlevel.boot=/ {print $2}' ${DATA});
  SRUNLEVEL=$(awk -F'=' '/tools.install.runlevel.sysinit=/ {print $2}' ${DATA});
  FAILEDPACKAGES="";
  HASFAILED=0;
  for PACKAGE in ${PACKAGES};
  do
    printf "  - Installing ${PACKAGE}... "
    logPrint "  - Installing ${PACKAGE}" >> ${LOG};
    PRESTEP=$(awk -F'=' "/tools.install.package.${PACKAGE}.preinstall=/ {print \$2}" ${DATA});
    POSTSTEP=$(awk -F'=' "/tools.install.package.${PACKAGE}.postinstall=/ {print \$2}" ${DATA});
    PREPEND=$(grep "^tools.install.package.${PACKAGE}.prepend" ${DATA} | sed -e 's:^[^=]*=::g');
    FULLCMD="";
    if [ -n "${PRESTEP}" ];
    then
      FULLCMD="${PRESTEP}; ";
    fi
    FULLCMD="${FULLCMD} ${PREPEND} emerge --binpkg-respect-use=y -g ${PACKAGE}; ";
    if [ -n "${POSTSTEP}" ];
    then
      FULLCMD="${FULLCMD} ${POSTSTEP};";
    fi
    logPrint "    Executing ${FULLCMD}" >> ${LOG};
    runChrootCommand "${FULLCMD}" >> ${LOG} 2>&1;
    RC=$?;
    if [ $RC -eq 0 ];
    then
      printf "done\n";
    else
      printf "failed!\n";
      FAILEDPACKAGES="${FAILEDPACKAGES} ${PACKAGE}";
      HASFAILED=$((${HASFAILED}+1));
    fi
  done

  for DEFRUNLEVEL in ${DRUNLEVEL};
  do
    printf "    Adding ${DEFRUNLEVEL} to default runlevel\n";
    logPrint "    Adding ${DEFRUNLEVEL} to default runlevel" >> ${LOG};
    runChrootCommand rc-update add ${DEFRUNLEVEL} default >> ${LOG} 2>&1;
  done 

  for BOOTRUNLEVEL in ${BRUNLEVEL};
  do
    printf "    Adding ${BOOTRUNLEVEL} to boot runlevel\n";
    logPrint "    Adding ${BOOTRUNLEVEL} to boot runlevel" >> ${LOG};
    runChrootCommand rc-update add ${BOOTRUNLEVEL} boot >> ${LOG} 2>&1;
  done

  for SYSINITRUNLEVEL in ${SRUNLEVEL};
  do
    printf "    Adding ${SYSINITRUNLEVEL} to sysinit runlevel\n";
    logPrint "    Adding ${SYSINITRUNLEVEL} to sysinit runlevel" >> ${LOG};
    runChrootCommand rc-update add ${SYSINITRUNLEVEL} sysinit >> ${LOG} 2>&1;
  done

  if [ ${HASFAILED} -gt 0 ];
  then
    die "${HASFAILED} packages (${FAILEDPACKAGES}) failed to install properly. Manually fix this and start with the next step.";
  fi
};

installGrub() {
  printf "  - Installing GRUB... ";
  logPrint "   - Installing GRUB" >> ${LOG};
  runChrootCommand emerge --binpkg-respect-use=y -g grub-static >> ${LOG} 2>&1;
  printf "done\n";

  printf "  - Forcing rw-mount for /boot (if applicable).. ";
  logPrint "  - Forcing rw-mount for /boot (if applicable)." >> ${LOG};
  mount -o remount,rw ${WORKDIR}/boot >> ${LOG} 2>&1;
  printf "done\n";

  # Check if the root drive is a logical volume or a standard partition and
  # build it's mounted path based on the result.
  ROOTISLV=$(grep -i "disk.*.purpose=root" ${DATA} | awk -F'.' "m = \$2 ~ /lvm/ { print 1 } "\!"m { print 0 } ");
  if [ "$ROOTISLV" == 1 ];
  then
    # Build the root path (to be passed to the kernel as an arg) to point to a
    # logical volume
    ROOT=$(awk -F'.' '/disk.*.purpose=root/ {print $3"/"$4}' ${DATA});
  else
    # Build the root path (to be passed to the kernel as an arg) to point to a
    # standard partition
    ROOT=$(awk -F'.' "/disk.*.purpose=root/ {print \$2\$3}" ${DATA});
    ROOT="${ROOT}$(awk -F'.' '/disk.lvm.*.purpose=root/ {print $3"/"$4}' ${DATA})";
  fi

  BOOT=$(awk -F'.' '/disk.*.purpose=\/boot/ { print $2$3}' ${DATA} | grep -v lvm);
  BOOT="${BOOT}$(awk -F'.' '/disk.lvm.*.purpose=\/boot/ { print $3"/"$4}' ${DATA})";

  printf "  - Configuring GRUB... ";
  logPrint "  - Configuring GRUB" >> ${LOG};

  INSTALLTYPE=$(getValue kernel.install);
  if [ "${INSTALLTYPE}" = "build" ];
  then
    # prepare for the genkernel initramfs
    printf "default 0\ntimeout 5\n\ntitle Gentoo Linux (Hardened)\nroot (hd0,0)\nkernel /boot/kernel root=/dev/ram0 real_root=/dev/${ROOT} dolvm\ninitrd /boot/initramfs\n" > ${WORKDIR}/boot/grub/grub.conf;
  else
    # a custom made and provided initramfs
    printf "default 0\ntimeout 5\n\ntitle Gentoo Linux (Hardened)\nroot (hd0,0)\nkernel /boot/kernel root=/dev/${ROOT} dolvm\ninitrd /boot/initramfs\n" > ${WORKDIR}/boot/grub/grub.conf;
  fi
  printf "done\n";

  printf "  - Installing into MBR... ";
  logPrint "  - Installing into MBR." >> ${LOG};
  grep -v rootfs /proc/mounts > ${WORKDIR}/etc/mtab;
  if [ -n "${BOOT}" ];
  then
    echo "(hd0) /dev/${BOOT%%[0-9]*}" >> ${WORKDIR}/boot/grub/device.map;
  else
    echo "(hd0)	/dev/${ROOT%%[0-9]*}" >> ${WORKDIR}/boot/grub/device.map;
  fi
  
  runChrootCommand "printf \"root (hd0,0)\nsetup (hd0)\n\" | grub --device-map=/boot/grub/device.map" >> ${LOG} 2>&1;
  printf "done\n";
};

installKernel() {
  KERNELINSTALL=$(getValue kernelsources.install);
  KERNELPACKAGE=$(awk -F'=' '/kernel.package=/ {print $2}' ${DATA});

  if [ "${KERNELINSTALL}" = "provided" ];
  then
    KERNELVERSION=$(runChrootCommand emerge --color n -p ${KERNELPACKAGE} | grep ${KERNELPACKAGE} | sed -e "s:.*/\(${KERNELPACKAGE}[^ ]*\).*:\1:g");
    printf "  - Marking kernel ${KERNELVERSION} as provided... ";
    mkdir -p ${WORKDIR}/etc/portage/make.profile;
    echo ${KERNELVERSION} >> ${WORKDIR}/etc/portage/make.profile/kernelsources;
    printf "done\n";

    printf "  - Creating /usr/src/linux location... ";
    runChrootCommand mkdir -p /usr/src/linux >> ${LOG} 2>&1;
    printf "done\n";
  else
    printf "  - Installing kernel ${KERNELPACKAGE} (source code)... ";
    logPrint "   - Installing kernel ${KERNELPACKAGE} (source code)" >> ${LOG};
    runChrootCommand emerge --binpkg-respect-use=y -g ${KERNELPACKAGE} >> ${LOG} 2>&1;
    printf "done\n";
  fi

  INSTALLTYPE=$(getValue kernel.install);
  if [ "${INSTALLTYPE}" = "binary" ];
  then
    KERNELBUILD=$(getValue kernel.binary);
    KERNELINITRAMFS=$(getValue kernel.initramfs);
    printf "  - Fetching kernel binary (${KERNELBUILD##*/})... ";
    logPrint "  - Fetching kernel binary (${KERNELBUILD##*/})" >> ${LOG};
    cp -f ${SCRIPTDIR}/${KERNELBUILD} ${WORKDIR}/usr/src/linux/linux-binary.tar.bz2 >> ${LOG} 2>&1;
    printf "done\n";

    printf "  - Fetching initramfs (${KERNELINITRAMFS##*/})... ";
    logPrint "  - Fetching initramfs (${KERNELINITRAMFS##*/})" >> ${LOG};
    cp -f ${SCRIPTDIR}/${KERNELINITRAMFS} ${WORKDIR}/boot/initramfs >> ${LOG} 2>&1;
    printf "done\n";

    printf "  - Installing kernel binary... ";
    runChrootCommand "tar xjf /usr/src/linux/linux-binary.tar.bz2 -C /" >> ${LOG} 2>&1;
    runChrootCommand mv -f /boot/vmlinuz-* /boot/kernel;
    printf "done\n";
  elif [ "${INSTALLTYPE}" = "build" ];
  then
    KERNELCONFIG=$(awk -F'=' '/kernel.config=/ {print $2}' ${DATA});

    # If a config file is provided, use that, else generate a base one to use
    if [ -n "$KERNELCONFIG" ];
    then
      printf "  - Fetching kernel configuration (${KERNELCONFIG})... ";
      logPrint "  - Fetching kernel configuration (${KERNELCONFIG})." >> ${LOG};
      cp -f ${SCRIPTDIR}/${KERNELCONFIG} ${WORKDIR}/usr/src/linux/.config >> ${LOG} 2>&1;
      printf "done\n";

      printf "  - Building kernel... ";
      logPrint "  - Building kernel" >> ${LOG};

      runChrootCommand "cd /usr/src/linux; yes \"\" | make && make modules_install" >> ${LOG} 2>&1;
    else
      printf "  - Building kernel... ";
      logPrint "  - Building kernel" >> ${LOG};

      runChrootCommand "cd /usr/src/linux; yes \"\" | make oldconfig && make && make modules_install" >> ${LOG} 2>&1;
    fi

    printf "done\n";

    printf "  - Installing kernel... ";
    logPrint "  - Installing kernel" >> ${LOG};

    cp ${WORKDIR}/usr/src/linux/arch/x86/boot/bzImage ${WORKDIR}/boot/kernel;

    # make initramfs if build
    if [ "${INSTALLTYPE}" = "build" ];
    then
      runChrootCommand emerge --binpkg-respect-use=y -g genkernel >> ${LOG} 2>&1;
      runChrootCommand "genkernel --kernel-config=/usr/src/linux/.config --lvm --install initramfs" >> ${LOG} 2>&1;

      # The automatic initramfs filename contains kernel data appended. Make sure 
      # the name is the one our bootloader expects.
      mv -f ${WORKDIR}/boot/initramfs-* ${WORKDIR}/boot/initramfs
    fi

    printf "done\n";
  fi
};

stepOK "disk" && (
printf ">>> Step \"disk\" starting...\n";
setupDisks;
);
nextStep;

stepOK "mount" && (
printf ">>> Step \"mount\" starting...\n";
mountDisks;
);
nextStep;

stepOK "extract" && (
printf ">>> Step \"extract\" starting...\n";
extractFiles;
);
nextStep;

stepOK "setup" && (
printf ">>> Step \"setup\" starting...\n";
setupSystem;
);
nextStep;

stepOK "configure" && (
printf ">>> Step \"configure\" starting...\n";
configureSystem;
);
nextStep;

stepOK "tools" && (
printf ">>> Step \"tools\" starting...\n";
installTools;
);
nextStep;

stepOK "bootloader" && (
printf ">>> Step \"bootloader\" starting...\n";
installGrub;
);
nextStep;

stepOK "kernel" && (
printf ">>> Step \"kernel\" starting...\n";
installKernel;
);
nextStep;

stepOK "umount" && (
printf ">>> Step \"umount\" starting...\n";
umountDisks;
);
nextStep;

stepOK "reboot" && (
printf ">>> Kernel installation complete. Rebooting system...\n";
reboot;
);
nextStep;

