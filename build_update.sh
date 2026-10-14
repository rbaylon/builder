#!/bin/sh

set -e
BUILD_DIR=`pwd`
cd $BUILD_DIR
mkdir -p ${BUILD_DIR}/updates/tmp
rm -rf ${BUILD_DIR}/updates/tmp/*
cp -v install.sh ${BUILD_DIR}/updates/tmp/
su - admin -c "sh ${BUILD_DIR}/buildapps.sh $BUILD_DIR"
sh "${BUILD_DIR}/version.sh" bump >/dev/null
cp -rv ${BUILD_DIR}/site/usr/local/arkgate/* ${BUILD_DIR}/updates/tmp/ 
version=`head -1 ${BUILD_DIR}/VERSION`
echo -n $version > ${BUILD_DIR}/updates/tmp/UPDATE_VERSION 
tar -C ${BUILD_DIR}/updates/ -czvf speczisp-${version}.tar.gz ${BUILD_DIR}/updates/tmp/*