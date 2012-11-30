#!/bin/bash
# ----------------------------------------------------------------------
# snapshot.sh
# ----------------------------------------------------------------------
# Creates a rotating snapshot of the contents of $INCLUDES whenever 
# called (minus the contents of the .exlude files). Snapshots are 
# written to a specified sparse disk image hosted file system (via 
# loopback) for portability. If the filesystem on the disk image 
# supports it, space is preserved via hardlinks.
# ----------------------------------------------------------------------
# Copyright (C) 2010  Jonathan Edwards
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE
# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# $Author$ 
# $Rev$
# $Date$
# $Id$
# ----------------------------------------------------------------------

unset PATH

# ----------------------------------------------------------------------
# ------------- COMMANDS --------------------
# Include external commands here for portability
# ----------------------------------------------------------------------
CAT=/bin/cat;
CHMOD=/bin/chmod;
CP=/bin/cp;
CUT=/usr/bin/cut;
DD=/bin/dd;
DATE=/bin/date;
ECHO=/bin/echo;
FSCK=/sbin/fsck;
GREP=/bin/grep;
HASH=/usr/bin/md5sum;
HOSTNAME=/bin/hostname;
ID=/usr/bin/id;
LOSETUP=/sbin/losetup;
LPWD=/bin/pwd;
MKDIR=/bin/mkdir;
MKFS=/sbin/mkfs;
MOUNT=/bin/mount;
MV=/bin/mv;
PS=/bin/ps;
RM=/bin/rm;
RSYNC=/usr/bin/rsync;
SED=/bin/sed;
SYNC=/bin/sync;
TOUCH=/bin/touch;
UMOUNT=/bin/umount;
WC=/usr/bin/wc;

# If we need encryption
CRYPTSETUP=/sbin/cryptsetup;

#If we want to notify the user of our progress
#NOTIFY="/usr/bin/notify-send --urgency=normal --expire-time=2000 Snaphot";
# set NOTIFY to $ECHO
NOTIFY=/bin/echo;

TEST_PROCESS="$PS -p";

# ----------------------------------------------------------------------
# ------------- GLOBAL VARIABLES ---------------------------------------
# ----------------------------------------------------------------------
# Filesystem specific scripts
SNAPSHOT_BTRFS=/usr/local/sbin/snapshot-btrfs.sh;
SNAPSHOT_HFS=/usr/local/sbin/snapshot-hfs.sh;
SNAPSHOT_MACZFS=/usr/local/sbin/snapshot-maczfs.sh;

# These persistent configuration files are user created
CONFIG_DIR=/usr/local/etc/snapshot
INCLUDES=$CONFIG_DIR/include;
EXCLUDE_DIR=$CONFIG_DIR;

# These persistent files are created on first-run
HOURLY_LAST=$CONFIG_DIR/.hourly.last
DAILY_LAST=$CONFIG_DIR/.daily.last;
WEEKLY_LAST=$CONFIG_DIR/.weekly.last;
SPARSE_IMAGE_STOR=$CONFIG_DIR/.sparse.dev;
LOOP_DEV_STOR=$CONFIG_DIR/.loop.dev;
CRYPT_DEV_STOR=$CONFIG_DIR/.crypt.dev;

# Various lock and run files (may be tmpfs so aren't persistent)
LOCK_DIR=/var/lock/snapshot;
FATAL_LOCK_FILE=$LOCK_DIR/fatal.lock;
LOCK_FILE=/var/run/snapshot.pid;

# Log file (may be tmpfs so aren't persistent)
LOG_FILE=/var/log/snapshot.log;

# Rotation variables
PERFORM_HOURLY_SNAPSHOT=yes;
PERFORM_DAILY_ROTATE=yes;
PERFORM_WEEKLY_ROTATE=yes;

# Remember, snap counts start at 0
HOURLY_SNAP_LIMIT=23;

# Time definitions
NOW_SEC=`$DATE -u +%s`; # the current time
HOUR_SEC=$((60 * 60)); # seconds per hourl
DAY_SEC=$(($HOUR_SEC * 24)); # seconds per day
WEEK_SEC=$(($DAY_SEC * 7));

DEFAULT_HOUR_INTERVAL=1; # make snapshots every hour
DEFAULT_DAY_INTERVAL=1; # rotate dailies once a day, every day
DEFAULT_WEEK_INTERVAL=1; # rotate weeklies once a week, every week

# LOGGING levels
LOG_TRACE=5;
LOG_DEBUG=4;
LOG_INFO=3;
LOG_WARN=2;
LOG_ERROR=1;
LOG_FATAL=0;

# Default options
DEFAULT_MOUNT_OPTIONS="nosuid,nodev,noexec,noatime,nodiratime"; 
DEFAULT_FSCK_OPTIONS="-fn";
DEFAULT_DAILY_SNAP_LIMIT=29;
DEFAULT_WEEKLY_SNAP_LIMIT=51;

# Unset parameters (set within setup())
SOURCE=;
LOOP_DEV=;
CRYPT_DEV=;
SPARSE_IMAGE_FILE=;
MOUNT_DEV=;
DAILY_SNAP_LIMIT=;
WEEKLY_SNAP_LIMIT=;
HOURLY_INTERVAL_SEC=;
DAILY_INTERVAL_SEC=;
WEEKLY_INTERVAL_SEC=;
MOUNT_OPTIONS=;


#-----------------------------------------------------------------------
#------------- LOAD THE CONFIGURATION FILE -----------------------------
#-----------------------------------------------------------------------
. $CONFIG_DIR/setenv.sh;


#-----------------------------------------------------------------------
#------------- FUNCTIONS -----------------------------------------------
#-----------------------------------------------------------------------

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
        echo "`$DATE` [$$] LOG: $*" >> $LOG_FILE;
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
        echo "`$DATE` [$$] WARNING: $*" >> $LOG_FILE;
    fi;
}

logError() {
    if [ $LOG_LEVEL -ge $LOG_ERROR ]; then
        echo "ERROR:  $*";
        echo "`$DATE` [$$] ERROR: $*" >> $LOG_FILE;
    fi;
    exit 1;
}

logFatal() {
    echo "FATAL: $*";
    echo "`$DATE` [$$] FATAL: $*" >> $LOG_FILE;
    $TOUCH $FATAL_LOCK_FILE;
    exit 2;
}

# ----------------------------------------------------------------------
# ------------- MERGED VARIABLES ---------------------------------------
# ----------------------------------------------------------------------
mergeConfig() {

  # Append user mount options to the defaults
  logDebug "mergeUserDefined(): DEFAULT_MOUNT_OPTIONS=$DEFAULT_MOUNT_OPTIONS.";
  if [ $USER_MOUNT_OPTIONS ] ; then
    logDebug "mergeUserDefined(): Using additional USER_MOUNT_OPTIONS=$USER_MOUNT_OPTIONS.";
    MOUNT_OPTIONS="$DEFAULT_MOUNT_OPTIONS,$USER_MOUNT_OPTIONS";
  else
    MOUNT_OPTIONS=$DEFAULT_MOUNT_OPTIONS;
  fi;

  # Check for override DAILY_SNAP_LIMIT and WEEKLY_SNAP_LIMIT
  if [ $DAILY_SNAP_LIMIT ] ; then
    logDebug "mergeUserDefined(): Using override DAILY_SNAP_LIMIT=$DAILY_SNAP_LIMIT.";
  else
    logDebug "mergeUserDefined(): Using default DAILY_SNAP_LIMIT=$DEFAULT_DAILY_SNAP_LIMIT.";
    DAILY_SNAP_LIMIT=$DEFAULT_DAILY_SNAP_LIMIT;
  fi;

  if [ $WEEKLY_SNAP_LIMIT ] ; then
    logDebug "mergeUserDefined(): Using override WEEKLY_SNAP_LIMIT=$WEEKLY_SNAP_LIMIT";
  else
    logDebug "mergeUserDefined(): Using default WEEKLY_SNAP_LIMIT=$DEFAULT_WEEKLY_SNAP_LIMIT.";
    WEEKLY_SNAP_LIMIT=$DEFAULT_WEEKLY_SNAP_LIMIT;
  fi;

  # Computed Time intervals (in seconds)
  # default is one hour, - 10% for cron miss
  if [ $HOUR_INTERVAL ] ; then
    logDebug "mergeUserDefined(): Using override HOUR_INTERVAL=$HOUR_INTERVAL";
  else
    HOUR_INTERVAL=$DEFAULT_HOUR_INTERVAL;
    logDebug "mergeUserDefined(): Using default HOUR_INTERVAL=$DEFAULT_HOUR_INTERVAL";
  fi;
  HOURLY_INTERVAL_SEC=$(($HOUR_SEC * $HOUR_INTERVAL - $HOUR_SEC / 10)); 
  logDebug "mergeUserDefined(): HOURLY_INTERVAL_SEC=$HOURLY_INTERVAL_SEC";

  # default is one day, - 1% for cron miss
  if [ $DAY_INTERVAL ] ; then
    logDebug "mergeUserDefined(): Using override DAY_INTERVAL=$DAY_INTERVAL";
  else
    DAY_INTERVAL=$DEFAULT_DAY_INTERVAL;
    logDebug "mergeUserDefined(): Using default DAY_INTERVAL=$DEFAULT_DAY_INTERVAL";
  fi;
  DAILY_INTERVAL_SEC=$(($DAY_SEC * $DAY_INTERVAL - $DAY_SEC / 100)); 
  logDebug "mergeUserDefined(): DAILY_INTERVAL_SEC=$DAILY_INTERVAL_SEC";

  # default is one week, - 1% for cron miss
  if [ $WEEK_INTERVAL ] ; then
    logDebug "mergeUserDefined(): Using override WEEK_INTERVAL=$WEEK_INTERVAL";
  else
    WEEK_INTERVAL=$DEFAULT_WEEK_INTERVAL;
    logDebug "mergeUserDefined(): Using default WEEK_INTERVAL=$DEFAULT_WEEK_INTERVAL";
  fi;
  WEEKLY_INTERVAL_SEC=$(($WEEK_SEC * $WEEK_INTERVAL - $WEEK_SEC / 100));
  logDebug "mergeUserDefined(): WEEKLY_INTERVAL_SEC=$WEEKLY_INTERVAL_SEC";

}

#-----------------------------------------------------------------------
# checkUser()
#    make sure we're running as root
#-----------------------------------------------------------------------
checkUser() {
  logInfo "checkUser(): Beginning checkUser...";
  if (( `$ID -u` != 0 )); then 
    logError "checkUser(): Sorry, must be root; exiting."; 
  else
    logDebug "checkUser(): User is root, proceeding...";
  fi;
  logInfo "checkUser(): Done.";
}

#-----------------------------------------------------------------------
# checkFields()
#    ensure that required fields are set
#-----------------------------------------------------------------------
checkFields() {
  if [ $IMAGE_SIZE ] ; then
    logDebug "checkFields(): IMAGE_SIZE is set.";
  else
    logError "checkFields(): IMAGE_SIZE is not set; exiting.";
  fi;

  if [ $IMAGE_FS_TYPE ] ; then
    logDebug "checkFields(): IMAGE_FS_TYPE is set.";
  else
    logError "checkFields(): IMAGE_FS_TYPE is not set; exiting.";
  fi;

  if [ "$SPARSE_IMAGE_MOUNT" ] ; then
    logDebug "checkFields(): SPARSE_IMAGE_MOUNT is set.";
  else
    logError "checkFields(): SPARSE_IMAGE_MOUNT is not set; exiting.";
  fi;

  if [ "$SPARSE_IMAGE_DIR" ] ; then
    logDebug "checkFields(): SPARSE_IMAGE_DIR is set.";
  else
    logError "checkFields(): SPARSE_IMAGE_DIR is not set; exiting.";
  fi;

  if [ $ENCRYPT = yes ] ; then
    if [ $PASSPHRASE ] ; then
      logInfo "checkFields(): Encrypting snapshot data.";
    else
      logError "checkFields(): User specified encryption, but no PASSPHRASE; exiting."
    fi;
  fi;
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
      PID=`$CAT ${LOCK_FILE}`;
      logDebug "getLock():Checking for running instance of script with PID $PID";
      logTrace "getLock(): $TEST_PROCESS ${PID} > /dev/null 2>&1";
      if $TEST_PROCESS ${PID} > /dev/null 2>&1; then
          # check name as well
          logError "getLock():Found running instance with PID=$PID; exiting.";
      else
          logDebug "getLock():Process $PID not found; deleting stale lockfile $LOCK_FILE";
          logTrace "getLock(): $RM $LOCK_FILE >> $LOG_FILE 2>&1";
          $RM $LOCK_FILE >> $LOG_FILE 2>&1;
      fi;
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

#-----------------------------------------------------------------------
# checkHourlyInterval()
#    Make sure we don't perform an hourly snapshot prematurely
#-----------------------------------------------------------------------
checkHourlyInterval() {
  logInfo "checkHourlyInterval(): Beginning checkHourlyInterval";
  if [ $HOURLY_LAST -a -f $HOURLY_LAST -a -s $HOURLY_LAST ] ; then
    LAST=$($CAT $HOURLY_LAST);
    if (( $NOW_SEC < $(($LAST + $HOURLY_INTERVAL_SEC)) )) ; then
      logInfo "checkHourlyInterval(): Will not perform hourly rotate; last hourly rotate occurred within $HOUR_INTERVAL hours.";
      PERFORM_HOURLY_SNAPSHOT=no;
    else
      logInfo "checkHourlyInterval(): Will perform hourly snapshot.";
    fi;
  else
    logInfo "checkHourlyInterval(): File $HOURLY_LAST not found; will attempt hourly snapshot.";
  fi;
  logInfo "checkHourlyInterval(): Done.";
}

#-----------------------------------------------------------------------
# checkDaillyInterval()
#    Make sure we don't perform a daily rotate prematurely
#-----------------------------------------------------------------------
checkDailyInterval() {
  logInfo "checkDailyInterval(): Beginning checkDailyInterval...";
  if [ $DAILY_LAST -a -f $DAILY_LAST -a -s $DAILY_LAST ] ; then
    LAST=$($CAT $DAILY_LAST);
    if (( $NOW_SEC < $(($LAST + $DAILY_INTERVAL_SEC)) )) ; then
      logInfo "checkDailyInterval(): Will not perform daily rotate; last daily rotate occurred within $DAY_INTERVAL day(s)";
      PERFORM_DAILY_ROTATE=no;
    else
      logInfo "checkDailyInterval(): Will perform daily rotate.";
    fi;
  else
    logInfo "checkDailyInterval(): File $DAILY_LAST not found; will attempt daily rotate.";
  fi;
  logInfo "checkDailyInterval(): Done.";
}

#-----------------------------------------------------------------------
# checkWeeklyInterval()
#    Make sure we don't perform a weekly rotate prematurely
#-----------------------------------------------------------------------
checkWeeklyInterval() {
  logInfo "checkWeeklyInterval(): Beginning checkWeeklyInterval...";
  if [ $WEEKLY_LAST -a -f $WEEKLY_LAST -a -s $WEEKLY_LAST ] ; then
    LAST=$($CAT $WEEKLY_LAST);
    if (( $NOW_SEC < $(($LAST + $WEEKLY_INTERVAL_SEC)) )) ; then
      logInfo "checkWeeklyInterval(): Will not perform weekly rotate; last weekly rotate occurred within $WEEK_INTERVAL week(s).";
      PERFORM_WEEKLY_ROTATE=no;
    else
      logInfo "checkWeeklyInterval(): Will perform weekly rotate.";
    fi;
  else
    logInfo "checkWeeklyInterval(): File $WEEKLY_LAST not found; will attempt weekly rotate.";
  fi;
  logInfo "checkWeeklyInterval(): Done.";
}

#-----------------------------------------------------------------------
# createSparseImage()
#    Create a sparse disk image (sparse file, with partition table and 
#    user specified file system (ext4 > ext3)) and record its name.
#    The name format is $HOSTNAME.$HASH($HOSTNAME+$RANDOM+$DATE).raw.
#    Once created, make it available via /dev/mapper via kparx.
#-----------------------------------------------------------------------
createSparseImage() {
  logInfo "createSparseImage(): Creating new sparse image file for snapshots...";

  logTrace "createSparseImage(): GUID=$HOSTNAME$RANDOM$DATE -u +%s";
  #GUID="`$HOSTNAME`$RANDOM`$DATE -u +%s`";
  GUID="$RANDOM`$DATE -u +%s`";

  #logTrace "createSparseImage(): GUID=$ECHO $GUID | $HASH";
  #GUID=`$ECHO $GUID | $HASH`;

  #logTrace "createSparseImage(): GUID=$ECHO $GUID | $CUT -d' ' -f1";
  #GUID=`$ECHO $GUID | $CUT -d' ' -f1`;

  SPARSE_IMAGE_FILE=`$HOSTNAME`.$GUID;
  if [ $ENCRYPT = yes ] ; then
    SPARSE_IMAGE_FILE=$SPARSE_IMAGE_FILE.crypt;
  else
    SPARSE_IMAGE_FILE=$SPARSE_IMAGE_FILE.raw;
  fi;

  logInfo "createSparseImage(): Initializing image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE...";
  logDebug "createSparseImage(): Creating file...";
  logTrace "createSparseImage(): $DD if=/dev/zero of=$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE bs=1 count=1 seek=$IMAGE_SIZE  >> $LOG_FILE 2>&1";
  `$DD if=/dev/zero of=$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE bs=1 count=1 seek=$IMAGE_SIZE  >> $LOG_FILE 2>&1`;
  if [ $? -ne 0 ] ; then
      logError "createSparseImage(): Unable to create sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE; exiting.";
  fi;
  logDebug "createSparseImage(): File creation complete.";
  `$ECHO "$SPARSE_IMAGE_FILE" > $SPARSE_IMAGE_STOR`;

  logDebug "createSparseImage(): Attaching $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE to loop...";
  logTrace "createSparseImage(): $LOSETUP -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
  `$LOSETUP -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE >> $LOG_FILE 2>&1`;
  if [ $? -ne 0 ] ; then
    logError "createSparseImage(): $LOSETUP -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE call failed; check $LOSETUP -a for available loop devices; consider rebooting to reset loop devs.";
  fi;

  logTrace "createSparseImage(): $LOSETUP -a | $GREP $SPARSE_IMAGE_FILE | $CUT -d':' -f1";
  LOOP_DEV=`$LOSETUP -a | $GREP $SPARSE_IMAGE_FILE | $CUT -d':' -f1`;
  logDebug "createSparseImage(): Attached $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE to $LOOP_DEV";
  $ECHO "$LOOP_DEV" > $LOOP_DEV_STOR;
  MOUNT_DEV=$LOOP_DEV;

  if [ $ENCRYPT = yes ] ; then
    logDebug "createSparseImage(): Enryption requested; using $CRYPTSETUP.";
    logTrace "createSparseImage(): $CRYPTSETUP luksFormat --batch-mode $LOOP_DEV >> $LOG_FILE 2>&1";
    `$ECHO $PASSPHRASE | $CRYPTSETUP luksFormat --batch-mode $LOOP_DEV >> $LOG_FILE 2>&1`;
    if [ $? -ne 0 ] ; then
      logFatal "createSparseImage(): Unable to encrypt $LOOP_DEV using $CRYPTSETUP; exiting.";
    fi;
    logTrace "createSparseImage(): $CRYPTSETUP luksOpen $LOOP_DEV $SPARSE_IMAGE_FILE >> $LOG_FILE 2>&1";
    `$ECHO $PASSPHRASE | $CRYPTSETUP luksOpen $LOOP_DEV $SPARSE_IMAGE_FILE >> $LOG_FILE 2>&1`;
    if [ $? -ne 0 ] ; then
      logError "createSparseImage(): Unable to map $LOOP_DEV to /dev/mapper/$SPARSE_IMAGE_FILE using $CRYPTSETUP; exiting.";
    fi;
    CRYPT_DEV="/dev/mapper/$SPARSE_IMAGE_FILE"; # prefix is constant
    $ECHO "$CRYPT_DEV" > $CRYPT_DEV_STOR;
    MOUNT_DEV=$CRYPT_DEV;
  fi;

  logDebug "createSparseImage(): Creating $IMAGE_FS_TYPE fs on $MOUNT_DEV...";
  logTrace "createSparseImage(): $MKFS -t $IMAGE_FS_TYPE $MOUNT_DEV";
  $MKFS -t $IMAGE_FS_TYPE $MOUNT_DEV;
  if [ $? -ne 0 ] ; then
      logFatal "createSparseImage(): Unable to create filesystem $IMAGE_FS_TYPE on $MOUNT_DEV; exiting.";
  fi;
  logDebug "createSparseImage(): Filesystem creation complete.";


  if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
    logDebug "createSparseImage(): Creating mount point $SPARSE_IMAGE_MOUNT...";
    logTrace "createSparseImage(): $MKDIR -p $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1";
    `$MKDIR -p $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1`;
    if [ $? -ne 0 ] ; then
        logError "createSparseImage(): Unable to create mount point $SPARSE_IMAGE_MOUNT; exiting.";
    fi;
    logDebug "createSparseImage(): Mount point creation done.";
  fi;

  logInfo "createSparseImage(): Done.";
}

#-----------------------------------------------------------------------
# setupLoopDevice()
#    After a (re)boot, no loopback devices are preserved. This function
#    attempts to check for an existing sparse diskimage mapping and will
#    create one if it doesn't exist. This must happen before mounting.
#-----------------------------------------------------------------------
setupLoopDevice() {
  if [ ! $LOOP_DEV ] ; then
    if [ $LOOP_DEV_STOR -a -f $LOOP_DEV_STOR -a -s $LOOP_DEV_STOR ] ; then
      LOOP_DEV=$($CAT $LOOP_DEV_STOR);
      logDebug "setupLoopDevice(): Read loop device from file ($LOOP_DEV)";
    else
      logError "setupLoopDevice(): Could not read loop device from file $LOOP_DEV_STOR; exiting.";
    fi;
  fi;
  
  logTrace "setupLoopDevice(): LOOP_EXISTS=$LOSETUP -a | $GREP $SPARSE_IMAGE_FILE | $GREP $LOOP_DEV | $WC -c";
  LOOP_EXISTS=`$LOSETUP -a | $GREP $SPARSE_IMAGE_FILE | $GREP "$LOOP_DEV" | $WC -c`;

  if [ $LOOP_EXISTS = 0 ] ; then
    logDebug "setupLoopDevice(): Attaching $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE to loop...";
    logTrace "setupLoopDevice(): $LOSETUP -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
    `$LOSETUP -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE`;
    if [ $? -ne 0 ] ; then
      logError "setupLoopDevice(): $LOSETUP -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE call failed; check $LOSETUP -a for available loop devices; consider rebooting to reset loop devs.";
    fi;

    logTrace "setupLoopDevice(): $LOSETUP -a | $GREP $SPARSE_IMAGE_FILE | $CUT -d':' -f1";
    LOOP_DEV=`$LOSETUP -a | $GREP $SPARSE_IMAGE_FILE | $CUT -d':' -f1`;

    logDebug "setupLoopDevice(): Attached $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE to $LOOP_DEV";
    $ECHO "$LOOP_DEV" > $LOOP_DEV_STOR;
  else
    logDebug "setupLoopDevice(): $LOOP_DEV appears to exist, skipping.";
  fi;
  MOUNT_DEV=$LOOP_DEV;
  

  if [ $ENCRYPT = yes ] ; then
    if [ ! $CRYPT_DEV ] ; then
      if [ $CRYPT_DEV_STOR -a -f $CRYPT_DEV_STOR -a -s $CRYPT_DEV_STOR ] ; then
        CRYPT_DEV=$($CAT $CRYPT_DEV_STOR);
        logDebug "setupLoopDevice(): Read loop device from file ($CRYPT_DEV)";
      else
        logError "setupLoopDevice(): Could not read loop device from file $CRYPT_DEV_STOR; exiting.";
      fi;
    fi;
    if [ ! -e $CRYPT_DEV ] ; then
      logDebug "setupLoopDevice(): Enryption requested; using $CRYPTSETUP to setup mapping.";
      logTrace "setupLoopDevice(): $CRYPTSETUP luksOpen $LOOP_DEV $SPARSE_IMAGE_FILE >> $LOG_FILE 2>&1";
      `$ECHO $PASSPHRASE | $CRYPTSETUP luksOpen $LOOP_DEV $SPARSE_IMAGE_FILE >> $LOG_FILE 2>&1`;
      if [ $? -ne 0 ] ; then
        logError "setupLoopDevice(): Unable to map $LOOP_DEV to /dev/mapper/$SPARSE_IMAGE_FILE using $CRYPTSETUP; exiting.";
      fi;
      CRYPT_DEV="/dev/mapper/$SPARSE_IMAGE_FILE"; # prefix is constant
      $ECHO "$CRYPT_DEV" > $CRYPT_DEV_STOR;
    else
      logDebug "setupLoopDevice(): $CRYPT_DEV appears to exist, skipping.";
    fi;
    MOUNT_DEV=$CRYPT_DEV;
  fi;

  logInfo "setupLoopDevice(): $MOUNT_DEV is ready.";
}

#-----------------------------------------------------------------------
# filesystemCheck()
#    Make sure that the fs is clean. If not, don't attempt repair, but 
#    logFatal and exit(2).
#-----------------------------------------------------------------------
filesystemCheck() {
  logInfo "filesystemCheck(): Starting file system check (repairs will NOT be attempted)...";
  logDebug "filesystemCheck(): Determining if $SPARSE_IMAGE_MOUNT is mounted";
  MOUNT_EXISTS=`$MOUNT | $GREP $SPARSE_IMAGE_MOUNT | $WC -c`;
  if [ $MOUNT_EXISTS != 0 ] ; then
    logDebug "filesystemCheck(): Unmounting filesystem $SPARSE_IMAGE_MOUNT";
    logTrace "filesystemCheck(): $UMOUNT $SPARSE_IMAGE_MOUNT";
    `$UMOUNT $SPARSE_IMAGE_MOUNT >> $LOG_FILE 2>&1`;
    if [ $? -ne 0 ] ; then
        logError "filesystemCheck(): Unable to $UMOUNT $SPARSE_IMAGE_MOUNT; exiting...";
    fi;
  fi;

  logDebug "filesystemCheck(): Checking file system $MOUNT_DEV";
  logTrace "filesystemCheck(): $FSCK $DEFAULT_FSCK_OPTIONS $MOUNT_DEV";
  `$FSCK $DEFAULT_FSCK_OPTIONS $MOUNT_DEV >> $LOG_FILE 2>&1`;
  if [ $? -ne 0 ] ; then
      logFatal "filesystemCheck(): $FSCK reported errors on $MOUNT_DEV; check $LOG_FILE and manually repair this voume; exiting...";
  fi;
  logInfo "filesystemCheck(): File system check complete; $MOUNT_DEV is clean.";
}

#-----------------------------------------------------------------------
# mountSparseImageRW()
#    Attempt to remount the sparse image to its mount point as 
#    read-write; If unable to do so, exit(1).
#-----------------------------------------------------------------------
mountSparseImageRW() {
  setupLoopDevice;
  logInfo "mountSparseImageRW(): Re-mounting $MOUNT_DEV to $SPARSE_IMAGE_MOUNT in readwrite...";
  if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
      logError "mountSparseImageRW(): Mount point $SPARSE_IMAGE_MOUNT does not exist; exiting.";
  fi;

  if [ $PERFORM_WEEKLY_ROTATE = yes ] ; then
    logInfo "mountSparseImageRW(): Performing weekly file system check...";
    filesystemCheck;
  else
    logInfo "mountSparseImageRW(): Skipping weekly file system check...";
  fi

  logDebug "mountSparseImageRW(): Attempting remount...";
  logTrace "mountSparseImageRW(): $MOUNT -t $IMAGE_FS_TYPE -o remount,rw,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1";
  `$MOUNT -t $IMAGE_FS_TYPE -o remount,rw,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1`;
  if [ $? -ne 0 ] ; then
      logWarn "mountSparseImageRW(): Trying without -o remount";
      logTrace "mountSparseImageRW(): $MOUNT -t $IMAGE_FS_TYPE -o rw,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1";
      `$MOUNT -t $IMAGE_FS_TYPE -o rw,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1`;
      if [ $? -ne 0 ] ; then
        logError "mountSparseImageRW(): Could not re-mount $MOUNT_DEV to $SPARSE_IMAGE_MOUNT readwrite";
      fi;
  fi;
  logDebug "mountSparseImageRW(): Mount complete.";

  logDebug "mountSparseImageRO(): Attempting chmod 700 $SPARSE_IMAGE_MOUNT/*";
  $CHMOD 700 $SPARSE_IMAGE_MOUNT/*;

  logInfo "mountSparseImageRW(): Done.";
}

#-----------------------------------------------------------------------
# mountSparseImageRO()
#    Attempt to (re)mount the sparse image to its mount point as 
#    read-only.
#-----------------------------------------------------------------------
mountSparseImageRO() {
  setupLoopDevice;
  logInfo "mountSparseImageRO(): Re-mounting $MOUNT_DEV to $SPARSE_IMAGE_MOUNT in readonly...";
  if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
      logError "mountSparseImageRO(): Mount point $SPARSE_IMAGE_MOUNT does not exist; exiting.";
  fi;

  logDebug "mountSparseImageRO(): Attempting chmod 755 $SPARSE_IMAGE_MOUNT/*";
  $CHMOD 755 $SPARSE_IMAGE_MOUNT/*;

  logDebug "mountSparseImageRO(): Attempting remount...";
  logTrace "mountSparseImageRO(): $MOUNT -t $IMAGE_FS_TYPE -o remount,ro,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1";
  `$MOUNT -t $IMAGE_FS_TYPE -o remount,ro,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1`;
  if [ $? -ne 0 ] ; then
      logWarn "mountSparseImageRO(): Trying without -o remount";
      logTrace "mountSparseImageRO(): $MOUNT -t $IMAGE_FS_TYPE -o ro,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1";
      `$MOUNT -t $IMAGE_FS_TYPE -o ro,$MOUNT_OPTIONS $MOUNT_DEV $SPARSE_IMAGE_MOUNT  >> $LOG_FILE 2>&1`;
      if [ $? -ne 0 ] ; then
        logError "mountSparseImageRO(): Could not re-mount $MOUNT_DEV to $SPARSE_IMAGE_MOUNT readonly";
      fi;
  fi;
  logDebug "mountSparseImageRO(): Mount complete.";

  logInfo "mountSparseImageRO(): Done.";
}

#-----------------------------------------------------------------------
# pruneWeeklySnapshots()
#    Deletes the $SPARSE_IMAGE_MOUNT/weekly.$WEEKLY_SNAP_LIMIT+1.
#-----------------------------------------------------------------------
pruneWeeklySnapshots() {
  # step 1: delete the oldest weekly snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)) ] ; then
    logDebug "pruneWeeklySnapshots(): Removing weekly.$(($WEEKLY_SNAP_LIMIT+1))...";
    logTrace "pruneWeeklySnapshots(): $RM -rf $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;";
    $RM -rf $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "pruneWeeklySnapshots(): Unable to remove $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "pruneWeeklySnapshots(): Removal complete.";
  fi ;
}

#-----------------------------------------------------------------------
# pruneDailySnapshots()
#    Deletes the $SPARSE_IMAGE_MOUNT/daily.$DAILY_SNAP_LIMIT+1.
#-----------------------------------------------------------------------
pruneDailySnapshots() {
  # step 2: delete the oldest daily snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)) ] ; then
    logDebug "pruneDailySnapshots(): Removing daily.$(($DAILY_SNAP_LIMIT+1))...";
    logTrace "pruneDailySnapshots(): $RM -rf $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;";
    $RM -rf $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "pruneDailySnapshots(): Unable to remove $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "pruneDailySnapshots(): Removal complete.";
  fi ;
}

#-----------------------------------------------------------------------
# pruneHourlySnapshots()
#    Deletes the $SPARSE_IMAGE_MOUNT/hourly.$HOURLY_SNAP_LIMIT+1.
#-----------------------------------------------------------------------
pruneHourlySnapshots() {
  # step #2.5: 
  if [ -d $SPARSE_IMAGE_MOUNT/.hourly.tmp ]; then
    logDebug "pruneHourlySnapshots(): Removing stale instance .hourly.tmp ...";
    logTrace "pruneHourlySnapshots(): \
      $RM -rf $SPARSE_IMAGE_MOUNT/.hourly.tmp >> $LOG_FILE 2>&1";
    $RM -rf $SPARSE_IMAGE_MOUNT/.hourly.tmp >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logError "pruneHourlySnapshots(): remove encountered an error; exiting.";
    fi;
  fi;

  # step 3: delete the oldest hourly snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)) ] ; then
    logDebug "pruneHourlySnapshots(): Removing hourly.$(($HOURLY_SNAP_LIMIT+1))...";
    logTrace "pruneHourlySnapshots(): $RM -rf $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1))";
    $RM -rf $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)) ;
    if [ $? -ne 0 ] ; then
      logFatal "pruneHourlySnapshots(): Unable to remove $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "pruneHourlySnapshots(): Removal of oldest hourly complete complete.";
  fi ;
}

#-----------------------------------------------------------------------
# rotateHourlySnapshot()
#    Operates on the $SPARSE_IMAGE_MOUNT/hourly.[0-$HOURLY_SNAP_LIMIT].
#    Shift hourly snapshots forward by one, then
#      use copy hourly.0 to hourly.1
#-----------------------------------------------------------------------
rotateHourlySnapshot() {
  logInfo "rotateHourlySnapshot(): Beginning rotateHourlySnapshot ...";

  logDebug "rotateHourlySnapshot(): Incrementing hourlies...";
  for (( i=$(($HOURLY_SNAP_LIMIT+1)) ; i>0 ; i-- ))
  do
    # step 1.1: shift the hourly snapshots(s) forward by one, if they exist
    OLD=$(($i-1));
    if [ -d "$SPARSE_IMAGE_MOUNT/hourly.$OLD" ] ; then
      logTrace "rotateHourlySnapshot(): $MV $SPARSE_IMAGE_MOUNT/hourly.$OLD $SPARSE_IMAGE_MOUNT/hourly.$i >> $LOG_FILE 2>&1";
      $MV "$SPARSE_IMAGE_MOUNT/hourly.$OLD" "$SPARSE_IMAGE_MOUNT/hourly.$i" >> $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logFatal "rotateHourlySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/hourly.$OLD; exiting.";
      fi;
    fi;
  done
  logDebug "rotateHourlySnapshot(): Hourly increment complete.";

  # step 1.2: rename the .hourly.tmp dir to hourly.0
  if [ -d "$SPARSE_IMAGE_MOUNT/.hourly.tmp" ] ; then
    logDebug "rotateHourlySnapshot(): Renaming .hourly.tmp to hourly.0 ...";
    logTrace "rotateHourlySnapshot(): $MV $SPARSE_IMAGE_MOUNT/.hourly.tmp $SPARSE_IMAGE_MOUNT/hourly.0" >> $LOG_FILE 2>&1;
    $MV "$SPARSE_IMAGE_MOUNT/.hourly.tmp" "$SPARSE_IMAGE_MOUNT/hourly.0" >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "rotateHourlySnapshot(): Unable to rename $SPARSE_IMAGE_MOUNT/.hourly.tmp to $SPARSE_IMAGE_MOUNT/.hourly.0; exiting.";
    fi;
    logDebug "rotateHourlySnapshot(): Rename complete.";
  else
    logError "rotateHourlySnapshot(): $SPARSE_IMAGE_MOUNT/.hourly.tmp is missing; exiting.";
  fi;


  logInfo "rotateHourlySnapshot(): Done.";
}

#-----------------------------------------------------------------------
# rotateDailySnapshot()
#    Operates on the $SPARSE_IMAGE_MOUNT/dailiy.[0-$DAILY_SNAP_LIMIT].
#    Shift hourly snapshots forward by one, then
#      rename hourly.$HOURLY_SNAP_LIMIT+1 to daily.0
#-----------------------------------------------------------------------
rotateDailySnapshot() {
  logInfo "rotateDailySnapshot(): Beginning rotateDailySnapshot...";

  logDebug "rotateDailySnapshot(): Incrementing dailies...";
  for (( i=$(($DAILY_SNAP_LIMIT+1)) ; i>0 ; i-- ))
  do
    # step 2.1: shift the daily snapshots(s) forward by one, if they exist
    OLD=$(($i-1));
    if [ -d "$SPARSE_IMAGE_MOUNT/daily.$OLD" ] ; then
      logTrace "rotateDailySnapshot(): $MV $SPARSE_IMAGE_MOUNT/daily.$OLD $SPARSE_IMAGE_MOUNT/daily.$i >> $LOG_FILE 2>&1;";
      $MV "$SPARSE_IMAGE_MOUNT/daily.$OLD" "$SPARSE_IMAGE_MOUNT/daily.$i" >> $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logFatal "rotateDailySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/daily.$OLD; exiting.";
      fi;
    fi;
  done
  logDebug "rotateDailySnapshot(): Daily increment complete.";
  # step 2.2: rename hourly.$HOURLY_SNAP_LIMIT into daily.0
  if [ -d "$SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1))" ] ; then
    logDebug "rotateDailySnapshot(): Renaming hourly.$(($HOURLY_SNAP_LIMIT+1)) to daily.0...";
    logTrace "rotateDailySnapshot(): $MV $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)) $SPARSE_IMAGE_MOUNT/daily.0 >> $LOG_FILE 2>&1;";
    $MV "$SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1))" "$SPARSE_IMAGE_MOUNT/daily.0" >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "rotateDailySnapshot(): Unable to rename $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "rotateDailySnapshot(): Rename complete.";
    $TOUCH "$DAILY_LAST";
    $ECHO "`$DATE -u +%s`" > "$DAILY_LAST";
  fi;

  logInfo "rotateDailySnapshot(): Done.";
}

#-----------------------------------------------------------------------
# rotateWeeklySnapshot()
#    Operates on the $SPARSE_IMAGE_MOUNT/weekly.[0-$WEEKLY_SNAP_LIMIT].
#    Shift weekly snapshots forward by one, then
#      rename daily.$DAILY_SNAP_LIMIT+1 to weekly.0
#-----------------------------------------------------------------------
rotateWeeklySnapshot() {
  logInfo "rotateWeeklySnapshot(): Beginning rotateWeeklySnapshot...";

  logDebug "rotateWeeklySnapshot(): Incrementing weeklies...";
  for (( i=$(($WEEKLY_SNAP_LIMIT+1)) ; i>0 ; i-- ))
  do
    # step 3.1: shift the weekly snapshots(s) forward by one, if they exist
    OLD=$(($i-1));
    if [ -d "$SPARSE_IMAGE_MOUNT/weekly.$OLD" ] ; then
      logTrace "rotateWeeklySnapshot(): $MV $SPARSE_IMAGE_MOUNT/weekly.$OLD $SPARSE_IMAGE_MOUNT/weekly.$i >> $LOG_FILE 2>&1;";
      $MV "$SPARSE_IMAGE_MOUNT/weekly.$OLD" "$SPARSE_IMAGE_MOUNT/weekly.$i" >> $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logFatal "rotateWeeklySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/weekly.$OLD; exiting.";
      fi;
    fi;
  done
  logDebug "rotateWeeklySnapshot(): Weekly increment complete";

  # step 3.2: rename daily.$DAILY_SNAP_LIMIT into weekly.0
  if [ -d "$SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1))" ] ; then
    logDebug "rotateWeeklySnapshot(): Renaming daily.$(($DAILY_SNAP_LIMIT+1)) to weekly.0...";
    logTrace "rotateWeeklySnapshot(): $MV $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)) $SPARSE_IMAGE_MOUNT/weekly.0 >> $LOG_FILE 2>&1;";
    $MV "$SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1))" "$SPARSE_IMAGE_MOUNT/weekly.0" >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "rotateWeeklySnapshot(): Unable to rename $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "rotateWeeklySnapshot(): Rename complete.";
    $TOUCH "$WEEKLY_LAST";
    $ECHO "`$DATE -u +%s`" > "$WEEKLY_LAST";
  fi;

  logInfo "rotateWeeklySnapshot(): Done.";
}

#-----------------------------------------------------------------------
# makeHourlySnapshot()
#   rsync $SOURCE into $SPARSE_IMAGE_MOUNT/hourly.0 updating and 
#   deleting changed files. Notice that rsync behaves like 
#   `cp --remove-destination` by default, so the destinationis unlinked
#   first.  If it were not so, this would copy over the other snapshot(s)
#   too! Also note the `--exclude-from` argument: rsync will ignore
#   files/dirs in $EXCLUDES/$SOURCE.exclude; so each entry within 
#   $INCLUDE should have a corresponsing .exclude (replacing '/' with 
#   '.')file.
#
#   !!! $SOURCE must be setup by calling function. !!!
#-----------------------------------------------------------------------
makeHourlySnapshot() {
  logInfo "makeHourlySnapshot(): Beginning makeHourlySnapshot...";

  # step 1: define rsync options
  RSYNC_OPTS="--archive --xattrs --acls --sparse --partial --delete --delete-excluded";

  if [ $LOG_LEVEL -ge $LOG_INFO ] ; then
    RSYNC_OPTS="--stats $RSYNC_OPTS";
  fi;

  if [ $LOG_LEVEL -ge $LOG_DEBUG ] ; then
    RSYNC_OPTS="--verbose $RSYNC_OPTS";
  fi;

  if [ $LOG_LEVEL -ge $LOG_TRACE ] ; then
    RSYNC_OPTS="--progress $RSYNC_OPTS";
  fi;

  # step 1.5: create the $SPARSE_IMAGE_MOUNT/.hourly.tmp directory 
  # and make it read/write for root only.
  if [ ! -d "$SPARSE_IMAGE_MOUNT/.hourly.tmp" ]; then
    logDebug "makeHourlySnapshot(): $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE does not exist; creating ...";
    logTrace "makeHourlySnapshot(): \ 
      $MKDIR -p "$SPARSE_IMAGE_MOUNT/.hourly.tmp" >> $LOG_FILE 2>&1;";
    $MKDIR -p "$SPARSE_IMAGE_MOUNT/.hourly.tmp" >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logError "makeHourlySnapshot(): Unable to create $SPARSE_IMAGE_MOUNT/.hourly.tmp; exiting.";
    fi;
  fi;
  $CHMOD 700 "$SPARSE_IMAGE_MOUNT/.hourly.tmp"; 

  # Perform all $SOURCE based logic in this block
  exec 3<&0;
  exec 0<"$INCLUDES";
  while read -r SOURCE;
  do
    logInfo "makeHourlySnapshot(): Taking snapshot of /$SOURCE...";

    # step 2.5: cp -al $SPARSE_IMAGE_MOUNT/hourly.0 to $SPARSE_IMAGE_MOUNT/hourly.tmp
    if [ ! -d "$SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE" ]; then
      logDebug "makeHourlySnapshot(): $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE does not exist; creating ...";
      logTrace "makeHourlySnapshot(): \ 
        $MKDIR -p $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE >> $LOG_FILE 2>&1;";
      $MKDIR -p "$SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE" >> $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logError "makeHourlySnapshot(): Unable to create $SPARSE_IMAGE_MOUNT/.hourly.tmp; exiting.";
      fi;
    fi;

    if [ -d "$SPARSE_IMAGE_MOUNT/hourly.0/$SOURCE" ]; then
      logDebug "makeHourlySnapshot(): Performing copy of $SPARSE_IMAGE_MOUNT/hourly.0/$SOURCE to  $SPARSE_IMAGE_MOUNT/.hourly.tmp/ ...";
      logTrace "makeHourlySnapshot(): \
        $CP -al $SPARSE_IMAGE_MOUNT/hourly.0/$SOURCE/ $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE/../ >> $LOG_FILE 2>&1";
      $CP -al $SPARSE_IMAGE_MOUNT/hourly.0/$SOURCE/ $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE/../ >>  $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logError "makeHourlySnapshot(): copy encountered an error; exiting.";
      fi;
      logDebug "makeHourlySnapshot(): copy complete.";
    fi;

    # step 1: extrapolate the exclude filename from $SOURCE
    EXCLUDE_FILE=`$ECHO "$SOURCE" | $SED "s/\//./g"`
    EXCLUDE_FILE=$EXCLUDE_FILE.exclude
    RSYNC_OPTS="$RSYNC_OPTS --exclude-from=$EXCLUDE_DIR/$EXCLUDE_FILE";

    # step #3: perform the rsync
    logDebug "makeHourlySnapshot(): Performing rsync...";
    logTrace "makeHourlySnapshot(): \
      $RSYNC $RSYNC_OPTS /$SOURCE/ $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE/ >> $LOG_FILE 2>&1";
    $RSYNC $RSYNC_OPTS "/$SOURCE/" "$SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE/" >>  $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logWarn "makeHourlySnapshot(): rsync encountered an error; continuing ...";
    fi;
    logDebug "makeHourlySnapshot(): rsync complete.";

    logInfo "makeHourlySnapshot(): Completed snapshot of /$SOURCE.";
  done;
  exec 0<&3;

  # step 4: update the mtime of hourly.0 to reflect the snapshot time
  logTrace "makeHourlySnapshot(): $TOUCH $SPARSE_IMAGE_MOUNT/.hourly.tmp";
  $TOUCH "$SPARSE_IMAGE_MOUNT/.hourly.tmp";
  
  # step 5: update the hourly timestamp with current time
  $TOUCH $HOURLY_LAST;
  $ECHO "`$DATE -u +%s`" > $HOURLY_LAST;

  logInfo "makeHourlySnapshot(): Done.";
}

#-----------------------------------------------------------------------
#------------- ORCHESTRATING FUNCTIONS ---------------------------------
#-----------------------------------------------------------------------

#-----------------------------------------------------------------------
# setup()
#    Grouping of setup tasks (user check, sparse image creation, interval 
#    checking, etc.)
#-----------------------------------------------------------------------
setup() {

  logInfo "setup(): Beginning setup ...";
  mergeConfig;
  checkUser;
  checkFields;

  if [ "$IMAGE_FS_TYPE" == "btrfs" ] ; then
    logWarn "setup(): Using ***EXPERIMENTAL*** filesystem, btrfs."
    . $SNAPSHOT_BTRFS;
  elif [ "$IMAGE_FS_TYPE" == "hfs" ] ; then
    logWarn "setup(): Using HFS+ filesystem."
    . $SNAPSHOT_HFS;
  elif [ "$IMAGE_FS_TYPE" == maczfs ] ; then
    logWarn "setup(): Using ZFS filesystem."
    . $SNAPSHOT_MACZFS;
  fi;

  getLock;

  if [ "$SPARSE_IMAGE_STOR" -a -f "$SPARSE_IMAGE_STOR" -a -s "$SPARSE_IMAGE_STOR" ] ; then
    SPARSE_IMAGE_FILE=$($CAT $SPARSE_IMAGE_STOR);
    logDebug "setup(): $SPARSE_IMAGE_STOR defines $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE for storage.";
  else
    logDebug "setup(): No sparse image file defined ($SPARSE_IMAGE_STOR); creating new...";
    createSparseImage;
  fi;

  if [ "$SPARSE_IMAGE_DIR" -a -d "$SPARSE_IMAGE_DIR" ] ; then
    logDebug "setup(): Sparse image directory $SPARSE_IMAGE_DIR exists.";
  else
    logError "setup(): Sparse image directory $SPARSE_IMAGE_DIR not found (is its device mounted?); exiting.";
  fi;

  # on Macs, sparsebundle is a directory so need -f OR -d "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE"
  if [ "$SPARSE_IMAGE_DIR" -a "$SPARSE_IMAGE_FILE" -a -f "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE" -a -s "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE" ] ; then
    logDebug "setup(): Sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE exists.";
  elif [ "$SPARSE_IMAGE_DIR" -a "$SPARSE_IMAGE_FILE" -a -d "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE" ] ; then
    logDebug "setup(): Sparsebundle dir $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE exists.";
  else
    logError "setup(): Sparse image file  $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE not found - verify contents of $SPARSE_IMAGE_STOR and remove that file if no longer valid; exiting.";
  fi;

  logInfo "setup(): Using sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";

  checkIntervals;

  mountSparseImageRW;

  if [ $INCLUDES -a -f $INCLUDES -a -s $INCLUDES ] ; then
    logDebug "setup(): Source listing present; proceeding.";
  else
    logError "setup(): Source listing is empty; verify entries in $INCLUDES; exiting.";
  fi;

  logInfo "setup(): Done.";
}

#-----------------------------------------------------------------------
# checkIntervals()
#   Function which coordindates the various interval checking functions.
#-----------------------------------------------------------------------
checkIntervals() {
  checkWeeklyInterval;
  checkDailyInterval;
  checkHourlyInterval;
}

#-----------------------------------------------------------------------
# rotateSnapshots()
#    Function responsible for overal orchestration of rotation functions 
#    when when performing a backup. The order of operations is important 
#    due to copies and renames which take place: 
#      1) rotate hourlies; 
#      2) rotate dailies;
#      3) rotate weeklies;
#-----------------------------------------------------------------------
rotateSnapshots() {
  logInfo "rotateSnapshots(): Rotating snapshots...";

  #---------- 1. INCREMENT HOURLIES ------------------------------------
  if [ $PERFORM_HOURLY_SNAPSHOT = yes ] ; then
    logInfo "rotateSnapshots(): Performing hourly snapshot creation...";
    rotateHourlySnapshot;
  else
    logInfo "rotateSnapshots(): Skipping hourly snapshot creation...";
  fi

  #---------- 2. INCREMENT DAILIES -------------------------------------
  if [ $PERFORM_DAILY_ROTATE = yes ] ; then
    logInfo "rotateSnapshots(): Performing daily snapshot rotatation...";
    rotateDailySnapshot;
  else
    logInfo "rotateSnapshots(): Skipping daily snapshot rotatation...";
  fi

  #---------- 3. INCREMENT WEEKLIES ------------------------------------
  if [ $PERFORM_WEEKLY_ROTATE = yes ] ; then
    logInfo "rotateSnapshots(): Performing weekly snapshot rotatation...";
    rotateWeeklySnapshot;
  else
    logInfo "rotateSnapshots(): Skipping weekly snapshot rotatation...";
  fi

  logInfo "rotateSnapshots(): Snapshot rotation complete.";
}

#-----------------------------------------------------------------------
# pruneSnapshots()
#    Function responsible for overal orchestration of other type-specific
#    snapshots. The order of operations is important:
#      1) prune weeklies; 
#      2) prune dailies;
#      3) prune hourlies;
#-----------------------------------------------------------------------
pruneSnapshots() {
  logInfo "pruneSnapshots(): Pruning old snapshots...";

  pruneWeeklySnapshots;

  pruneDailySnapshots;

  pruneHourlySnapshots;

  logInfo "pruneSnapshots(): Prune complete.";
}

#-----------------------------------------------------------------------
# teardown()
#    delete $LOCK_FILE and mount readonly
#-----------------------------------------------------------------------
teardown() {
  logInfo "teardown(): Beginning teardown ...";

  mountSparseImageRO;

  logDebug "teardown(): Removing lock file $LOCK_FILE..."
  $RM $LOCK_FILE
  
  logDebug "teardown(): Syncing filesystem...";
  $SYNC; #ensure that changes to the backup imsage file are written-out

  logInfo "teardown(): Done.";
}

#-----------------------------------------------------------------------
# main()
#    Function responsible for overal orchestration of other functions 
#    when when performing a backup. The order of operations is important 
#    due to copies and renames which take place: 
#      1) prune; 
#      2) rotate;
#      3) take hourly snapshots;
#      4) prune;
#    Note that each entry in the $INCLUDES is backed up in this order 
#    serially (otherwise we'd create I/O contention).
#-----------------------------------------------------------------------
main() {

  logLog "Backup starting...";
  
  setup;

  pruneSnapshots;

  if [ $PERFORM_HOURLY_SNAPSHOT = yes ] ; then
    logInfo "main(): Performing hourly snapshot creation...";
    makeHourlySnapshot;
    rotateSnapshots;
    pruneSnapshots;
  else
    logInfo "main(): Skipping hourly snapshot creation...";
  fi

  teardown;
  
  logLog "Backup complete.";
  
  exit 0;
}

#------------------------------------------------------------------------------
# RUN!
#------------------------------------------------------------------------------
main;
