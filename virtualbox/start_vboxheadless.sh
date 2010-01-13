#!/bin/bash
# ----------------------------------------------------------------------
# start_vboxheadless
# ----------------------------------------------------------------------
# Start/resume VirtualBox VMs (if powered-off or saved) listed in config file.
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
PREFIX="`date`:$0";
CONFIG=/etc/vbox/headless.config;
LOG=/var/log/messages;
if [ ! -f $CONFIG ] ; then
  echo "$NAME: Unable to read config file $CONFIG; exiting.";
  exit 1;
fi;

exec 3<&0;
exec 0<"$CONFIG";
while read -r SERVER;
do
  VMNAME=`echo $SERVER | cut -d ' ' -f1`;
  RDP_STATE=`echo $SERVER | cut -d ' ' -f2`;
  RDP_PORT=`echo $SERVER | cut -d ' ' -f3`;
  echo "$PREFIX: $VMNAME $RDP_STATE $RDP_PORT";
  STATE=$(VBoxManage showvminfo $VMNAME --machinereadable | grep 'VMState=' | cut -d '=' -f2);
  STATE=`echo $STATE | sed "s/\"//g"`
  echo "$PREFIX: $VMNAME is currently $STATE";
  OPTS="--startvm $VMNAME";
  if [ $STATE != saved ] ; then
    OPTS="$OPTS --vrdp $RDP_STATE";
    if [ $RDP_STATE = on ] ; then
      OPTS="$OPTS --vrdpport $RDP_PORT";
      # if 'off' or 'config' then don't specify a port
    fi;
    # if the state is 'saved' then it is immutable, so don't pass any options
  fi;

  if [ $STATE != running ] ; then
    echo "$PREFIX: Starting VirtualBox VM with VBoxHeadless $OPTS...";
    eval "nohup VBoxHeadless $OPTS &";
  fi;
done;
exec 0<&3;
exit 0;
