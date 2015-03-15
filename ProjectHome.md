At the moment this project is not much more than a collection of scripts that I've written to help me out on the few Ubuntu hosts that I use day-to-day. There isn't anyone involved in the project except me - really, I just wanted a hosted _svn_ instance where I could upload code so that (a) I wouldn't loose changes, (b) I could work without being afraid of making changes and (c) I could share the resulting work.

## [backup](backup.md) ##

A set of `#!/bin/bash` scripts which leverages common GNU utilities to perform regular, unattended, rotated backups of user specified directories (with support for exclusions). It currently features hourly interval snapshots via [rsync](http://samba.anu.edu.au/rsync/), with daily and weekly rotations of predecessor snapshots using `cp` (with [hardlinks](http://en.wikipedia.org/wiki/Hard_link) to reduce disk utilization) to a managed [sparse-file](http://en.wikipedia.org/wiki/Sparse_file) disk image. The script itself is not a daemon, but rather is run regularly via [cron](http://en.wikipedia.org/wiki/Cron)/[anacron](http://anacron.sourceforge.net).

Versions >= 2.3.0 support `btrfs` and use `subvolumes` instead of individual `hardlinks` to further reduce I/O overhead and improve performance, when running on a `btrfs` filesystem.

## [vboxheadless](vboxheadless.md) ##

A set of `#!/bin/bash` scripts that facilitate managed start/resume and suspension of [VirtualBox](http://www.virtualbox.org) virtual machines during host startup and shutdown. Currently supports [Ubuntu](http://www.ubuntu.com) (because that is what use as my main platform - desktop and server; the VMs themselves are primarily Centos 5).