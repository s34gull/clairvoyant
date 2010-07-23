#!/bin/bash
# ----------------------------------------------------------------------
# stop_vboxheadless
# ----------------------------------------------------------------------
# Suspend VirtualBox VMs (if running/paused) listed in config file.
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
