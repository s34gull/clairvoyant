#!/bin/bash
# ----------------------------------------------------------------------
# start_vboxheadless
# ----------------------------------------------------------------------
# Start/resume VirtualBox VMs (if powered-off or saved) listed in config file.
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
  STATE=$(VBoxManage showvminfo $VMNAME --machinereadable | grep 'VMState=' | cut -d '"' -f2);
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
