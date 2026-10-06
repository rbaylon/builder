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
# relayd's "tls keypair arkgate.local" only ever looks in /etc/ssl (see
# relayd.conf's header comment) and this relayd build can only load an
# RSA key, not the EC key nginx would have been fine with.
mkdir -p /etc/ssl/private
openssl req -x509 -newkey rsa:2048 -keyout /etc/ssl/private/arkgate.local.key -out /etc/ssl/arkgate.local.crt -days 365 -nodes -subj '/CN=arkgate.local'
chmod 600 /etc/ssl/private/arkgate.local.key
mv /usr/local/arkgate_templates/relayd.conf /etc/
rcctl enable relayd
mv /usr/local/arkgate_templates/httpd.conf /etc/
rcctl enable httpd
#only admin can run this script
chown -R admin:admin /usr/local/arkgate
chown -R admin:admin /usr/local/arkgate_templates
chmod 700 /usr/local/arkgate_templates/setup_appadmin.sh
echo "install.site: custom provisioning complete" >> $logfile
echo "" >> /etc/ssh/sshd_config
echo "AllowUsers admin" >> /etc/ssh/sshd_config
for app in srvcman srvcmanui arkgated billportal captiveportal
do
    cp /usr/local/arkgate/${app}/rc.${app} /etc/rc.d/${app}
    chmod 755 /etc/rc.d/${app}
    rcctl enable $app
done
now=`date '+%Y%m%d%H%M'`
echo "specz${now}" > /etc/myname
cp -v /usr/local/arkgate_templates/config.json.arkgated /usr/local/arkgate/arkgated/rundir/config.json
sed -i "s/myname/specz${now}/" /usr/local/arkgate/arkgated/rundir/config.json
cp -v /usr/local/arkgate_templates/modules.json /usr/local/arkgate/srvcman/
/usr/local/arkgate_templates/setup_appadmin.sh
rcctl enable unbound
echo "Phase 2 setup complete."
reboot

