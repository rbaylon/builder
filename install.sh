#!/bin/sh

mydir=`pwd`
cd $mydir
myversion=`cat UPDATE_VERSION`
echo "Installing specz ISP version $myversion"

distdir=/usr/local/arkgate

install -m 755 -o admin -g admin srvcman/srvcman /usr/local/arkgate/srvcman/
install -m 755 -o admin -g admin srvcmanui/srvcmanui ${distdir}/srvcmanui/
cp -fr srvcmanui/layouts ${distdir}/srvcmanui/
cp -fr srvcmanui/static ${distdir}/srvcmanui/
cp -fr srvcmanui/modules ${distdir}/srvcmanui/
cp -f srvcmanui/utils/*.html ${distdir}/srvcmanui/
install -m 755 arkgated/arkgated ${distdir}/arkgated/
install -m 755 -o admin -g admin captiveportal/captiveportal ${distdir}/captiveportal/
cp -fr captiveportal/templates ${distdir}/captiveportal/
install -m 755 -o admin -g admin billportal/billportal ${distdir}/billportal/
cp -fr billportal/ ${distdir}/billportal/
cp -fr billportal/static ${distdir}/billportal/

echo "update done."