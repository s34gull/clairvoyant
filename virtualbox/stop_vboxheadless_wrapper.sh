#!/bin/bash
# ----------------------------------------------------------------------
# stop_vboxheadless_wrapper
# ----------------------------------------------------------------------
# Run the stop_vboxheadless.sh script as another user.
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
USERAS=; # username to execute start script; must be owner and aware of all VMs in /etc/vbox/headless.config
LOG=; # file to which ths script should append status messages

su - $USERAS -c "/usr/local/bin/stop_vboxheadless.sh" >> $LOG 2>&1;

exit $?;
