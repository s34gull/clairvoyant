#!/bin/bash

#
# The following actions apply to all of the repositories (4, 5; i386 and x86_64)
# 
# Kickoff a clamscan of the repos
#

LOCAL_REPO_MOUNT=/var/www/repos
LOCAL_CENTOS_REPO=${LOCAL_REPO_MOUNT}/centos
LOCAL_CENTOS_REPO_WORKING=${LOCAL_REPO_MOUNT}/.centos
CENTOS_REPO_ROOT=centos.mirrors.tds.net/CentOS
MESSAGE_LOG=/var/log/messages
DETAIL_LOG=/var/log/yum-rsync-repos-centos.log

echo "`date`: Centos repo mirror: Starting..." >> ${MESSAGE_LOG};

mount -o remount,rw,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT}
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: Remount rw ${LOCAL_REPO_MOUNT} failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
fi;

cp -al ${LOCAL_CENTOS_REPO} ${LOCAL_CENTOS_REPO_WORKING};
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: cp -al failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
fi;


for RELEASE_VER in "4" "5"; 
do
  for BASE_ARCH in "i386" "x86_64";
  do
    if [[ ${RELEASE_VER} == "4" ]] && [[ ${BASE_ARCH} == "i386" ]] ; then
      echo "`date`: Centos repo mirror: Skipping CentOS ${RELEASE_VER} for ${BASE_ARCH} ..." >> ${DETAIL_LOG};
      continue;
    fi
    for REPO in addons centosplus contrib extras updates;
    do
      echo "`date`: rsync --archive --verbose --partial --sparse --delete  rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
      --exclude=debug/ ${LOCAL_CENTOS_REPO_WORKING}/${RELEASE_VER}/${REPO}/" >> ${DETAIL_LOG};

      sudo su reposync -c "rsync --archive --verbose --partial --sparse --delete  rsync://${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH} \
      --exclude=debug/ ${LOCAL_CENTOS_REPO_WORKING}/${RELEASE_VER}/${REPO}/" >> ${DETAIL_LOG} 2>&1;

      if [ $? -ne 0 ]; then
        echo "`date`: Centos repo mirror: [${CENTOS_REPO_ROOT}/${RELEASE_VER}/${REPO}/${BASE_ARCH}] rsync failed; continuing..." >> ${MESSAGE_LOG};
      fi; 
    done;
  done;
done;

# Kickoff a clamscan of the repos
#
clamdscan --fdpass --multiscan --remove ${LOCAL_CENTOS_REPO_WORKING} >> ${DETAIL_LOG} 2>&1;
if [ $? -eq 1 ]; then
  echo "`date`: Centos repo mirror: clamscan detected and removed infected files; contiuing..." >> ${MESSAGE_LOG};
else 
  if [ $? -eq 2 ]; then
    echo "`date`: Centos repo mirror: clamscan encountered an error; exiting..." >> ${MESSAGE_LOG};
    exit 1;
  fi;
fi; 

rm -rf ${LOCAL_CENTOS_REPO};
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: rm -rf failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
else 
  mv ${LOCAL_CENTOS_REPO_WORKING} ${LOCAL_CENTOS_REPO};
  if [ $? -ne 0 ]; then
    echo "`date`: Centos repo mirror: mv failed; exiting..." >> ${MESSAGE_LOG};
    exit 1;
  fi;
fi;

mount -o remount,ro,noatime,nodiratime,noexec ${LOCAL_REPO_MOUNT}
if [ $? -ne 0 ]; then
  echo "`date`: Centos repo mirror: Remount ro ${LOCAL_REPO_MOUNT} failed; exiting..." >> ${MESSAGE_LOG};
  exit 1;
fi;

echo "`date`: Centos repo mirror: Complete." >> ${MESSAGE_LOG};
exit 0;
