#!/bin/sh

username=$1
password=$2
# use this to generate
b64creds=`printf "{$username}:${password}" | uuencode -m - | egrep -v "begin|===="`