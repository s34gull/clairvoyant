#!/bin/bash
# ----------------------------------------------------------------------
# clairvoyant
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
HASH=/usr/bin/md5sum;
HOSTNAME=/bin/hostname;
ID=/usr/bin/id;
KILL=/bin/kill;
KPARTX=/sbin/kpartx;
LOSETUP=/sbin/losetup;
MKDIR=/bin/mkdir;
MKFS=/sbin/mkfs;
MOUNT=/bin/mount;
MV=/bin/mv;
PARTED=/sbin/parted;
RM=/bin/rm;
RSYNC=/usr/bin/rsync;
SED=/bin/sed;
LPWD=/bin/pwd;
TOUCH=/bin/touch;

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
DAILY_LAST=$CONFIG_DIR/daily.last;
WEEKLY_LAST=$CONFIG_DIR/weekly.last;
SPARSE_IMAGE_STOR=$CONFIG_DIR/sparse.dev;
LOOP_DEV_STOR=$CONFIG_DIR/loop.dev;

# Various lock and run files (may be tmpfs so aren't persistent)
LOCK_DIR=/var/lock/snapshot;
LOCK_FILE=$LOCK_DIR/pid.lock;
FATAL_LOCK_FILE=$LOCK_DIR/fatal.lock;

# Log file (may be tmpfs so aren't persistent)
LOG_FILE=/var/log/snapshot.log;

# Rotation variables
PERFORM_DAILY_ROTATE=yes;
PERFORM_WEEKLY_ROTATE=yes;

# Remember, snap counts start at 0
HOURLY_SNAP_LIMIT=23;
DAILY_SNAP_LIMIT=29;
WEEKLY_SNAP_LIMIT=51;

# Time intervals (in seconds)
DAILY_INTERVAL_SEC=60*60*24;
WEEKLY_INTERVAL_SEC=$DAILY_INTERVAL_SEC*7;

# Logging levels
LOG_DEBUG=4;
LOG_INFO=3;
LOG_WARNING=2;
LOG_ERROR=1;
LOG_FATAL=0;

# Unset parameters (set within startup())
SOURCES=;
SOURCE=;
LOOP=;
SPARSE_IMAGE_FILE=;

#-----------------------------------------------------------------------
#------------- User Parameters -----------------------------------------
#-----------------------------------------------------------------------
LOG_LEVEL=$LOG_WARNING; # see above $LOG_xxx
SILENT=no; # no - print to console; yes - suppress console output
IMAGE_SIZE=; # specify in M (megabytes) or G (gigabytes)
IMAGE_FS_TYPE=; # use either ext4, ext3 or ext2 (must support hard-links)
SPARSE_IMAGE_MOUNT=; # attatch image to this mountpoint 
SPARSE_IMAGE_DIR=; # directory storing image file

#-----------------------------------------------------------------------
#------------- FUNCTIONS -----------------------------------------------
#-----------------------------------------------------------------------

echoConsole() {
    if [ $SILENT = no ]; then
        echo $1;
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
    if [ $LOG_LEVEL -ge $LOG_WARNING ]; then
        echo "WARNING: $*";
        echo "`$DATE` [$$] WARNING: $*" >> $LOG_FILE;
    fi;
}

logError() {
    if [ $LOG_LEVEL -ge $LOG_ERROR ]; then
        echo "ERROR:  $*";
        echo "`$DATE` [$$] ERROR: $*" >> $LOG_FILE;
    fi;
}

logFatal() {
    echo "FATAL: $*";
    echo "`$DATE` [$$] FATAL: $*" >> $LOG_FILE;
    $TOUCH $FATAL_LOCK_FILE;
    exit 2;
}

#------------------------------------------------------------------------------
# make sure we're running as root
#------------------------------------------------------------------------------
checkUser() {
  logInfo "checkUser(): Beginning checkUser...";
  if (( `$ID -u` != 0 )); then 
    logError "checkUser(): Sorry, must be root; exiting."; 
    exit 1;
  else
    logInfo "checkUser(): User is root, proceeding...";
  fi;
  logInfo "checkUser(): Done.";
}

#------------------------------------------------------------------------------
# ensure that required fields are set
#------------------------------------------------------------------------------
checkFields() {
  if [ $IMAGE_SIZE ] ; then
    logDebug "checkFields(): IMAGE_SIZE is set.";
  else
    logFatal "checkFields(): IMAGE_SIZE is not set; exiting.";
  fi;

  if [ $IMAGE_FS_TYPE ] ; then
    logDebug "checkFields(): IMAGE_FS_TYPE is set.";
  else
    logFatal "checkFields(): IMAGE_FS_TYPE is not set; exiting.";
  fi;

  if [ $SPARSE_IMAGE_MOUNT ] ; then
    logDebug "checkFields(): SPARSE_IMAGE_MOUNT is set.";
  else
    logFatal "checkFields(): SPARSE_IMAGE_MOUNT is not set; exiting.";
  fi;

  if [ $SPARSE_IMAGE_DIR ] ; then
    logDebug "checkFields(): SPARSE_IMAGE_DIR is set.";
  else
    logFatal "checkFields(): SPARSE_IMAGE_DIR is not set; exiting.";
  fi;
}

#------------------------------------------------------------------------------
# check for or create PID-based lockfile
#------------------------------------------------------------------------------
getLock() {
  logInfo "getLock(): Beginning getLock...";
  if [ ! -d $LOCK_DIR ] ; then
      logInfo "getLock(): Lockfile directory doesn't exist; creating $LOCK_DIR";
      $MKDIR -p $LOCK_DIR;
  fi;

  if [ $FATAL_LOCK_FILE -a -f $FATAL_LOCK_FILE ] ; then
    logFatal "A previously fatal error was detected. I will not execute until you review the $LOG_FILE and address any issues reported there; failure to do so may result in corruption of your snapshots. Once you have done so, remove $FATAL_LOCK_FILE and re-run me."; 
  fi;

  if [ $LOCK_FILE -a -f $LOCK_FILE -a -s $LOCK_FILE ] ; then
      exec 3<&0;
      exec 0<"$LOCK_FILE";
      while read -r PID
      do 
      logInfo "getLock():Checking for running instance of script with PID $PID";
      $TEST_PROCESS $PID > /dev/null 2>&1;
      if [ $? = 0 ] ; then
          # check name as well
          logError "getLock():Found running instance with PID=$PID; exiting.";
          exit 1;
      else
          $RM $LOCK_FILE;
          logInfo "getLock():Process $PID not found; deleting stale lockfile $LOCK_FILE";
      fi;
       break;
    done
  else
    logInfo "getLock(): Specified lockfile $LOCK_FILE not found; creating...";
    $TOUCH $LOCK_FILE;
  fi;

  logInfo "getLock(): Recording current PID $$ in lockfile $LOCK_FILE";
  echo $$ > $LOCK_FILE;
  logInfo "getLock(): Done.";
}

#------------------------------------------------------------------------------
# make sure we don't perform a daily rotate prematurely
#------------------------------------------------------------------------------
checkDailyInterval() {
  logInfo "checkWeeklyInterval(): Beginning checkDailyInterval...";
  if [ $DAILY_LAST -a -f $DAILY_LAST -a -s $DAILY_LAST ] ; then
    exec 3<&0;
    exec 0<"$DAILY_LAST";
    while read -r LAST;
    do 
      if (( `$DATE -u +%s` < $[$LAST+$DAILY_INTERVAL_SEC] )) ; then
        logInfo "checkDailyInterval(): Will not perform daily rotate; last daily rotate occurred within 24 hours.";
        PERFORM_DAILY_ROTATE=no;
      else
        logInfo "checkDailyInterval(): Will perform daily rotate.";
      fi;
      break;
    done
  else
    logInfo "checkDailyInterval(): File $DAILY_LAST not found; will attempt daily rotate.";
  fi;
  logInfo "checkWeeklyInterval(): Done.";
}

#------------------------------------------------------------------------------
# make sure we don't perform a weekly rotate prematurely
#------------------------------------------------------------------------------
checkWeeklyInterval() {
  logInfo "checkWeeklyInterval(): Beginning checkWeeklyInterval...";
  if [ $WEEKLY_LAST -a -f $WEEKLY_LAST -a -s $WEEKLY_LAST ] ; then
    exec 3<&0;
    exec 0<"$WEEKLY_LAST";
    while read -r LAST;
    do 
      if (( `$DATE -u +%s` < $[$LAST+$WEEKLY_INTERVAL_SEC] )) ; then
        logInfo "checkWeeklyInterval(): Will not perform weekly rotate; last weekly rotate occurred within 7 days.";
        PERFORM_WEEKLY_ROTATE=no;
      else
        logInfo "checkWeeklyInterval(): Will perform weekly rotate.";
      fi;
      break;
    done
  else
    logInfo "checkWeeklyInterval(): File $WEEKLY_LAST not found; will attempt weekly rotate.";
  fi;
  logInfo "checkWeeklyInterval(): Done.";
}

#-----------------------------------------------------------------------
# Create a sparse disk image (sparse file, with partition table and user
# specified file system (ext4 > ext3)) and record its name.
# The name format is $HOSTNAME.$HASH($HOSTNAME+$RANDOM+$DATE).raw.
# Once created, make it available via /dev/mapper via kparx.
#-----------------------------------------------------------------------
createSparseImage() {

  GUID="`$HOSTNAME`$RANDOM`$DATE -u +%s`";
  GUID=`$ECHO $GUID | $HASH`;
  GUID=`$ECHO $GUID | $CUT -d' ' -f1`;
  SPARSE_IMAGE_FILE=`$HOSTNAME`.$GUID.raw;
  $ECHO "$SPARSE_IMAGE_FILE" > $SPARSE_IMAGE_STOR;

  logInfo "createSparseImage(): Creating file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE...";
  `$DD if=/dev/zero of=$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE bs=1 count=1 seek=$IMAGE_SIZE`;
  if [ $? -ne 0 ] ; then
      logFatal "createSparseImage(): Unable to create sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE; exiting.";
  fi;
  logInfo "createSparseImage(): Creating partition...";
  `$PARTED $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE mklabel msdos`;
  if [ $? -ne 0 ] ; then
      logFatal "createSparseImage(): Unable to create partition table; exiting.";
  fi;
  `$PARTED $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE mkpart primary 0G $IMAGE_SIZE`;
  if [ $? -ne 0 ] ; then
      logFatal "createSparseImage(): Unable to create partition; exiting.";
  fi;

  logInfo "createSparseImage(): Creating temp loopback device for initialization";
  CWD=`$LPWD`;
  cd $SPARSE_IMAGE_DIR;
    LOOP=`$KPARTX -a -v $SPARSE_IMAGE_FILE`;
    if [ $? -ne 0 ] ; then
        logFatal "createSparseImage(): Unable to create device mapping using $KPARTX; exiting.";
    fi;
    LOOP=`$ECHO $LOOP | $CUT -d' ' -f3`;
    LOOP=/dev/mapper/$LOOP;
    $ECHO "$LOOP" > $LOOP_DEV_STOR;
  cd $CWD;

  logInfo "createSparseImage(): Creating fs on $LOOP using $MKFS...";
  `$MKFS -t $IMAGE_FS_TYPE $LOOP`;
  if [ $? -ne 0 ] ; then
      logFatal "createSparseImage(): Unable to create filesystem $IMAGE_FS_TYPE on $LOOP; exiting.";
  fi;

  if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
    logInfo "createSparseImage(): Creating mount point $SPARSE_IMAGE_MOUNT...";
    `$MKDIR -p $SPARSE_IMAGE_MOUNT`;
    if [ $? -ne 0 ] ; then
        logFatal "createSparseImage(): Unable to create mount point $SPARSE_IMAGE_MOUNT; exiting.";
    fi;
  fi;

  logInfo "createSparseImage(): Done.";
}

#-----------------------------------------------------------------------
# After a (re)boot, no loopback devices are preserved. This function
# attempts to check for an existing sparse diskimage mapping and will
# create one if it doesn't exist. This must happen before mounting.
#-----------------------------------------------------------------------
setupLoopDevice() {
  if [ ! $LOOP ] ; then
    if [ $LOOP_DEV_STOR -a -f $LOOP_DEV_STOR -a -s $LOOP_DEV_STOR ] ; then
      exec 3<&0;
      exec 0<"$LOOP_DEV_STOR";
      while read -r LOOP;
      do 
        logDebug "setupLoopDevice(): Read loop device from file ($LOOP)";
        break;
      done;
    else
      logFatal "setupLoopDevice(): Could not read loop device from file $LOOP_DEV_STOR; exiting.";
    fi;
  fi;

  if [ ! -e $LOOP ] ; then
    CWD=`$LPWD`;
    cd $SPARSE_IMAGE_DIR;
      LOOP=`$KPARTX -a -v $SPARSE_IMAGE_FILE`;
      if [ $? -ne 0 ] ; then
        logFatal "setupLoopDevice(): $KPARTX call failed; check $LOSETUP for available loop devices; consider rebooting to reset loop devs.";
      else
        logDebug "setupLoopDevice(): $KPARTX call successful.";
      fi;
      LOOP=`$ECHO $LOOP | $CUT -d' ' -f3`;
      LOOP=/dev/mapper/$LOOP;
      $ECHO "$LOOP" > $LOOP_DEV_STOR;
    cd $CWD;
  else
    logDebug "setupLoopDevice(): $LOOP appears to exist, skipping $KPARTX call.";
  fi;

  logInfo "setupLoopDevice(): $LOOP is ready.";
}


#------------------------------------------------------------------------------
# attempt to remount the RW mount point as RW; else abort
#------------------------------------------------------------------------------
mountSparseImageRW() {
    setupLoopDevice;
    logInfo "mountSparseImageRW(): Re-mounting $LOOP to $SPARSE_IMAGE_MOUNT in readwrite...";
    if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
        logFatal "mountSparseImageRW(): Mount point $SPARSE_IMAGE_MOUNT does not exist; exiting.";
    fi;
    `$MOUNT -t $IMAGE_FS_TYPE -o remount,rw,relatime,nodiratime $LOOP $SPARSE_IMAGE_MOUNT`;
    if [ $? -ne 0 ] ; then
        logWarn "mountSparseImageRW(): Trying without -o remount";
        `$MOUNT -t $IMAGE_FS_TYPE -o rw $LOOP $SPARSE_IMAGE_MOUNT`;
        if [ $? -ne 0 ] ; then
          logFatal "mountSparseImageRW(): Could not re-mount $LOOP to $SPARSE_IMAGE_MOUNT readwrite";
        else
          logInfo "mountSparseImageRW(): Done.";
        fi;
    else
      logInfo "mountSparseImageRW(): Done.";
    fi;
  }

#------------------------------------------------------------------------------
# now remount the RW snapshot mountpoint as readonly
#------------------------------------------------------------------------------
mountSparseImageRO() {
    setupLoopDevice;
    logInfo "mountSparseImageRO(): Re-mounting $LOOP to $SPARSE_IMAGE_MOUNT in readonly...";
    if [ ! -d $SPARSE_IMAGE_MOUNT ] ; then
        logFatal "mountSparseImageRO(): Mount point $SPARSE_IMAGE_MOUNT does not exist; exiting.";
    fi;
    `$MOUNT -t $IMAGE_FS_TYPE -o remount,ro,relatime,nodiratime $LOOP $SPARSE_IMAGE_MOUNT`;
    if [ $? -ne 0 ] ; then
        logWarn "mountSparseImageRO(): Trying without -o remount";
        `$MOUNT -t $IMAGE_FS_TYPE -o ro $LOOP $SPARSE_IMAGE_MOUNT`;
        if [ $? -ne 0 ] ; then
          logFatal "mountSparseImageRO(): Could not re-mount $LOOP to $SPARSE_IMAGE_MOUNT readonly";
        else
          logInfo "mountSparseImageRO(): Done.";
        fi;
    else
      logInfo "mountSparseImageRO(): Done.";
    fi;
  }


#------------------------------------------------------------------------------
# rotating snapshots of /home (fixme: this should be more general)
#------------------------------------------------------------------------------
makeHourlySnapshot() {
  logInfo "makeHourlySnapshot(): Beginning makeHourlySnapshot...";

  # step 1: delete the oldest snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT ] ; then
    logDebug "makeHourlySnapshot(): $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT";
    $RM -rf $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT ;
    if [ $? -ne 0 ] ; then
      logFatal "makeHourlySnapshot(): Unable to remove $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$HOURLY_SNAP_LIMIT; exiting.";
    fi;
  fi ;


  for (( i=$HOURLY_SNAP_LIMIT ; i>1 ; i-- ))
  do
    # step 2: shift the middle snapshots(s) back by one, if they exist
    OLD=$[$i-1];
    if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$OLD ] ; then
      logDebug "makeHourlySnapshot(): $MV $SPARSE_IMAGE_MOUNT/home/hourly.$OLD $SPARSE_IMAGE_MOUNT/home/hourly.$i";
      $MV $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$OLD $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$i ;
      if [ $? -ne 0 ] ; then
        logFatal "makeHourlySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.$OLD; exiting.";
      fi;
    fi;
  done

  # step 3: make a hard-link-only (except for dirs) copy of the latest snapshot,
  # if that exists
  if [ -d $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0 ] ; then
    logDebug "makeHourlySnapshot(): $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0 $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.1";
    $CP -al $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0 $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.1 ;
    if [ $? -ne 0 ] ; then
      logFatal "makeHourlySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0; exiting.";
    fi;
  fi;

  # step 4: rsync from the system into the latest snapshot (notice that
  # rsync behaves like cp --remove-destination by default, so the destination
  # is unlinked first.  If it were not so, this would copy over the other
  # snapshot(s) too! Also note the --exclude-from argument: rsync will ignore
  # files/dirs in $EXCLUDES/$SOURCE.exclude; so each entry within $INCLUDE
  # should have a corresponsing .exclude file.
  EXCLUDE_FILE=`$ECHO "$SOURCE" | $SED "s/\//./g"`
  EXCLUDE_FILE=$EXCLUDE_FILE.exclude
  logDebug "makeHourlySnapshot(): $RSYNC \
      -va --delete --delete-excluded \
      --exclude-from="$EXCLUDE_DIR/$EXCLUDE_FILE" \
      /$SOURCE/ $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/";
  $RSYNC \
      -va --delete --delete-excluded \
      --exclude-from="$EXCLUDE_DIR/$EXCLUDE_FILE" \
      /$SOURCE/ $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/ ;
  if [ $? -ne 0 ] ; then
    logFatal "makeHourlySnapshot(): rsync failed; exiting.";
  fi;

  # step 5: update the mtime of hourly.0 to reflect the snapshot time
  logDebug "makeHourlySnapshot(): $TOUCH $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/";
  $TOUCH $SPARSE_IMAGE_MOUNT/$SOURCE/hourly.0/ ;

  # TODO implement cleanup for cases where rsync failed; 
  # previous renames need to be undone

  # and thats it for home.
  logInfo "makeHourlySnapshot(): Done.";
}

#------------------------------------------------------------------------------
# rotate the earlier dailies and rename  the oldest hourly to daily.0
#------------------------------------------------------------------------------
rotateDailySnapshot() {
  logInfo "rotateDailySnapshot(): Beginning rotateDailySnapshot...";
  if [ ! -d $SPARSE_IMAGE_MOUNT/home/hourly.$HOURLY_SNAP_LIMIT ] ; then
        logWarn "rotateDailySnapshot(): Unable to begin daily rotate because the $SPARSE_IMAGE_MOUNT/home/hourly.$HOURLY_SNAP_LIMIT file doesn't exist; returning ..."
        return 1;
  fi;

  # step 1: delete the oldest snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT ] ; then
    $RM -rf $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT ;
    if [ $? -ne 0 ] ; then
      logFatal "rotateDailySnapshot(): Unable to remove $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT; exiting.";
    fi;
  fi ;


  for (( i=$DAILY_SNAP_LIMIT ; i>0 ; i-- ))
  do
    # step 2: shift the middle snapshots(s) back by one, if they exist
    OLD=$[$i-1]
    if [ -d $SPARSE_IMAGE_MOUNT/home/daily.$OLD ] ; then
      $MV $SPARSE_IMAGE_MOUNT/home/daily.$OLD $SPARSE_IMAGE_MOUNT/home/daily.$i ;
      if [ $? -ne 0 ] ; then
        logFatal "rotateDailySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/home/daily.$OLD; exiting.";
      fi;
    fi;
  done

  # step 3: make a hard-link-only (except for dirs) copy of
  # hourly.3, assuming that exists, into daily.0
  if [ -d $SPARSE_IMAGE_MOUNT/home/hourly.$HOURLY_SNAP_LIMIT ] ; then
    $CP -al $SPARSE_IMAGE_MOUNT/home/hourly.$HOURLY_SNAP_LIMIT $SPARSE_IMAGE_MOUNT/home/daily.0 ;
    if [ $? -ne 0 ] ; then
      logFatal "rotateDailySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/home/hourly.$HOURLY_SNAP_LIMIT; exiting.";
    fi;
    $TOUCH $DAILY_LAST;
    $ECHO "`$DATE -u +%s`" > $DAILY_LAST;
  fi;

  logInfo "rotateDailySnapshot(): Done.";
}

#------------------------------------------------------------------------------
# rotate the earlier weklies and rename the oldest daily to weekly.0
#------------------------------------------------------------------------------
rotateWeeklySnapshot() {
  logInfo "rotateWeeklySnapshot(): Beginning rotateWeeklySnapshot...";
  if [ ! -d $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT ] ; then
        logWarn "rotateDailySnapshot(): Unable to begin weekly rotate because the $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT file doesn't exist; returning ..."
        return 1;
  fi;

  # step 1: delete the oldest snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/home/weekly.$WEEKLY_SNAP_LIMIT ] ; then
    $RM -rf $SPARSE_IMAGE_MOUNT/home/weekly.$WEEKLY_SNAP_LIMIT ;
    if [ $? -ne 0 ] ; then
      logFatal "rotateWeeklySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/home/weekly.$WEEKLY_SNAP_LIMIT; exiting.";
    fi;
  fi ;

  for (( i=$WEEKLY_SNAP_LIMIT ; i>0 ; i-- ))
  do
    # step 2: shift the middle snapshots(s) back by one, if they exist
    OLD=$[$i-1]
    if [ -d $SPARSE_IMAGE_MOUNT/home/weekly.$OLD ] ; then
      $MV $SPARSE_IMAGE_MOUNT/home/weekly.$OLD $SPARSE_IMAGE_MOUNT/home/weekly.$i ;
      if [ $? -ne 0 ] ; then
        logFatal "rotateWeeklySnapshot(): Unable to move $SPARSE_IMAGE_MOUNT/home/weekly.$OLD; exiting.";
      fi;
    fi;
  done
  # step 3: make a hard-link-only (except for dirs) copy of
  # daily.2, assuming that exists, into weekly.0
  if [ -d $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT ] ; then
    $CP -al $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT $SPARSE_IMAGE_MOUNT/home/weekly.0 ;
    if [ $? -ne 0 ] ; then
      logFatal "rotateWeeklySnapshot(): Unable to copy $SPARSE_IMAGE_MOUNT/home/daily.$DAILY_SNAP_LIMIT; exiting.";
    fi;
    $TOUCH $WEEKLY_LAST;
    $ECHO "`$DATE -u +%s`" > $WEEKLY_LAST;
  fi;

  logInfo "rotateWeeklySnapshot(): Done.";
}

#------------------------------------------------------------------------------
#------------- ORCHESTRATING FUNCTIONS ----------------------------------------
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# grouping of precursor tasks
#------------------------------------------------------------------------------
startup() {
  logInfo "startup(): Beginning initialization...";
  checkUser;
  checkFields;
  getLock;

  if [ $SPARSE_IMAGE_STOR -a -f $SPARSE_IMAGE_STOR -a -s $SPARSE_IMAGE_STOR ] ; then
    exec 3<&0;
    exec 0<"$SPARSE_IMAGE_STOR";
    while read -r SPARSE_IMAGE_FILE;
    do 
      logDebug "startup(): Sparse image file info read from file $SPARSE_IMAGE_FILE";
      break;
    done;
  else
    logInfo "startup(): No sparse image file defined; creating new...";
    createSparseImage;
  fi;

  if [ $SPARSE_IMAGE_DIR -a $SPARSE_IMAGE_FILE -a -f $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE -a -s $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE ] ; then
    logDebug "startup(): Sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE exists.";
  else
    logWarn "startup(): Sparse image file  $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE not found; creating new...";
    createSparseImage;
  fi;

  logInfo "startup(): Using sparse image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";

  checkWeeklyInterval;
  checkDailyInterval;

  mountSparseImageRW;

  if [ $INCLUDES -a -f $INCLUDES -a -s $INCLUDES ] ; then
    SOURCES=`$CAT $INCLUDES`;
    for SOURCE in $SOURCES
    do
      if [ ! -d $SPARSE_IMAGE_MOUNT/$SOURCE ] ; then
        logInfo "startup(): Creating new snapshot directory $SPARSE_IMAGE_MOUNT/$SOURCE";
        $MKDIR -p $SPARSE_IMAGE_MOUNT/$SOURCE;
      fi;
      logDebug "startup(): Will take snapshot of /$SOURCE.";
    done;
  else
    logFatal "startup(): Source listing is empty; verify entries in $INCLUDES";
  fi;

  logInfo "startup(): Done.";
}

#------------------------------------------------------------------------------
# delete $LOCK_FILE and mount readonly
#------------------------------------------------------------------------------
shutdown() {
  mountSparseImageRO;
  logInfo "shutdown(): Removing lock file $LOCK_FILE..."
  $RM $LOCK_FILE
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
  logInfo "main(): Script starting...";

  startup;

  for SOURCE in $SOURCES
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

    logInfo "main(): Performing hourly snapshot creation...";
    makeHourlySnapshot;

    logInfo "main(): Completed snapshot of /$SOURCE.";
  done;

  shutdown;

  logInfo "main(): Script exiting successfully.";
}

#------------------------------------------------------------------------------
# RUN!
#------------------------------------------------------------------------------
main;
