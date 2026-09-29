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
pkg_add go snmp_exporter
echo "Done" >> $logfile
echo "pfctl -f /etc/pf.conf" >> /etc/rc.local
echo "rm -f /var/arkgated.sock" >> /etc/rc.local

echo "Setting up console menu login shell for admin..." >> $logfile
menu=/usr/local/bin/console-menu
chmod 755 $menu
grep -qxF $menu /etc/shells || echo $menu >> /etc/shells
cat >> /etc/doas.conf <<EOF
permit nopass :arkgate cmd pfctl args -si
permit nopass :arkgate cmd pfctl args -f /etc/pf.conf
permit nopass :arkgate cmd reboot
permit nopass :arkgate cmd halt args -p
EOF
doas -C /etc/doas.conf
usermod -s $menu admin
echo "Done" >> $logfile
chown -R admin:admin /usr/local/arkgate
# relayd's "tls keypair arkgate.local" only ever looks in /etc/ssl (see
# relayd.conf's header comment) and this relayd build can only load an
# RSA key, not the EC key nginx would have been fine with.
mkdir -p /etc/ssl/private
openssl req -x509 -newkey rsa:2048 -keyout /etc/ssl/private/arkgate.local.key -out /etc/ssl/arkgate.local.crt -days 365 -nodes -subj '/CN=arkgate.local'
chmod 600 /etc/ssl/private/arkgate.local.key
mv /usr/local/arkgate/relayd.conf /etc/
rcctl enable relayd
mv /usr/local/arkgate/httpd.conf /etc/
rcctl enable httpd
echo "install.site: custom provisioning complete" >> $logfile
reboot

