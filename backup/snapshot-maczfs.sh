#!/bin/bash
# ----------------------------------------------------------------------
# snapshot-hfs.sh
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
# $Author: s34gull $ 
# $Rev: 145 $
# $Date: 2010-08-31 13:32:19 -0600 (Tue, 31 Aug 2010) $
# $Id: snapshot.sh 145 2010-08-31 19:32:19Z s34gull $
# ----------------------------------------------------------------------


# ----------------------------------------------------------------------
# ------------- COMMANDS --------------------
# Include external commands here for portability
# ----------------------------------------------------------------------
CP=/opt/local/bin/gcp
GREP=/usr/bin/grep
RSYNC=/opt/local/bin/rsync
SED=/usr/bin/sed
TOUCH=/usr/bin/touch

CHFLAGS=/usr/bin/chflags
HDIUTIL=/usr/bin/hdiutil;
DISKUTIL=/usr/sbin/diskutil;
ZPOOL=/usr/sbin/zpool
ZFS=/usr/sbin/zfs


# If we need encryption
#    - encryption is specified during image creation

#If we want to notify the user of our progress
# Use Growl's API to send to Notification Center
#NOTIFY="/usr/bin/notify-send --urgency=normal --expire-time=2000 Snaphot";
# set NOTIFY to $ECHO
NOTIFY=/bin/echo;



#-----------------------------------------------------------------------
#------------- FUNCTIONS -----------------------------------------------
#-----------------------------------------------------------------------

#-----------------------------------------------------------------------
# createSparseImage()
#    Create a sparse disk image (sparse file, with partition table and 
#    user specified file system (ext4 > ext3)) and record its name.
#    The name format is $HOSTNAME.$HASH($HOSTNAME+$RANDOM+$DATE).raw.
#    Once created, make it available via /dev/mapper via kparx.
#-----------------------------------------------------------------------
createSparseImage() {
  logInfo "createSparseImage(): Creating new sparse image file for snapshots...";

  logDebug "createSparseImage(): GUID=$HOSTNAME$RANDOM$DATE -u +%s";
  #GUID="`$HOSTNAME`$RANDOM`$DATE -u +%s`";
  GUID="$RANDOM`$DATE -u +%s`";

  #logDebug "createSparseImage(): GUID=$ECHO $GUID | $HASH";
  #GUID=`$ECHO $GUID | $HASH`;

  #logDebug "createSparseImage(): GUID=$ECHO $GUID | $CUT -d' ' -f1";
  #GUID=`$ECHO $GUID | $CUT -d' ' -f1`;

  SPARSE_IMAGE_FILE=`$HOSTNAME`.$GUID.sparsebundle;

  logInfo "createSparseImage(): Initializing image file $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE...";
  logDebug "createSparseImage(): Creating file...";

  # Something TODO with creating sparsebundles on network volumes is preventing 
  # successful creation of a filesystem on newly minted disk image
  if [ $ENCRYPT = yes ] ; then
    logDebug "createSparseImage(): Enryption requested; using encrypted DMG."
    logDebug "createSparseImage(): $HDIUTIL create -stdinpass -encryption AES-256 -type SPARSEBUNDLE -size $IMAGE_SIZE -volname Snapshot Volume -fs Journaled HFS+ $SPARSE_IMAGE_DIR/SPARSE_IMAGE_FILE";
    $ECHO $PASSPHRASE | $HDIUTIL create -verbose -stdinpass -encryption AES-256 -type SPARSEBUNDLE -size $IMAGE_SIZE -volname "Snapshot_Volume" -fs Journaled\ HFS+ -attach "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
  else
    logDebug "createSparseImage(): Enryption NOT requested; using standard DMG."
    logDebug "createSparseImage(): $HDIUTIL create -type SPARSEBUNDLE -size $IMAGE_SIZE -volname Snapshot Volume -fs Journaled HFS+ $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
    $HDIUTIL create -verbose -type SPARSEBUNDLE -size $IMAGE_SIZE -volname "Snapshot_Volume" -fs Journaled\ HFS+ -attach "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
  fi;

  # TODO create zpool/zfs volume on the new Volume
  # DEVICE_NODE=`diskutil info /Volumes/Snapshot_Volume | grep "Device Node" | CUT -d ':' -f2- | sed -e 's/[ \t]*//g'`
  # zpool create -f -O casesensitivity=insensitive -O copies=2 -O compression=on -O checksum=fletcher4 -O primarycache=metadata -O secondarycache=none -O atime=off Snapshot_Volume $DEVICE_NODE

  `$ECHO "$SPARSE_IMAGE_FILE" > $SPARSE_IMAGE_STOR`;

  $TOUCH "$DAILY_LAST";
  $ECHO "`$DATE -u +%s`" > "$DAILY_LAST";

  $TOUCH "$WEEKLY_LAST";
  $ECHO "`$DATE -u +%s`" > "$WEEKLY_LAST";

  logInfo "createSparseImage(): Done.";
}

setupLoopDevice() {
  logInfo "Calling noop loop setup for Mac.";
}

#-----------------------------------------------------------------------
# filesystemCheck()
#    Make sure that the fs is clean. If not, don't attempt repair, but 
#    logFatal and exit(2).
#-----------------------------------------------------------------------
filesystemCheck() {
  logInfo "filesystemCheck(): Starting file system check (repairs will NOT be attempted)...";

  logDebug "echo $SPARSE_IMAGE_MOUNT | $CUT -d '/' -f3-"
  ZPOOL_NAME="`echo $SPARSE_IMAGE_MOUNT | $CUT -d '/' -f3 -`"

  logDebug "filesystemCheck(): Checking file system $SPARSE_IMAGE_MOUNT";
  logWarn "filesystemCheck(): A week has passed; a scrub is recommended.";
  #logDebug "filesystemCheck(): $ZPOOL scrub $ZPOOL_NAME";
  #`$ZPOOL scrub "$ZPOOL_NAME" >> $LOG_FILE 2>&1`;
  #if [ $? -ne 0 ] ; then
  #    logFatal "filesystemCheck(): $ZPOOL scrub reported errors on $ZPOOL_NAME; check $LOG_FILE and manually repair this voume; exiting...";
  #fi;
  logInfo "filesystemCheck(): File system check complete.";
}

#-----------------------------------------------------------------------
# mountSparseImageRW()
#    Attempt to remount the sparse image to its mount point as 
#    read-write; If unable to do so, exit(1).
#-----------------------------------------------------------------------
mountSparseImageRW() {
  setupLoopDevice;
  logInfo "mountSparseImageRW(): Re-mounting $MOUNT_DEV to $SPARSE_IMAGE_MOUNT in readwrite...";
  if [ -d "$SPARSE_IMAGE_MOUNT" ] ; then
    TYPE=`$DISKUTIL info $SPARSE_IMAGE_MOUNT | $GREP "Type (Bundle)" | $CUT -d ':' -f2- | $SED -e 's/ *//g'`
    if [[ "$TYPE" == "zfs" ]] ; then
      logDebug "ZFS volume mounted; nothing to do";
    else
      logFatal "$SPARSE_IMAGE_MOUNT mounted, but not ZFS volume (found $TYPE); exiting..."
    fi;
  else
      logDebug "mountSparseImageRW(): Attempting mount...";
      if [ $ENCRYPT = yes ] ; then
        logDebug "mountSparseImageRW(): $HDIUTIL attach -stdinpass $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
        `$ECHO $PASSPHRASE | $HDIUTIL attach -stdinpass "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE" >> $LOG_FILE 2>&1`;
        if [ $? -ne 0 ] ; then
          sleep 10;
          `$ECHO $PASSPHRASE | $HDIUTIL attach -stdinpass "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE" >> $LOG_FILE 2>&1`;
          if [ $? -ne 0 ] ; then
            logFatal "mountSparseImageRW(): $HDIUTIL failed; exiting."
          fi;
        fi;
      else 
        logDebug "mountSparseImageRW(): $HDIUTIL attach $SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE";
        `$HDIUTIL attach "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE" >> $LOG_FILE 2>&1`;
        if [ $? -ne 0 ] ; then
          sleep 10;
          `$HDIUTIL attach "$SPARSE_IMAGE_DIR/$SPARSE_IMAGE_FILE" >> $LOG_FILE 2>&1`;
          if [ $? -ne 0 ] ; then
            logFatal "mountSparseImageRW(): $HDIUTIL failed; exiting."
          fi;
        fi;
      fi;
  fi;

  if [ $PERFORM_WEEKLY_ROTATE = yes ] ; then
    logInfo "mountSparseImageRW(): Performing weekly file system check...";
    filesystemCheck;
  else
    logInfo "mountSparseImageRW(): Skipping weekly file system check...";
  fi

  logDebug "echo $SPARSE_IMAGE_MOUNT | $CUT -d '/' -f3-"
  ZPOOL_NAME="`echo $SPARSE_IMAGE_MOUNT | $CUT -d '/' -f3-`"
  logDebug "$ZFS set readonly=off $ZPOOL_NAME"
  `$ZFS set readonly=off $ZPOOL_NAME`

  # exit code 1 means already mounted
  logDebug "$ZFS unmount $ZPOOL_NAME"
  `$ZFS unmount $ZPOOL_NAME`
  logDebug "$ZFS mount $ZPOOL_NAME"
  `$ZFS mount $ZPOOL_NAME`
  if [ $? -ne 0 ] ; then
      logFatal "mountSparseImageRW(): '$ZFS mount' reported errors on $ZPOOL_NAME; check $LOG_FILE and manually repair this voume; exiting...";
  fi;

  logDebug "mountSparseImageRW(): Mount complete.";

  logDebug "mountSparseImageRW(): Attempting chmod 700 $SPARSE_IMAGE_MOUNT/*";
  `$CHMOD 700 $SPARSE_IMAGE_MOUNT/*`
  `$CHFLAGS nohidden $SPARSE_IMAGE_MOUNT`

  logInfo "mountSparseImageRW(): Done.";
}

#-----------------------------------------------------------------------
# mountSparseImageRO()
#    On the Mac, just detach the disk image, to be consistent with 
# Time Machine.
#-----------------------------------------------------------------------
mountSparseImageRO() {
  setupLoopDevice;

  logDebug "mountSparseImageRO(): Attempting chmod 755 $SPARSE_IMAGE_MOUNT/*";
  $CHMOD 755 $SPARSE_IMAGE_MOUNT/*;
  $CHFLAGS hidden $SPARSE_IMAGE_MOUNT;

  logInfo "mountSparseImageRO(): Unmounting $SPARSE_IMAGE_MOUNT ...";
  if [ -d "$SPARSE_IMAGE_MOUNT" ] ; then
      logDebug "echo $SPARSE_IMAGE_MOUNT | $CUT -d '/' -f3-"
      ZPOOL_NAME="`echo $SPARSE_IMAGE_MOUNT | $CUT -d '/' -f3-`"
      logDebug "$ZFS set readonly=on $ZPOOL_NAME"
      `$ZFS set readonly=on $ZPOOL_NAME`

      logInfo "mountSparseImageRO(): Mount point $SPARSE_IMAGE_MOUNT exists; detaching.";
      `$HDIUTIL detach "$SPARSE_IMAGE_MOUNT" >> $LOG_FILE 2>&1`
      if [ $? -ne 0 ] ; then
        logWarn "mountSparseImageRO(): '$HDIUTIL detach' reported errors on $ZPOOL_NAME; exiting...";
      fi;
  fi;

  logInfo "mountSparseImageRO(): Done.";
}
