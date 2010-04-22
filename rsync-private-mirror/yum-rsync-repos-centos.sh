#!/bin/bash

#
# The following actions apply to all of the repositories (4, 5; i386 and x86_64)
# 
# Kickoff a clamscan of the repos
#
echo "`date`: Centos mirror rsync starting..." >> /var/log/messages;

cp -al /var/www/html/centos /var/www/html/.centos;
if [ $? -ne 0 ]; then
  echo "`date`: Centos mirror cp -al failed; exiting..." >> /var/log/messages;
  exit 1;
fi;

for releasever in "4" "5"; 
do
  for basearch in "i386" "x86_64";
  do
    if [[ ${releasever} == "4" ]] && [[ ${basearch} == "i386" ]] ; then
      echo "`date`: Skipping CentOS ${releasever} for ${basearch} ..." >> /var/log/yum-rsync-repos-centos.log;
      continue;
    fi
    for repo in addons centosplus contrib extras updates;
    do
      echo "`date`: rsync --archive --verbose --partial --sparse --delete  rsync://centos.mirrors.tds.net/CentOS/${releasever}/${repo}/${basearch} \
      --exclude=debug/ /var/www/html/.centos/${releasever}/${repo}/" >> /var/log/yum-rsync-repos-centos.log;

      sudo su reposync -c "rsync --archive --verbose --partial --sparse --delete  rsync://centos.mirrors.tds.net/CentOS/${releasever}/${repo}/${basearch} \
      --exclude=debug/ /var/www/html/.centos/${releasever}/${repo}/" >> /var/log/yum-rsync-repos-centos.log 2>&1;

      if [ $? -ne 0 ]; then
        echo "`date`: Centos mirror [${releasever}/${repo}/${basearch}] rsync failed; continuing..." >> /var/log/messages;
      fi; 
    done;
  done;
done;

# Kickoff a clamscan of the repos
#
clamdscan --fdpass --multiscan --remove /var/www/html/.centos >> /var/log/yum-rsync-repos-centos.log 2>&1;
if [ $? -eq 1 ]; then
  echo "`date`: Centos mirror clamscan detected and removed infected files; contiuing..." >> /var/log/messages;
else 
  if [ $? -eq 2 ]; then
    echo "`date`: Centos mirror clamscan encountered an error; exiting..." >> /var/log/messages;
    exit 1;
  fi;
fi; 

rm -rf /var/www/html/centos;
if [ $? -ne 0 ]; then
  echo "`date`: Centos mirror rm -rf failed; exiting..." >> /var/log/messages;
  exit 1;
else 
  mv /var/www/html/.centos /var/www/html/centos;
  if [ $? -ne 0 ]; then
    echo "`date`: Centos mirror mv failed; exiting..." >> /var/log/messages;
    exit 1;
  fi;
fi;

echo "`date`: Centos mirror rsync complete." >> /var/log/messages;
exit 0;
