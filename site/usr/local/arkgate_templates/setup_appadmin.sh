#!/bin/sh

print "A reboot is required for the changes to take effect! Are you sure? [yes/no]: "
read proceed
if [ $proceed != "yes" ];then
    exit
fi
print "Enter app admin username: "
read username
print "Enter app admin password: "
read password
# use this to generate
b64creds=`printf "{$username}:${password}" | uuencode -m - | egrep -v "begin|===="`
secret_key=`openssl rand -hex 32`
session_key=`openssl rand -hex 32`
build_dir=`pwd`
now=`date '+%Y%m%d%H%M'`
for e in srvcman srvcmanui arkgated
do
    cp /usr/local/arkgate/${e}/.env /usr/local/arkgate/${e}/.env.${now}
    if [ ${e} = "arkgated" ];then
        cp -f ${build_dir}/site/usr/local/arkgate_templates/app.config.${e} /usr/local/arkgate/${e}/app.config
    else
        cp -f ${build_dir}/site/usr/local/arkgate_templates/.env.${e} /usr/local/arkgate/${e}/.env
    fi      
done

for e in srvcman srvcmanui
do
    sed -i "s/appadmin/${username}/" /usr/local/arkgate/${e}/.env
    sed -i "s/apppw/${password}/" /usr/local/arkgate/${e}/.env
done

sed -i "s/appcreds/${b64creds}/" /usr/local/arkgate/arkgated/app.config
sed -i "s/appsecret/${secret_key}/" /usr/local/arkgate/srvcman/.env
sed -i "s/appsessionkey/${session_key}/" /usr/local/arkgate/srvcmanui/.env

print "Password reset done. You may now reboot the system."