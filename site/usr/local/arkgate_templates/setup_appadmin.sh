#!/bin/sh

username=$1
password=$2
# use this to generate
b64creds=`printf "{$username}:${password}" | uuencode -m - | egrep -v "begin|===="`
secret_key=`openssl rand -hex 32`
session_key=`openssl rand -hex 32`
build_dir=`pwd`
for e in srvcman srvcmanui
do
    sed -i "s/appadmin/${username}/" ${build_dir}/site/usr/local/arkgate/${e}/.env
    sed -i "s/apppw/${password}/" ${build_dir}/site/usr/local/arkgate/${e}/.env
done

sed -i "s/appcreds/${b64creds}/" ${build_dir}/site/usr/local/arkgate/arkgated/app.config
sed -i "s/appsecret/${secret_key}/" ${build_dir}/site/usr/local/arkgate/srvcman/.env
sed -i "s/appsessionkey/${session_key}/" ${build_dir}/site/usr/local/arkgate/srvcmanui/.env