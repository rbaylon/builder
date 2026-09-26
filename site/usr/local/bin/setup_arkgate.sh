#!/bin/sh

set -e
logfile=/var/log/install.site.log
rcctl enable sshd

echo "creating arkgate group" > $logfile
groupadd arkgate
usermod -G arkgate admin
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

echo "Installing golang..." >> $logfile
pkg_add go
echo "Done" >> $logfile
echo "pfctl -f /etc/pf.conf" >> /etc/rc.local
echo "rm -f /var/arkgated.sock" >> /etc/rc.local
echo "install.site: custom provisioning complete" >> $logfile

