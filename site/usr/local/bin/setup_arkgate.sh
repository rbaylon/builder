#!/bin/sh

set -e
logfile=/var/log/install.site.log
rcctl enable sshd

passwd=admin12345
echo "creating arkgate group" > $logfile
groupadd arkgate
echo "done" >> $logfile

echo "Creating admin user..." >> $logfile
adduser -batch admin arkgate $passwd -unencrypted
echo "done" >> $logfile

echo "Making pppacX devices..." >> $logfile
cd /dev/
./MAKEDEV pppac1
./MAKEDEV pppac2
./MAKEDEV pppac3
./MAKEDEV pppac4
./MAKEDEV pppac5
./MAKEDEV pppac6
./MAKEDEV pppac7
echo "done" >> $logfile

echo "install.site: custom provisioning complete" >> $logfile

