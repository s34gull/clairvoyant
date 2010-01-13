#!/bin/bash
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
    fi;
  fi;
  if [ $STATE != running ] ; then
    echo "$PREFIX: Starting VirtualBox VM $VMNAME $OPTS...";
    eval "nohup VBoxHeadless $OPTS &";
  fi;
done;

exit 0;
