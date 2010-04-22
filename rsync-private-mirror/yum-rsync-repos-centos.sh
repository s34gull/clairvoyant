#!/bin/bash

#
# The following actions apply to all of the repositories (4, 5; i386 and x86_64)
# 
# Kickoff a clamscan of the repos
#
echo "`date`: Centos repo mirror: Starting..." >> /var/log/messages;

cp -al /var/www/html/centos /var/www/html/.centos;
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: cp -al failed; exiting..." >> /var/log/messages;
  exit 1;
fi;

CENTOS_REPO_ROOT="centos.mirrors.tds.net/CentOS"

for RELEASE_VER in "4" "5"; 
do
  for BASE_ARCH in "i386" "x86_64";
  do
    if [[ ${RELEASE_VER} == "4" ]] && [[ ${BASE_ARCH} == "i386" ]] ; then
      echo "`date`: Centos repo mirror: Skipping CentOS ${RELEASE_VER} for ${BASE_ARCH} ..." >> /var/log/yum-rsync-repos-centos.log;
      continue;
    fi
    for REPO in addons centosplus contrib extras updates;
    do
      echo "`date`: rsync --archive --verbose --partial --sparse --delete  rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
      --exclude=debug/ /var/www/html/.centos/${RELEASE_VER}/${REPO}/" >> /var/log/yum-rsync-repos-centos.log;

      sudo su reposync -c "rsync --archive --verbose --partial --sparse --delete  rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
      --exclude=debug/ /var/www/html/.centos/${RELEASE_VER}/${REPO}/" >> /var/log/yum-rsync-repos-centos.log 2>&1;

      if [ $? -ne 0 ]; then
        echo "`date`: Centos repo mirror: [${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH}] rsync failed; continuing..." >> /var/log/messages;
      fi; 
    done;
  done;
done;

# Kickoff a clamscan of the repos
#
clamdscan --fdpass --multiscan --remove /var/www/html/.centos >> /var/log/yum-rsync-repos-centos.log 2>&1;
if [ $? -eq 1 ]; then
  echo "`date`: Centos repo mirror: clamscan detected and removed infected files; contiuing..." >> /var/log/messages;
else 
  if [ $? -eq 2 ]; then
    echo "`date`: Centos repo mirror: clamscan encountered an error; exiting..." >> /var/log/messages;
    exit 1;
  fi;
fi; 

rm -rf /var/www/html/centos;
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: rm -rf failed; exiting..." >> /var/log/messages;
  exit 1;
else 
  mv /var/www/html/.centos /var/www/html/centos;
  if [ $? -ne 0 ]; then
    echo "`date`: Centos repo mirror: mv failed; exiting..." >> /var/log/messages;
    exit 1;
  fi;
fi;

echo "`date`: Centos repo mirror: Complete." >> /var/log/messages;
exit 0;
