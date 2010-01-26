#!/bin/bash
# ----------------------------------------------------------------------
# snapshot
# ----------------------------------------------------------------------
# Creates a rotating snapshot of the contents of $INCLUDES whenever 
# called (minus the contents of the .exlude files). Snapshots are 
# written to a specified sparse disk image hosted file system (via 
# loopback) for portability. If the filesystem on the disk image 
# supports it, space is preserved via hardlinks.
# ----------------------------------------------------------------------
# Copyright (C) 2010  Jonathan Edwards
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the 
# Free Software Foundation, Inc., 
# 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
# ----------------------------------------------------------------------

unset PATH

# ----------------------------------------------------------------------
# ------------- COMMANDS --------------------
# Include external commands here for portability
# ----------------------------------------------------------------------
CAT=/bin/cat;
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
KILL=/bin/kill;
LOSETUP=/sbin/losetup;
LPWD=/bin/pwd;
MKDIR=/bin/mkdir;
MKFS=/sbin/mkfs;
MOUNT=/bin/mount;
MV=/bin/mv;
RM=/bin/rm;
RSYNC=/usr/bin/rsync;
SED=/bin/sed;
SYNC=/bin/sync;
TOUCH=/bin/touch;
WC=/usr/bin/wc;

# If we need encryption
CRYPTSETUP=/sbin/cryptsetup

# The semantics of kill can differ; either -n (Ubuntu) or -s (RHEL/Centos)
# Make appropriate change here.
TEST_PROCESS="$KILL -n 0";

# ----------------------------------------------------------------------
# ------------- GLOBAL VARIABLES ---------------------------------------
# ----------------------------------------------------------------------
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
LOCK_FILE=$LOCK_DIR/pid.lock;
FATAL_LOCK_FILE=$LOCK_DIR/fatal.lock;

# Log file (may be tmpfs so aren't persistent)
LOG_FILE=/var/log/snapshot.log;

# Rotation variables
PERFORM_HOURLY_SNAPSHOT=yes;
PERFORM_DAILY_ROTATE=yes;
PERFORM_WEEKLY_ROTATE=yes;

# Remember, snap counts start at 0
HOURLY_SNAP_LIMIT=23;
DAILY_SNAP_LIMIT=29;
WEEKLY_SNAP_LIMIT=51;

# Time definitions
NOW_SEC=`$DATE -u +%s`; # the current time
HOUR_SEC=$((60 * 60)); # seconds per hourl
DAY_SEC=$(($HOUR_SEC * 24)); # seconds per day
WEEK_SEC=$(($DAY_SEC * 7));

# LOGGING levels
LOG_TRACE=5;
LOG_DEBUG=4;
LOG_INFO=3;
LOG_WARN=2;
LOG_ERROR=1;
LOG_FATAL=0;

# Default mounting options
DEFAULT_MOUNT_OPTIONS="nosuid,nodev,noexec,noatime,nodiratime"; 

# Unset parameters (set within setup())
SOURCE=;
LOOP_DEV=;
CRYPT_DEV=;
SPARSE_IMAGE_FILE=;
MOUNT_DEV=;

# ----------------------------------------------------------------------
# ------------- SOURCE USER-DEFINED VARIABLES ---------------------------------------
# ----------------------------------------------------------------------
. $CONFIG_DIR/setenv.sh;


# ----------------------------------------------------------------------
# ------------- MERGED VARIABLES ---------------------------------------
# ----------------------------------------------------------------------

# Append user mount options to the defaults
MOUNT_OPTIONS="$DEFAULT_MOUNT_OPTIONS,$USER_MOUNT_OPTIONS";

# Computed Time intervals (in seconds)
# default is one hour, - 10% for cron miss
HOURLY_INTERVAL_SEC=$(($HOUR_SEC * $HOUR_INTERVAL - $HOUR_SEC / 10)); 
# default is one day, - 1% for cron miss
DAILY_INTERVAL_SEC=$(($DAY_SEC * $DAY_INTERVAL - $DAY_SEC / 100)); 
# default is one week, - 1% for cron miss
WEEKLY_INTERVAL_SEC=$(($WEEK_SEC * $WEEK_INTERVAL - $WEEK_SEC / 100));

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

#------------------------------------------------------------------------------
# checkUser()
#    make sure we're running as root
#------------------------------------------------------------------------------
checkUser() {
  logInfo "checkUser(): Beginning checkUser...";
  if (( `$ID -u` != 0 )); then 
    logError "checkUser(): Sorry, must be root; exiting."; 
  else
    logDebug "checkUser(): User is root, proceeding...";
  fi;
  logInfo "checkUser(): Done.";
}

#------------------------------------------------------------------------------
# checkFields()
#    ensure that required fields are set
#------------------------------------------------------------------------------
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

  if [ $SPARSE_IMAGE_MOUNT ] ; then
    logDebug "checkFields(): SPARSE_IMAGE_MOUNT is set.";
  else
    logError "checkFields(): SPARSE_IMAGE_MOUNT is not set; exiting.";
  fi;

  if [ $SPARSE_IMAGE_DIR ] ; then
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

#------------------------------------------------------------------------------
# getLock()
#    Check for or create PID-based lockfile; if it exists note its presence and
#    exit(1) to avoid running multiple backups simultaneously.
#------------------------------------------------------------------------------
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

#------------------------------------------------------------------------------
# checkHourlyInterval()
#    Make sure we don't perform an hourly snapshot prematurely
#------------------------------------------------------------------------------
checkHourlyInterval() {
  logInfo "checkHourlyInterval(): Beginning checkHourlyInterval";
  if [ $HOURLY_LAST -a -f $HOURLY_LAST -a -s $HOURLY_LAST ] ; then
    exec 3<&0;
    exec 0<"$HOURLY_LAST";
    while read -r LAST;
    do 
      if (( $NOW_SEC < $(($LAST + $HOURLY_INTERVAL_SEC)) )) ; then
        logInfo "checkHourlyInterval(): Will not perform hourly rotate; last hourly rotate occurred within $HOUR_INTERVAL hours.";
        PERFORM_HOURLY_SNAPSHOT=no;
      else
        logInfo "checkHourlyInterval(): Will perform hourly snapshot.";
      fi;
      break;
    done;
    exec 0<&3;
  else
    logInfo "checkHourlyInterval(): File $HOURLY_LAST not found; will attempt hourly snapshot.";
  fi;
  logInfo "checkHourlyInterval(): Done.";
}

#------------------------------------------------------------------------------
# checkDaillyInterval()
#    Make sure we don't perform a daily rotate prematurely
#------------------------------------------------------------------------------
checkDailyInterval() {
  logInfo "checkDailyInterval(): Beginning checkDailyInterval...";
  if [ $DAILY_LAST -a -f $DAILY_LAST -a -s $DAILY_LAST ] ; then
    exec 3<&0;
    exec 0<"$DAILY_LAST";
    while read -r LAST;
    do 
      if (( $NOW_SEC < $(($LAST + $DAILY_INTERVAL_SEC)) )) ; then
        logInfo "checkDailyInterval(): Will not perform daily rotate; last daily rotate occurred within $DAY_INTERVAL day(s)";
        PERFORM_DAILY_ROTATE=no;
      else
        logInfo "checkDailyInterval(): Will perform daily rotate.";
      fi;
      break;
    done;
    exec 0<&3;
  else
    logInfo "checkDailyInterval(): File $DAILY_LAST not found; will attempt daily rotate.";
  fi;
  logInfo "checkDailyInterval(): Done.";
}

#------------------------------------------------------------------------------
# checkWeeklyInterval()
#    Make sure we don't perform a weekly rotate prematurely
#------------------------------------------------------------------------------
checkWeeklyInterval() {
  logInfo "checkWeeklyInterval(): Beginning checkWeeklyInterval...";
  if [ $WEEKLY_LAST -a -f $WEEKLY_LAST -a -s $WEEKLY_LAST ] ; then
    exec 3<&0;
    exec 0<"$WEEKLY_LAST";
    while read -r LAST;
    do 
      if (( $NOW_SEC < $(($LAST + $WEEKLY_INTERVAL_SEC)) )) ; then
        logInfo "checkWeeklyInterval(): Will not perform weekly rotate; last weekly rotate occurred within $WEEK_INTERVAL week(s).";
        PERFORM_WEEKLY_ROTATE=no;
      else
        logInfo "checkWeeklyInterval(): Will perform weekly rotate.";
      fi;
      break;
    done;
    exec 0<&3;
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
  GUID="`$HOSTNAME`$RANDOM`$DATE -u +%s`";

  logTrace "createSparseImage(): GUID=$ECHO $GUID | $HASH";
  GUID=`$ECHO $GUID | $HASH`;

  logTrace "createSparseImage(): GUID=$ECHO $GUID | $CUT -d' ' -f1";
  GUID=`$ECHO $GUID | $CUT -d' ' -f1`;

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
  $ECHO "$SPARSE_IMAGE_FILE" > $SPARSE_IMAGE_STOR;

  logDebug "createSparseImage(): Attaching $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE to loop...";
  logTrace "createSparseImage(): $LOSETUP --find $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
  `$LOSETUP --find $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE >> $LOG_FILE 2>&1`;
  if [ $? -ne 0 ] ; then
    logError "createSparseImage(): $LOSETUP --find $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE call failed; check $LOSETUP -a for available loop devices; consider rebooting to reset loop devs.";
  fi;

  logTrace "createSparseImage(): $LOSETUP -j $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE | $CUT -d':' -f1";
  LOOP_DEV=`$LOSETUP -j $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE | $CUT -d':' -f1`;
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
      exec 3<&0;
      exec 0<"$LOOP_DEV_STOR";
      while read -r LOOP_DEV;
      do 
        logDebug "setupLoopDevice(): Read loop device from file ($LOOP_DEV)";
        break;
      done;
      exec 0<&3;
    else
      logError "setupLoopDevice(): Could not read loop device from file $LOOP_DEV_STOR; exiting.";
    fi;
  fi;
  
  logTrace "setupLoopDevice(): LOOP_EXISTS=$LOSETUP -j $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE | $GREP $LOOP_DEV | $WC -c";
  LOOP_EXISTS=`$LOSETUP -j $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE | $GREP "$LOOP_DEV" | $WC -c`;

  if [ $LOOP_EXISTS = 0 ] ; then
    logDebug "setupLoopDevice(): Attaching $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE to loop...";
    logTrace "setupLoopDevice(): $LOSETUP --find $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
    `$LOSETUP --find $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE`;
    if [ $? -ne 0 ] ; then
      logError "setupLoopDevice(): $LOSETUP --find $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE call failed; check $LOSETUP -a for available loop devices; consider rebooting to reset loop devs.";
    fi;

    logTrace "setupLoopDevice(): $LOSETUP -j $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE | $CUT -d':' -f1";
    LOOP_DEV=`$LOSETUP -j $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE | $CUT -d':' -f1`;

    logDebug "setupLoopDevice(): Attached $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE to $LOOP_DEV";
    $ECHO "$LOOP_DEV" > $LOOP_DEV_STOR;
  else
    logDebug "setupLoopDevice(): $LOOP_DEV appears to exist, skipping.";
  fi;
  MOUNT_DEV=$LOOP_DEV;
  

  if [ $ENCRYPT = yes ] ; then
    if [ ! $CRYPT_DEV ] ; then
      if [ $CRYPT_DEV_STOR -a -f $CRYPT_DEV_STOR -a -s $CRYPT_DEV_STOR ] ; then
        exec 3<&0;
        exec 0<"$CRYPT_DEV_STOR";
        while read -r CRYPT_DEV;
        do 
          logDebug "setupLoopDevice(): Read loop device from file ($CRYPT_DEV)";
          break;
        done;
        exec 0<&3;
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


#------------------------------------------------------------------------------
# mountSparseImageRW()
#    Attempt to remount the sparse image to its mount point as read-write;
#    If unable to do so, exit(1).
#------------------------------------------------------------------------------
mountSparseImageRW() {
  setupLoopDevice;
  logInfo "mountSparseImageRW(): Re-mounting $MOUNT_DEV to $SPARSE_IMAGE_MOUNT in readwrite...";
  if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
      logError "mountSparseImageRW(): Mount point $SPARSE_IMAGE_MOUNT does not exist; exiting.";
  fi;

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

  logInfo "mountSparseImageRW(): Done.";
}

#------------------------------------------------------------------------------
# mountSparseImageRO()
#    Attempt to (re)mount the sparse image to its mount point as readonly.
#------------------------------------------------------------------------------
mountSparseImageRO() {
  setupLoopDevice;
  logInfo "mountSparseImageRO(): Re-mounting $MOUNT_DEV to $SPARSE_IMAGE_MOUNT in readonly...";
  if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
      logError "mountSparseImageRO(): Mount point $SPARSE_IMAGE_MOUNT does not exist; exiting.";
  fi;

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


#------------------------------------------------------------------------------
# makeHourlySnapshot()
#    Operates on the $SOURCE directory and its children.
#    Delete the previous $HOURLY_SNAP_LIMIT snapshot; 
#      then rotate earlier (1 .. $HOURLY_SNAP_LIMIT-1; increment each by 1) 
#        hourly snapshots of $SOURCE;
#      then copy hourly.0 to hourly.1 using hardlinks;
#      then rsync $SOURCE into hourly.0 updating and deleting changed files. 
#
#    !!! $SOURCE must be setup by calling function. !!!
#------------------------------------------------------------------------------
makeHourlySnapshot() {
  logInfo "makeHourlySnapshot(): Beginning makeHourlySnapshot...";

  # step 1: delete the oldest snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT ] ; then
    logDebug "makeHourlySnapshot(): Removing hourly.$HOURLY_SNAP_LIMIT...";
    logTrace "makeHourlySnapshot(): $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT";
    $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT ;
    if [ $? -ne 0 ] ; then
      logFatal "makeHourlySnapshot(): Unable to remove $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT; exiting.";
    fi;
    logDebug "makeHourlySnapshot(): Removal complete.";
  fi ;

  logDebug "makeHourlySnapshot(): Incrementing hourlies...";
  for (( i=$HOURLY_SNAP_LIMIT ; i>1 ; i-- ))
  do
    # step 2: shift the middle snapshots(s) back by one, if they exist
    OLD=$[$i-1];
    if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$OLD ] ; then
      logTrace "makeHourlySnapshot(): $MV $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$OLD $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$i >> $LOG_FILE 2>&1";
      $MV $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$OLD $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$i >> $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logFatal "makeHourlySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$OLD; exiting.";
      fi;
    fi;
  done
  logDebug "makeHourlySnapshot(): Increment complete.";

  # step 3: make a hard-link-only (except for dirs) copy of the latest snapshot,
  # if that exists
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0 ] ; then
    logDebug "makeHourlySnapshot(): Copying hourly.0...";
    logTrace "makeHourlySnapshot(): $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0 $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.1" >> $LOG_FILE 2>&1;
    $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0 $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.1 >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "makeHourlySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0; exiting.";
    fi;
    logDebug "makeHourlySnapshot(): Copy complete.";
  fi;

  # step 4: rsync from the system into the latest snapshot (notice that
  # rsync behaves like cp --remove-destination by default, so the destination
  # is unlinked first.  If it were not so, this would copy over the other
  # snapshot(s) too! Also note the --exclude-from argument: rsync will ignore
  # files/dirs in $EXCLUDES/$SOURCE.exclude; so each entry within $INCLUDE
  # should have a corresponsing .exclude file.
  EXCLUDE_FILE=`$ECHO "$SOURCE" | $SED "s/\//./g"`
  EXCLUDE_FILE=$EXCLUDE_FILE.exclude
  RSYNC_OPTS="--archive --sparse --partial --delete --delete-excluded \
      --exclude-from=$EXCLUDE_DIR/$EXCLUDE_FILE";

  if [ $LOG_LEVEL -ge $LOG_DEBUG ]; then
    RSYNC_OPTS="--verbose $RSYNC_OPTS";
  fi;

  if [ $LOG_LEVEL -ge $LOG_TRACE ]; then
    RSYNC_OPTS="--progress $RSYNC_OPTS";
  fi;
  logDebug "makeHourlySnapshot(): Performing rsync...";
  logTrace "makeHourlySnapshot(): $RSYNC \
      $RSYNC_OPTS \
      /$SOURCE/ $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/ >> $LOG_FILE 2>&1";
  $RSYNC \
      $RSYNC_OPTS \
      /$SOURCE/ $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/ >> $LOG_FILE 2>&1;
  if [ $? -ne 0 ] ; then
    logWarn "makeHourlySnapshot(): rsync encountered an error; continuing ...";
  fi;
  logDebug "makeHourlySnapshot(): rsync complete.";

  # step 5: update the mtime of hourly.0 to reflect the snapshot time
  logTrace "makeHourlySnapshot(): $TOUCH $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/";
  $TOUCH $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/ ;

  # TODO implement cleanup for cases where rsync failed; 
  # previous renames need to be undone
  $TOUCH $HOURLY_LAST;
  $ECHO "`$DATE -u +%s`" > $HOURLY_LAST;

  # and thats it for now.
  logInfo "makeHourlySnapshot(): Done.";
}

#------------------------------------------------------------------------------
# rotateDailySnapshot()
#    Operates on the $SOURCE directory and its children.
#    Delete the previous $DAILY_SNAP_LIMIT snapshot; 
#      then rotate earlier (0 .. $DAILY_SNAP_LIMIT-1; increment each by 1) 
#        daily snapshots of $SOURCE;
#      then rename hourly.$HOURLY_SNAP_LIMIT to daily.0 
#
#    !!! $SOURCE must be setup by calling function. !!!
#------------------------------------------------------------------------------
rotateDailySnapshot() {
  logInfo "rotateDailySnapshot(): Beginning rotateDailySnapshot...";
  if [ ! -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT ] ; then
        logDebug "rotateDailySnapshot(): ";
        logWarn "rotateDailySnapshot(): Unable to begin daily rotate because the $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT file doesn't exist; continuiing ..."
        return 1;
  fi;

  # step 1: delete the oldest snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT ] ; then
    logDebug "rotateDailySnapshot(): Removing daily.$DAILY_SNAP_LIMIT...";
    logTrace "rotateDailySnapshot(): $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT >> $LOG_FILE 2>&1;";
    $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "rotateDailySnapshot(): Unable to remove $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT; exiting.";
    fi;
    logDebug "rotateDailySnapshot(): Removal complete.";
  fi ;

  logDebug "rotateDailySnapshot(): Incrementing dailies...";
  for (( i=$DAILY_SNAP_LIMIT ; i>0 ; i-- ))
  do
    # step 2: shift the middle snapshots(s) back by one, if they exist
    OLD=$[$i-1]
    if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$OLD ] ; then
      logTrace "rotateDailySnapshot(): $MV $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$OLD $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$i >> $LOG_FILE 2>&1;";
      $MV $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$OLD $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$i >> $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logFatal "rotateDailySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$OLD; exiting.";
      fi;
    fi;
  done
  logDebug "rotateDailySnapshot(): Increment complete.";

  # step 3: make a hard-link-only (except for dirs) copy of
  # hourly.3, assuming that exists, into daily.0
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT ] ; then
    logDebug "rotateDailySnapshot(): Copying hourly.$HOURLY_SNAP_LIMIT to daily.0...";
    logTrace "rotateDailySnapshot(): $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT $SPARSE_IMAGE_MOUNT/$SOURCE/daily.0 >> $LOG_FILE 2>&1;";
    $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT $SPARSE_IMAGE_MOUNT/$SOURCE/daily.0 >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "rotateDailySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT; exiting.";
    fi;
    logDebug "rotateDailySnapshot(): Copy complete.";
    $TOUCH $DAILY_LAST;
    $ECHO "`$DATE -u +%s`" > $DAILY_LAST;
  fi;

  logInfo "rotateDailySnapshot(): Done.";
}

#------------------------------------------------------------------------------
# rotateWeeklySnapshot()
#    Operates on the $SOURCE directory and its children.
#    Delete the previous $WEEKLY_SNAP_LIMIT snapshot; 
#      then rotate earlier (0 .. $WEEKLY_SNAP_LIMIT-1; increment each by 1) 
#        weekly snapshots of $SOURCE;
#      then rename daily.$DAILY_SNAP_LIMIT to weekly.0 
#
#    !!! $SOURCE must be setup by calling function. !!!
#------------------------------------------------------------------------------
rotateWeeklySnapshot() {
  logInfo "rotateWeeklySnapshot(): Beginning rotateWeeklySnapshot...";
  if [ ! -d $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT ] ; then
        logWarn "rotateWeeklySnapshot(): Unable to begin weekly rotate because the $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT file doesn't exist; continuing ..."
        return 1;
  fi;

  # step 1: delete the oldest snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$WEEKLY_SNAP_LIMIT ] ; then
    logDebug "rotateWeeklySnapshot(): Removing weekly.$WEEKLY_SNAP_LIMIT...";
    logTrace "rotateWeeklySnapshot(): $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$WEEKLY_SNAP_LIMIT >> $LOG_FILE 2>&1;";
    $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$WEEKLY_SNAP_LIMIT >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "rotateWeeklySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$WEEKLY_SNAP_LIMIT; exiting.";
    fi;
    logDebug "rotateWeeklySnapshot(): Removal complete.";
  fi ;

  logDebug "rotateWeeklySnapshot(): Incrementing weeklies...";
  for (( i=$WEEKLY_SNAP_LIMIT ; i>0 ; i-- ))
  do
    # step 2: shift the middle snapshots(s) back by one, if they exist
    OLD=$[$i-1]
    if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$OLD ] ; then
      logTrace "rotateWeeklySnapshot(): $MV $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$OLD $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$i >> $LOG_FILE 2>&1;";
      $MV $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$OLD $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$i >> $LOG_FILE 2>&1;
      if [ $? -ne 0 ] ; then
        logFatal "rotateWeeklySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.$OLD; exiting.";
      fi;
    fi;
  done
  logDebug "rotateWeeklySnapshot(): Increment complete";

  # step 3: make a hard-link-only (except for dirs) copy of
  # daily.2, assuming that exists, into weekly.0
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT ] ; then
    logDebug "rotateWeeklySnapshot(): Copying daily.$DAILY_SNAP_LIMIT to weekly.0...";
    logTrace "rotateWeeklySnapshot(): $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.0 >> $LOG_FILE 2>&1;";
    $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT $SPARSE_IMAGE_MOUNT/$SOURCE/weekly.0 >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "rotateWeeklySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/$SOURCE/daily.$DAILY_SNAP_LIMIT; exiting.";
    fi;
    logDebug "rotateWeeklySnapshot(): Copy complete.";
    $TOUCH $WEEKLY_LAST;
    $ECHO "`$DATE -u +%s`" > $WEEKLY_LAST;
  fi;

  logInfo "rotateWeeklySnapshot(): Done.";
}

#------------------------------------------------------------------------------
#------------- ORCHESTRATING FUNCTIONS ----------------------------------------
#------------------------------------------------------------------------------

#------------------------------------------------------------------------------
# setup()
#    Grouping of setup tasks (user check, sparse image creation, interval 
#    checking, etc.)
#------------------------------------------------------------------------------
setup() {

  logInfo "setup(): Beginning setup ...";
  checkUser;
  checkFields;
  getLock;

  if [ $SPARSE_IMAGE_STOR -a -f $SPARSE_IMAGE_STOR -a -s $SPARSE_IMAGE_STOR ] ; then
    exec 3<&0;
    exec 0<"$SPARSE_IMAGE_STOR";
    while read -r SPARSE_IMAGE_FILE;
    do 
      logDebug "setup(): $SPARSE_IMAGE_STOR defines $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE for storage.";
      break;
    done;
    exec 0<&3;
  else
    logDebug "setup(): No sparse image file defined; creating new...";
    createSparseImage;
  fi;

  if [ $SPARSE_IMAGE_DIR -a -d $SPARSE_IMAGE_DIR ] ; then
    logDebug "setup(): Sparse image directory $SPARSE_IMAGE_DIR exists.";
  else
    logError "setup(): Sparse image directory $SPARSE_IMAGE_DIR not found (is its device mounted?); exiting.";
  fi;

  if [ $SPARSE_IMAGE_DIR -a $SPARSE_IMAGE_FILE -a -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE -a -s $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE ] ; then
    logDebug "setup(): Sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE exists.";
  else
    logWarn "setup(): Sparse image file  $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE not found; creating new...";
    createSparseImage;
  fi;

  logInfo "setup(): Using sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";

  checkWeeklyInterval;
  checkDailyInterval;
  checkHourlyInterval;

  mountSparseImageRW;

  if [ $INCLUDES -a -f $INCLUDES -a -s $INCLUDES ] ; then
    exec 3<&0;
    exec 0<"$INCLUDES";
    while read -r SOURCE;
    do
      if [ ! -d $SPARSE_IMAGE_MOUNT/$SOURCE ] ; then
        logDebug "setup(): Creating new snapshot directory $SPARSE_IMAGE_MOUNT/$SOURCE";
        logTrace "setup(): $MKDIR -p $SPARSE_IMAGE_MOUNT/$SOURCE >> $LOG_FILE 2>&1";
        $MKDIR -p $SPARSE_IMAGE_MOUNT/$SOURCE >> $LOG_FILE 2>&1;
      fi;
      logDebug "setup(): Will take snapshot of /$SOURCE.";
    done;
    exec 0<&3;
  else
    logError "setup(): Source listing is empty; verify entries in $INCLUDES; exiting.";
  fi;

  logInfo "setup(): Done.";
}

#------------------------------------------------------------------------------
# teardown()
#    delete $LOCK_FILE and mount readonly
#------------------------------------------------------------------------------
teardown() {
  logInfo "teardown(): Beginning teardown ...";

  mountSparseImageRO;

  logDebug "teardown(): Removing lock file $LOCK_FILE..."
  $RM $LOCK_FILE
  
  logDebug "teardown(): Syncing filesystem...";
  $SYNC; #ensure that changes to the backup imsage file are written-out

  logInfo "teardown(): Done.";
}

#------------------------------------------------------------------------------
# main()
#    Function responsible for overal orchestration of other functions when
#    when performing a backup. The order of operations is important due to
#    copies and renames which take place: 
#      1) rotate weeklies; 
#      2) rotate dailies;
#      3) take hourly snapshot.
#    Note that each entry in the $INCLUDES is backed up in this order 
#    serially (otherwise we'd create I/O contention).
#    
#------------------------------------------------------------------------------
main() {

  logLog "Backup starting...";
  
  setup;

  exec 3<&0;
  exec 0<"$INCLUDES";
  while read -r SOURCE;
  do
    logInfo "main(): Taking snapshot of /$SOURCE...";
    if [ $PERFORM_WEEKLY_ROTATE = yes ] ; then
      logInfo "main(): Performing weekly snapshot rotatation...";
      rotateWeeklySnapshot;
    else
      logInfo "main(): Skipping weekly snapshot rotatation...";
    fi

    if [ $PERFORM_DAILY_ROTATE = yes ] ; then
      logInfo "main(): Performing daily snapshot rotatation...";
      rotateDailySnapshot;
    else
      logInfo "main(): Skipping daily snapshot rotatation...";
    fi

    if [ $PERFORM_HOURLY_SNAPSHOT = yes ] ; then
      logInfo "main(): Performing hourly snapshot creation...";
      makeHourlySnapshot;
    else
      logInfo "main(): Skipping hourly snapshot creation...";
    fi

    logInfo "main(): Completed snapshot of /$SOURCE.";
  done;
  exec 0<&3;

  teardown;
  
  logLog "Backup complete.";
  
  exit 0;
}

#------------------------------------------------------------------------------
# RUN!
#------------------------------------------------------------------------------
main;
