#
# This file is sourced by snapshot.sh so it refers to several parameters
# defined in that script: 
#
#-----------------------------------------------------------------------
#------------- User Logging Parameters ---------------------------------
#-----------------------------------------------------------------------
LOG_LEVEL=$LOG_INFO; # $LOG_TRACE > $LOG_DEBUG > $LOG_INFO > $LOG_WARNING > $LOG_ERROR > $LOG_FATAL
SILENT=no; # no - print to console; yes - suppress console output

#-----------------------------------------------------------------------
#------------- User Sparse Image File ----------------------------------
#-----------------------------------------------------------------------
IMAGE_SIZE=; # specify in M (megabytes) or G (gigabytes)
IMAGE_FS_TYPE=; # use either ext4, ext3 or ext2 (must support hard-links)
USER_MOUNT_OPTIONS=; # append comma delimited FS options here
SPARSE_IMAGE_MOUNT=; # attatch image to this mountpoint 
SPARSE_IMAGE_DIR=; # directory storing image file

#-----------------------------------------------------------------------
#------------- User Defined Intervals Parameters -----------------------
#-----------------------------------------------------------------------
HOUR_INTERVAL=1; # make snapshots every hour
DAY_INTERVAL=1; # rotate dailies once a day, every day
WEEK_INTERVAL=1; # rotate weeklies once a week, every week
