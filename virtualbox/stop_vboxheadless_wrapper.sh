#!/bin/bash
su - vbox -c "/usr/local/bin/stop_vboxheadless.sh" >> /var/log/messages 2>&1;

exit $?;
