#!/bin/bash
su - vbox -c "/usr/local/bin/start_vboxheadless.sh" >> /var/log/messages 2>&1;

exit 0;
