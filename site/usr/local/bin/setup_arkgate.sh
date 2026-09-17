#!/bin/sh
# Runs chroot(8)'d into the freshly-installed target system, after all
# sets (including this site set) have been extracted. See
# install.site(5) and the "Custom File Sets" section of
# https://www.openbsd.org/faq/faq4.html.
#
# Keep this idempotent -- customize as the project grows.

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

