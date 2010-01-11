#!/bin/bash
# ----------------------------------------------------------------------
# clairvoyant
# ----------------------------------------------------------------------
# Creates a rotating snapshot of the contents of $INCLUDES whenever 
# called (minus the contents of the .exlude files). Snapshots are 
# written to a specified sparse disk image hosted file system (via 
# loopback) for portability. If the filesystem on the disk image 
# supports it, space is preserved via hardlinks.
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
su - snapshot -c "/usr/local/bin/snapshot.sh &"