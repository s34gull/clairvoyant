#!/bin/bash
# ----------------------------------------------------------------------
# stop_vboxheadless
# ----------------------------------------------------------------------
# Suspend VirtualBox VMs (if running/paused) listed in config file.
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
PREFIX="`date` $0:";
CONFIG=/etc/vbox/headless.config;
LOG=/var/log/messages;
SLEEP_LIMIT=120;

if [ ! -f $CONFIG ] ; then
  echo "$NAME: Unable to read config file $CONFIG; exiting.";
  exit 1;
fi;

exec 3<&0;
exec 0<"$CONFIG";
while read -r SERVER;
do
  VMNAME=`echo $SERVER | cut -d ' ' -f1`;
  STATE=$(VBoxManage showvminfo $VMNAME --machinereadable | grep 'VMState=' | cut -d '=' -f2);
  STATE=`echo $STATE | sed "s/\"//g"`;
  echo "$PREFIX: VirtualBox VM $VMNAME in VMState=$STATE."; 
  if [ $STATE != saved ] && [ $STATE != poweroff ] ; then
    echo "$PREFIX: Suspending VirtualBox VM $VMNAME...";
    VBoxManage controlvm $VMNAME savestate; # call blocks until complete so no looping
    echo "$PREFIX: VirtualBox VM $VMNAME now in VMState=$STATE."; 
  fi;
done;

exec 0<&3;
exit 0;
