

# Introduction #

I'm not sure when it occurred to me that I needed a simple on-line incremental backup utility for my Ubuntu laptop. I suppose it was some time after I'd reinstalled the OS twice (Windows and Ubuntu - its a dual boot/virtualized setup with Ubuntu being the primary). For whatever reason, I couldn't find a solution that I liked, and after wandering around the web I came across the (most likely ubiquitous) idea of an hourly snapshot utility that could rotate its older snapshots until a user defined limit was hit. The original script that I found was based on `rsync` (using the `--archive` flag for the hourly snapshots) and `cp` (using hardlinks for the preservation of older hourly, daily and weekly snapshots).

# Features #
Now this approach isn't terribly unique - I won't attempt to make any claim to that effect - but I believe there are a few design goals that set it apart from other implementations using `rsync`:

## v1.0 ##
  * **Simplicity** - It is a pair of `bash` scripts. One script sets user variables and the other controls the invocation of the common utilities to perform the snapshot and rotations. Scheduling is external to the script, so you can utilize cron, anacron, upstart, launchd or any other scheduling mechanism you prefer, or none at all if you prefer manual operation.
  * **Speed** - The utilities operate as quickly as your attached storage will allow (and given modern async filesystem behavior, often faster!)
  * **Minimal Footprint** - If you have the core GNU utilities installed, plus `rsync` you're ready to start protecting your data. There are no dependencies on other frameworks (python, ruby, etc.) or persistence mechanisms (file inclusion/exclusion is text-file based with support for substitutions native to `rsync` so there is no need for external storage like `sqlite`)
  * **Data Integrity** - The destination filesystem is only mounted read-write during snapshot periods. When the script is idle, the destination is mounted read-only to ensure that data cannot be deleted. Filesystem integrity of the disk image is managed normally via `fsck` and `tune2fs` parameters and because the disk image is remounted after the completion of a snapshot the kernel must flush all pending data, ensuring minimal exposure to data loss. In critical situations the disk image may be mounted with the `sync` option at the expense of performance.

## v2.0 ##
  * **Data Portability** - Hardlinks are a great way to save space, but make it impossible to easily migrate snapshot data from one volume to another - unless that volume is itself a disk image. All backups are make to a script-managed sparse-file disk image (with user selectable filesystem and capacity). In the event that you need to relocate the image file to a larger local device, all of the hardlinks are left intact. Even better, the image file can be stored on any network-aware file system (CIFS, NFS, AFP, iSCSI, WebDAV) and then mounted locally.

## v2.1 ##
  * **Data Encryption** - Optionally leverages [cryptsetup](http://www.saout.de/tikiwiki/tiki-index.php?page=cryptsetup) and `dm-crypt` to create and mount AES-256 encrypted snapshot disk images

## v2.2 ##
  * **Resource Friendliness** - Lower I/O overhead during snapshot by minimizing file replication.
  * **Improved Directory Organization** - Time-based snapshot directories are now at the root of backup volume; all backed-up directories are children of the time-directories

## v2.2.1 ##
  * **Resource Friendliness** - Lower I/O overhead during snapshot with `ionice` (runs at a lower I/O priority than normal processes)

## v2.3.0 ##
  * **Speed/Resource Friendliness** - leverage features of `btrfs` to snapshot the root backup subvolume using `btrfs subvolume snapshot` for incremental rotations if kernel >= 2.6.32 (`btrfs` tooling >= 0.19 with support for subvolume deletion); significantly reduces file I/O as we no longer have to link/unlink individual inodes during hardlink creation deletion.

## v2.4.0 ##
  * **ZFS on Mac** - Support ZFS (specifically Zevo implementation) on Mac OS X as a target sparse image filesystem.

## Future ##
  * **Data Integrity** - mount root user access only during snapshot period
  * **Date/Time Snapshot Directory Names** - Utilise yyyy-MM-dd-HHmmss format for snapshot root.
  * **ZFS** - Leverage ZFS snapshots on source volume for consistent backup.