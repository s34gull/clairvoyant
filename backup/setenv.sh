#!/bin/bash
# ----------------------------------------------------------------------
# setenv.sh
# ----------------------------------------------------------------------
# This file is sourced by snapshot.sh so it refers to several parameters
# defined in that script: 
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

#-----------------------------------------------------------------------
#------------- User Logging Parameters ---------------------------------
#-----------------------------------------------------------------------
LOG_LEVEL=$LOG_INFO; # $LOG_TRACE > $LOG_DEBUG > $LOG_INFO > $LOG_WARN > $LOG_ERROR > $LOG_FATAL
SILENT=no; # no - print to console; yes - suppress console output

#-----------------------------------------------------------------------
#------------- User Sparse Image File ----------------------------------
#-----------------------------------------------------------------------
IMAGE_SIZE=; # specify in M (megabytes) or G (gigabytes)
IMAGE_FS_TYPE=; # use either ext4, ext3 or ext2 (must support hard-links)
USER_MOUNT_OPTIONS=; # append comma delimited FS options here
SPARSE_IMAGE_MOUNT=; # attatch image to this mountpoint 
SPARSE_IMAGE_DIR=; # directory storing image file
ENCRYPT=no; # yes or no; yes will use dm-crypt aes-256; requires cryptsetup
PASSPHRASE=; # if ENCRYPT=yes then you must provide a passphrase

#-----------------------------------------------------------------------
#------------- User Defined Intervals Parameters -----------------------
#-----------------------------------------------------------------------
#HOUR_INTERVAL=1; # make snapshots every hour
#DAY_INTERVAL=1; # rotate dailies once a day, every day
#WEEK_INTERVAL=1; # rotate weeklies once a week, every week

# Remember, snap counts start at 0; you cannot alter the HOURLY_SNAP_LIMIT=23
#DAILY_SNAP_LIMIT=29;
#WEEKLY_SNAP_LIMIT=51;

