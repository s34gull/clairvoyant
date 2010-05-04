#!/bin/bash
unset PATH

# -------------COMMANDS------------------------------------------------
# Include external commands here for portability

CAT=/bin/cat;
CLAMDSCAN=/usr/bin/clamdscan
CP=/bin/cp;
DATE=/bin/date;
ECHO=/bin/echo;
FSCK=/sbin/fsck;
GREP=/bin/grep;
MKDIR=/bin/mkdir;
MOUNT=/bin/mount;
MV=/bin/mv;
PS=/bin/ps;
RM=/bin/rm;
RSYNC=/usr/bin/rsync;
SU=/bin/su;
SUDO=/usr/bin/sudo;
SYNC=/bin/sync;
TOUCH=/bin/touch;
UMOUNT=/bin/umount;

# ---------------------------------------------------------------------
#
# The following actions apply to the following repositories:
# CentOS 4 x86_64 (skip i386);
# CentOS 5 i386 and x86_64
# 

RSYNC_USER=reposync;

LOCAL_REPO_DEV=/dev/mapper/raid10--vol--group-centos--repo--lv;
LOCAL_REPO_MOUNT=/var/www/repos;
LOCAL_CENTOS_REPO=${LOCAL_REPO_MOUNT}/centos;
LOCAL_CENTOS_REPO_WORKING=${LOCAL_REPO_MOUNT}/.centos;

CENTOS_MIRROT_SITE=centos.mirrors.tds.net;
CENTOS_REPO_ROOT=${CENTOS_MIRROT_SITE}/CentOS;

MESSAGE_LOG=/var/log/messages;
DETAIL_LOG=/var/log/local-repo-rsync-centos.log;

LOCK_DIR=/var/lock/local-repo-rsync-centos.d;
FATAL_LOCK_FILE=$LOCK_DIR/fatal.lock;
LOCK_FILE=/var/run/local-repo-rsync-centos.pid;

# LOGGING levels
LOG_TRACE=5;
LOG_DEBUG=4;
LOG_INFO=3;
LOG_WARN=2;
LOG_ERROR=1;
LOG_FATAL=0;

SILENT=no;

# The syntax of kill can differ; either -n (Ubuntu) or -s (RHEL/Centos)
# Make appropriate change here.
TEST_PROCESS="$PS -p";

#If we want to notify the user of our progress
#NOTIFY="/usr/bin/notify-send --urgency=normal --expire-time=2000 Snaphot";
# set NOTIFY to $ECHO
NOTIFY=$ECHO;

#-----------------------------------------------------------------------
# Logging functions; all output is echo'd to console and/or appended to
# $MESSAGE_LOG
#-----------------------------------------------------------------------
echoConsole() {
    if [ $SILENT = no ]; then
        $ECHO $1;
    fi;
}

logLog() {
    if [ $LOG_LEVEL -ge $LOG_WARN ]; then
        echoConsole "LOG: $*";
        $ECHO "`$DATE` {$0} [$$] LOG: $*" >> $MESSAGE_LOG;
        $ECHO "`$DATE` [$$] LOG: $*" >> $DETAIL_LOG;
        $NOTIFY "$*";
    fi;
}

logTrace() {
    if [ $LOG_LEVEL -ge $LOG_TRACE ]; then
        echoConsole "TRACE: $*";
        $ECHO "`$DATE` [$$] TRACE: $*" >> $DETAIL_LOG;
    fi;
}

logDebug() {
    if [ $LOG_LEVEL -ge $LOG_DEBUG ]; then
        echoConsole "DEBUG: $*";
        $ECHO "`$DATE` [$$] DEBUG: $*" >> $DETAIL_LOG;
    fi;
}

logInfo() {
    if [ $LOG_LEVEL -ge $LOG_INFO ]; then
        echoConsole "INFO: $*";
        $ECHO "`$DATE` [$$] INFO: $*" >> $DETAIL_LOG;
    fi;
}

logWarn() {
    if [ $LOG_LEVEL -ge $LOG_WARN ]; then
        $ECHO "WARNING: $*";
        $ECHO "`$DATE` {$0} [$$] WARNING: $*" >> $MESSAGE_LOG;
        $ECHO "`$DATE` [$$] WARNING: $*" >> $DETAIL_LOG;
    fi;
}

logError() {
    if [ $LOG_LEVEL -ge $LOG_ERROR ]; then
        $ECHO "ERROR:  $*";
        $ECHO "`$DATE` {$0} [$$] ERROR: $*" >> $MESSAGE_LOG;
        $ECHO "`$DATE` [$$] ERROR: $*" >> $DETAIL_LOG;
    fi;
    teardown;
    exit 1;
}

logFatal() {
    $ECHO "FATAL: $*";
    $ECHO "`$DATE` {$0} [$$] FATAL: $*" >> $MESSAGE_LOG;
    $ECHO "`$DATE` [$$] FATAL: $*" >> $DETAIL_LOG;
    $TOUCH $FATAL_LOCK_FILE;
    teardown;
    exit 2;
}

#-----------------------------------------------------------------------
# getLock()
#    Check for or create PID-based lockfile; if it exists note its 
#    presence and exit(1) to avoid running multiple backups 
#    simultaneously.
#-----------------------------------------------------------------------
getLock() {
  logInfo "getLock(): Starting...";
  if [ ! -d $LOCK_DIR ] ; then
      logDebug "getLock(): Lockfile directory doesn't exist; creating $LOCK_DIR";
      logTrace "getLock(): $MKDIR -p $LOCK_DIR >> $MESSAGE_LOG 2>&1";
      $MKDIR -p $LOCK_DIR >> $MESSAGE_LOG 2>&1;
  fi;

  if [ $FATAL_LOCK_FILE -a -f $FATAL_LOCK_FILE ] ; then
    logFatal "A previously fatal error was detected. I will not execute until you review the $MESSAGE_LOG and address any issues reported there; failure to do so may result in corruption of your snapshots. Once you have done so, remove $FATAL_LOCK_FILE and re-run me."; 
  fi;

  if [ $LOCK_FILE -a -f $LOCK_FILE -a -s $LOCK_FILE ] ; then
    PID=`$CAT ${LOCK_FILE}`;
    logDebug "getLock():Checking for running instance of script with PID ${PID}";
    logTrace "getLock(): $TEST_PROCESS ${PID} > /dev/null 2>&1";
    if $TEST_PROCESS ${PID} > /dev/null 2>&1; then
        # check name as well
        logError "getLock():Found running instance with PID=$PID; exiting.";
    else
        logDebug "getLock():Process $PID not found; deleting stale lockfile $LOCK_FILE";
        logTrace "getLock(): $RM $LOCK_FILE >> $MESSAGE_LOG 2>&1";
        $RM $LOCK_FILE >> $MESSAGE_LOG 2>&1;
    fi;
  else
    logDebug "getLock(): Specified lockfile $LOCK_FILE not found; creating...";
    logTrace "getLock(): $TOUCH $LOCK_FILE >> $MESSAGE_LOG 2>&1";
    $TOUCH $LOCK_FILE >> $MESSAGE_LOG 2>&1;
  fi;

  logInfo "getLock(): Recording current PID $$ in lockfile $LOCK_FILE";
  logTrace "getLock(): $ECHO $$ > $LOCK_FILE";
  $ECHO $$ > $LOCK_FILE;

  logInfo "getLock(): Done.";
}

#-----------------------------------------------------------------------
# filesystemCheck()
#    Make sure that the fs is clean. If not, don't attempt repair, but 
#    logFatal and exit(2).
#-----------------------------------------------------------------------
filesystemCheck() {
  logInfo "filesystemCheck(): Starting file system check (repairs will NOT be attempted)...";
  logDebug "filesystemCheck(): Unmounting filesystem $LOCAL_REPO_MOUNT";
  logTrace "filesystemCheck(): $UMOUNT $LOCAL_REPO_MOUNT";
  `$UMOUNT $LOCAL_REPO_MOUNT >> $MESSAGE_LOG 2>&1`;
  if [ $? -ne 0 ] ; then
      logError "filesystemCheck(): Unable to $UMOUNT $LOCAL_REPO_MOUNT; exiting...";
  fi;

  logDebug "filesystemCheck(): Checking file system $LOCAL_REPO_DEV";
  logTrace "filesystemCheck(): $FSCK -fy $LOCAL_REPO_DEV";
  `$FSCK -fy $LOCAL_REPO_DEV >> $MESSAGE_LOG 2>&1`;
  if [ $? -ne 0 ] ; then
      logFatal "filesystemCheck(): $FSCK reported errors on $LOCAL_REPO_DEV; repairs are being attempted; exiting...";
  fi;
  logInfo "filesystemCheck(): File system check complete; $LOCAL_REPO_DEV is clean.";
}

#
# Remount LOCAL_REPO_MOUNT as read-write for update
#
mountReadWrite() {
  logInfo "mountReadWrite(): Starting...";

  filesystemCheck;

  logTrace "mountReadWrite(): Will execute: $MOUNT -o remount,rw,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT}";
  $MOUNT -o remount,rw,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT} >> $MESSAGE_LOG 2>&1;

  if [ $? -ne 0 ]; then
    logWarn "mountReadWrite(): Trying without -o remount";
    logTrace "mountReadWrite(): $MOUNT -o rw,noatime,nodiratime,noexec $LOCAL_REPO_DEV $LOCAL_REPO_MOUNT  >> $MESSAGE_LOG 2>&1";
    `$MOUNT -o rw,noatime,nodiratime,noexec $LOCAL_REPO_DEV $LOCAL_REPO_MOUNT  >> $MESSAGE_LOG 2>&1`;
    if [ $? -ne 0 ] ; then
      logError "mountReadWrite(): Could not re-mount $MOUNT_DEV to $SPARSE_IMAGE_MOUNT readwrite";
    fi;
  fi;
  logInfo "mountReadWrite(): Done.";
}

#
# Remount the LOCAL_REPO_MOUNT as read-only
#
mountReadOnly() {
  logInfo "mountReadOnly(): Starting...";

  logTrace "mountReadOnly(): Will execute: $MOUNT -o remount,ro,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT}";
  $MOUNT -o remount,ro,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT} >> $MESSAGE_LOG 2>&1;

  if [ $? -ne 0 ]; then
    logError "mountReadOnly(): Remount ro ${LOCAL_REPO_MOUNT} failed; exiting...";
  fi;
  logInfo "mountReadOnly(): Done.";
}

#
# Create a working copy of the current local repository using hard links
# to minimize space and preserving modification times so that rsync
# will handle diffs properly. All work takes place in the working copy.
#
createWorkingCopy() { 
  logInfo "createWorkingCopy(): Starting...";

  if [ -d ${LOCAL_CENTOS_REPO_WORKING} ] ; then
    logInfo "createWorkingCopy(): Found old working directory ${LOCAL_CENTOS_REPO_WORKING}; deleting...";
    logTrace "createWorkingCopy(): Will execute: $RM -rf ${LOCAL_CENTOS_REPO_WORKING} >> $MESSAGE_LOG 2>&1";
    $RM -rf ${LOCAL_CENTOS_REPO_WORKING} >> $MESSAGE_LOG 2>&1;
      if [ $? -ne 0 ]; then
        logError "createWorkingCopy(): $RM -rf failed; exiting...";
      fi;
  fi;

  logTrace "createWorkingCopy(): Will execute: $CP -al ${LOCAL_CENTOS_REPO} ${LOCAL_CENTOS_REPO_WORKING}";

  $CP -al ${LOCAL_CENTOS_REPO} ${LOCAL_CENTOS_REPO_WORKING} >> $MESSAGE_LOG 2>&1;

  if [ $? -ne 0 ]; then
    logError "createWorkingCopy(): $CP -al failed; exiting...";
  fi;
  logInfo "createWorkingCopy(): Done.";
}

#
# Replace the stale CentOS repo with the now vetted working copy.
#
promoteWorkingCopy() {
  logInfo "promoteWorkingCopy(): Starting...";

  logTrace "promoteWorkingCopy(): Will execute: $RM -rf ${LOCAL_CENTOS_REPO}";

  $RM -rf ${LOCAL_CENTOS_REPO} >> $MESSAGE_LOG 2>&1;

  if [ $? -ne 0 ]; then
    logError "promoteWorkingCopy(): $RM -rf failed; exiting...";
    exit 1;
  else 
    logTrace "promoteWorkingCopy(): Will execute: $MV ${LOCAL_CENTOS_REPO_WORKING} ${LOCAL_CENTOS_REPO}";

    $MV ${LOCAL_CENTOS_REPO_WORKING} ${LOCAL_CENTOS_REPO} >> $MESSAGE_LOG 2>&1;

    if [ $? -ne 0 ]; then
      logError "promoteWorkingCopy(): $MV failed; exiting...";
    fi;
  fi;
  logInfo "promoteWorkingCopy(): Done.";
}

#
# Loop over CentOS 4 and 5 for i386 and x86_64, performing and rsync against
# a Tier 1 CentOS mirror. Require port 873 be opened for the mirror defined in
# CENTOS_MIRROT_SITE. Failures for an individual file will not stop the sync;
# Failures for an individual REPO will not stop the sync.
#
synchronizeLocalRepos() {
  logInfo "synchronizeLocalRepos(): Starting...";
  
  RSYNC_OPTS="--archive --partial --sparse --delete --exclude=debug/";

  if [ $LOG_LEVEL -ge $LOG_INFO ] ; then
    RSYNC_OPTS="--stats $RSYNC_OPTS";
  fi;

  if [ $LOG_LEVEL -ge $LOG_DEBUG ] ; then
    RSYNC_OPTS="--verbose $RSYNC_OPTS";
  fi;

  if [ $LOG_LEVEL -ge $LOG_TRACE ] ; then
    RSYNC_OPTS="--progress $RSYNC_OPTS";
  fi;

  for RELEASE_VER in "4" "5"; 
  do
    for BASE_ARCH in "i386" "x86_64";
    do
      if [[ ${RELEASE_VER} == "4" ]] && [[ ${BASE_ARCH} == "i386" ]] ; then
        logInfo "synchronizeLocalRepos(): Skipping CentOS ${RELEASE_VER} for ${BASE_ARCH} ...";
        continue;
      fi
      for REPO in addons centosplus contrib extras updates;
      do
        logInfo "synchronizeLocalRepos(): Syncing ${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH}";

        logTrace "synchronizeLocalRepos(): Will execute: $SUDO $SU ${RSYNC_USER} -c \"$RSYNC ${RSYNC_OPTS}  rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
        ${LOCAL_CENTOS_REPO_WORKING}/${RELEASE_VER}/${REPO}/\"";

        $SUDO $SU ${RSYNC_USER} -c "$RSYNC ${RSYNC_OPTS} rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
        ${LOCAL_CENTOS_REPO_WORKING}/${RELEASE_VER}/${REPO}/" >> ${DETAIL_LOG} 2>&1;

        if [ $? -ne 0 ]; then
          logWarn "synchronizeLocalRepos(): [${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH}] rsync failed; continuing...";
        fi; 
      done;
    done;
  done;

  $SYNC;

  logInfo "synchronizeLocalRepos(): Done.";
}

#
# Perform virus scan of the newly downloaded files. Infected files will be deleted.
#
scanForVirii() {
  logInfo "scanForVirii(): Starting...";

  logTrace "scanForVirii(): Will execute: clamdscan --fdpass --multiscan --remove ${LOCAL_CENTOS_REPO_WORKING}";

  CLAMDSCAN_OPT="--fdpass --remove";
  
  $CLAMDSCAN ${CLAMDSCAN_OPT} ${LOCAL_CENTOS_REPO_WORKING} >> ${DETAIL_LOG} 2>&1;

  if [ $? -eq 1 ]; then
    logWarn "scanForVirii(): clamscan detected and removed infected files; contiuing...";
  else 
    if [ $? -eq 2 ]; then
      logError "scanForVirii(): clamscan encountered an error; exiting...";
    fi;
  fi; 

  $SYNC;

  logInfo "scanForVirii(): Done.";
}

#
#
#
startup() {
  logInfo "startup(): Starting...";

  getLock;

  mountReadWrite;

  logInfo "startup(): Done.";
}

#
#
#
teardown() {
  logInfo "teardown(): Starting...";

  mountReadOnly;

  logInfo "teardown(): Removing $LOCK_FILE...";
  $RM $LOCK_FILE >> $MESSAGE_LOG 2>&1;

  logInfo "teardown(): Done.";
}

#
# main coordinates all of the other functions
#
main() {
  LOG_LEVEL=${LOG_WARN};

  logLog "main(): Starting...";

  startup;

  createWorkingCopy;

  synchronizeLocalRepos;

  scanForVirii;

  promoteWorkingCopy;

  teardown;

  logLog "main(): Complete.";

  exit 0;
}

#
# Invoke main
#
main;