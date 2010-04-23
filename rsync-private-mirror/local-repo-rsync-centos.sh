#!/bin/bash

#
# The following actions apply to the following repositories:
# CentOS 4 x86_64 (skip i386);
# CentOS 5 i386 and x86_64
# 

LOCAL_REPO_MOUNT=/var/www/repos
LOCAL_CENTOS_REPO=${LOCAL_REPO_MOUNT}/centos
LOCAL_CENTOS_REPO_WORKING=${LOCAL_REPO_MOUNT}/.centos

CENTOS_MIRROT_SITE=centos.mirrors.tds.net
CENTOS_REPO_ROOT=${CENTOS_MIRROT_SITE}/CentOS

MESSAGE_LOG=/var/log/messages
DETAIL_LOG=/var/log/yum-rsync-repos-centos.log

LOCK_DIR=/var/lock/repo.rsync.d;
FATAL_LOCK_FILE=$LOCK_DIR/fatal.lock;
LOCK_FILE=/var/run/repo.rsync.pid;

# LOGGING levels
LOG_TRACE=5;
LOG_DEBUG=4;
LOG_INFO=3;
LOG_WARN=2;
LOG_ERROR=1;
LOG_FATAL=0;
SILENT=no;

#-----------------------------------------------------------------------
# Logging functions; all output is echo'd to console and/or appended to
# $LOG_FILE
#-----------------------------------------------------------------------
echoConsole() {
    if [ $SILENT = no ]; then
        echo $1;
    fi;
}

logLog() {
    if [ $LOG_LEVEL -ge $LOG_WARN ]; then
        echoConsole "LOG: $*";
        echo "`$DATE` [$$] LOG: $*" >> $MESSAGE_LOG;
        $NOTIFY "$*";
    fi;
}

logTrace() {
    if [ $LOG_LEVEL -ge $LOG_TRACE ]; then
        echoConsole "TRACE: $*";
        echo "`$DATE` [$$] TRACE: $*" >> $LOG_FILE;
    fi;
}

logDebug() {
    if [ $LOG_LEVEL -ge $LOG_DEBUG ]; then
        echoConsole "DEBUG: $*";
        echo "`$DATE` [$$] DEBUG: $*" >> $LOG_FILE;
    fi;
}

logInfo() {
    if [ $LOG_LEVEL -ge $LOG_INFO ]; then
        echoConsole "INFO: $*";
        echo "`$DATE` [$$] INFO: $*" >> $LOG_FILE;
    fi;
}

logWarn() {
    if [ $LOG_LEVEL -ge $LOG_WARN ]; then
        echo "WARNING: $*";
        echo "`$DATE` [$$] WARNING: $*" >> $MESSAGE_LOG;
    fi;
}

logError() {
    if [ $LOG_LEVEL -ge $LOG_ERROR ]; then
        echo "ERROR:  $*";
        echo "`$DATE` [$$] ERROR: $*" >> $MESSAGE_LOG;
    fi;
    exit 1;
}

logFatal() {
    echo "FATAL: $*";
    echo "`$DATE` [$$] FATAL: $*" >> $MESSAGE_LOG;
    $TOUCH $FATAL_LOCK_FILE;
    exit 2;
}

#-----------------------------------------------------------------------
# getLock()
#    Check for or create PID-based lockfile; if it exists note its 
#    presence and exit(1) to avoid running multiple backups 
#    simultaneously.
#-----------------------------------------------------------------------
getLock() {
  logInfo "getLock(): Beginning getLock...";
  if [ ! -d $LOCK_DIR ] ; then
      logDebug "getLock(): Lockfile directory doesn't exist; creating $LOCK_DIR";
      logTrace "getLock(): $MKDIR -p $LOCK_DIR >> $LOG_FILE 2>&1";
      $MKDIR -p $LOCK_DIR >> $LOG_FILE 2>&1;
  fi;

  if [ $FATAL_LOCK_FILE -a -f $FATAL_LOCK_FILE ] ; then
    logFatal "A previously fatal error was detected. I will not execute until you review the $LOG_FILE and address any issues reported there; failure to do so may result in corruption of your snapshots. Once you have done so, remove $FATAL_LOCK_FILE and re-run me."; 
  fi;

  if [ $LOCK_FILE -a -f $LOCK_FILE -a -s $LOCK_FILE ] ; then
      exec 3<&0;
      exec 0<"$LOCK_FILE";
      while read -r PID
      do 
        logDebug "getLock():Checking for running instance of script with PID $PID";
        logTrace "getLock(): $TEST_PROCESS $PID > /dev/null 2>&1";
        $TEST_PROCESS $PID > /dev/null 2>&1;
        if [ $? = 0 ] ; then
            # check name as well
            logError "getLock():Found running instance with PID=$PID; exiting.";
        else
            logDebug "getLock():Process $PID not found; deleting stale lockfile $LOCK_FILE";
            logTrace "getLock(): $RM $LOCK_FILE >> $LOG_FILE 2>&1";
            $RM $LOCK_FILE >> $LOG_FILE 2>&1;
        fi;
        break;
      done;
      exec 0<&3;
  else
    logDebug "getLock(): Specified lockfile $LOCK_FILE not found; creating...";
    logTrace "getLock(): $TOUCH $LOCK_FILE >> $LOG_FILE 2>&1";
    $TOUCH $LOCK_FILE >> $LOG_FILE 2>&1;
  fi;

  logInfo "getLock(): Recording current PID $$ in lockfile $LOCK_FILE";
  logTrace "getLock(): echo $$ > $LOCK_FILE";
  echo $$ > $LOCK_FILE;

  logInfo "getLock(): Done.";
}

echo "`date`: Centos repo mirror: Starting..." >> ${MESSAGE_LOG};

#
# Remount LOCAL_REPO_MOUNT as read-write for update
#
mount -o remount,rw,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT}
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: Remount rw ${LOCAL_REPO_MOUNT} failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
fi;

#
# Create a working copy of the current local repository using hard links
# to minimize space and preserving modification times so that rsync
# will handle diffs properly. All work takes place in the working copy.
# 
cp -al ${LOCAL_CENTOS_REPO} ${LOCAL_CENTOS_REPO_WORKING};
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: cp -al failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
fi;

#
# Loop over CentOS 4 and 5 for i386 and x86_64, performing and rsync against
# a Tier 1 CentOS mirror. Require port 873 be opened for the mirror defined in
# CENTOS_MIRROT_SITE. Failures for an individual file will not stop the sync;
# Failures for an individual REPO will not stop the sync.
#
for RELEASE_VER in "4" "5"; 
do
  for BASE_ARCH in "i386" "x86_64";
  do
    if [[ ${RELEASE_VER} == "4" ]] && [[ ${BASE_ARCH} == "i386" ]] ; then
      echo "`date`: Centos repo mirror: Skipping CentOS ${RELEASE_VER} for ${BASE_ARCH} ..." >> ${DETAIL_LOG};
      continue;
    fi
    for REPO in addons centosplus contrib extras updates;
    do
      echo "`date`: rsync --archive --verbose --partial --sparse --delete  rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
      --exclude=debug/ ${LOCAL_CENTOS_REPO_WORKING}/${RELEASE_VER}/${REPO}/" >> ${DETAIL_LOG};

      sudo su reposync -c "rsync --archive --verbose --partial --sparse --delete  rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
      --exclude=debug/ ${LOCAL_CENTOS_REPO_WORKING}/${RELEASE_VER}/${REPO}/" >> ${DETAIL_LOG} 2>&1;

      if [ $? -ne 0 ]; then
        echo "`date`: Centos repo mirror: [${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH}] rsync failed; continuing..." >> ${MESSAGE_LOG};
      fi; 
    done;
  done;
done;

#
# Kickoff a virus scan of the newly downloaded files. Infected files will be deleted.
#
clamdscan --fdpass --multiscan --remove ${LOCAL_CENTOS_REPO_WORKING} >> ${DETAIL_LOG} 2>&1;
if [ $? -eq 1 ]; then
  echo "`date`: Centos repo mirror: clamscan detected and removed infected files; contiuing..." >> ${MESSAGE_LOG};
else 
  if [ $? -eq 2 ]; then
    echo "`date`: Centos repo mirror: clamscan encountered an error; exiting..." >> ${MESSAGE_LOG};
    exit 1;
  fi;
fi; 

#
# Replace the stale CentOS repo with the now vetted working copy.
#
rm -rf ${LOCAL_CENTOS_REPO};
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: rm -rf failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
else 
  mv ${LOCAL_CENTOS_REPO_WORKING} ${LOCAL_CENTOS_REPO};
  if [ $? -ne 0 ]; then
    echo "`date`: Centos repo mirror: mv failed; exiting..." >> ${MESSAGE_LOG};
    exit 1;
  fi;
fi;

#
# Remount the LOCAL_REPO_MOUNT as read-only
#
mount -o remount,ro,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT}
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: Remount ro ${LOCAL_REPO_MOUNT} failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
fi;

#
# We're outta here!
# 
echo "`date`: Centos repo mirror: Complete." >> ${MESSAGE_LOG};
exit 0;
