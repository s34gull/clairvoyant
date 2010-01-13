#!/bin/bash
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
  SLEPT=0;
  STATE=$(VBoxManage showvminfo $VMNAME --machinereadable | grep 'VMState=' | cut -d '=' -f2);
  STATE=`echo $STATE | sed "s/\"//g"`;
  echo "$PREFIX: VirtualBox VM $VMNAME in VMState=$STATE."; 
  if [ $STATE != saved ] && [ $STATE != poweroff ] ; then
    echo "$PREFIX: Suspending VirtualBox VM $VMNAME...";
    VBoxManage controlvm $VMNAME savestate;
    echo "$PREFIX: VirtualBox VM $VMNAME now in VMState=$STATE after $SLEPT seconds."; 
  fi;
done;

exit 0;
