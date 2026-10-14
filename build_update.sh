#!/bin/sh

BUILD_DIR=`pwd`
mkdir updates/tmp
rm -rf updates/tmp/*
cp -v install.sh updates/tmp/
su - admin -c "sh ${BUILD_DIR}/buildapps.sh $BUILD_DIR"
sh "${BUILD_DIR}/version.sh" bump >/dev/null
cp -rv ${BUILD_DIR}/site/usr/local/arkgate/* ${BUILD_DIR}/updates/tmp/ 
version=`head -1 ${BUILD_DIR}/VERSION`
echo -n $version > ${BUILD_DIR}/updates/tmp/UPDATE_VERSION
cd ${BUILD_DIR}/updates/tmp
tar -C ${BUILD_DIR}/updates/tmp -czvf ${BUILD_DIR}/updates/speczisp-${version}.tar.gz *
