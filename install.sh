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
echo "update done. Restarting services"
exitstatus=0
for s in srvcman srvcmanui arkgated captiveportal billportal
do
    rcctl restart $s
    if [ $? -ne 0 ];then
        case "$s" in
            srvcman)
                exitstatus=1
                ;;
            srvcmanui)
                exitstatus=2
                ;;
            arkgated)
                exitstatus=3
                ;;
            captiveportal)
                exitstatus=4
                ;;
            billportal)
                exitstatus=5
                ;;
        esac
    fi
done
echo "done."
exit $exitstatus