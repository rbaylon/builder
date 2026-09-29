#!/binsh

build_app() {
	cd $1
	git pull
	make dist
}

buildir_dir=$1
src_base=~/go/src/github.com/rbaylon
dist_dir=/usr/local/arkgate
rm -rf $dist_dir/*
rm -rf $buildir_dir/site/usr/local/arkgate/*
for app in arkgated srvcman srvcmanui billportal subsportal
do
    echo "building $app"
    build_app ${src_base}/${app}
    echo "done building $app"
    echo "Moving $app bin files to site dir"
    cp -v /usr/local/arkgate_templates/*.${app} ${dist_dir}/${app}/
    if [ "${app}" = "subsportal" ];then
        cp -v /usr/local/arkgate_templates/*.${app} ${dist_dir}/captiveportal/.env
        tar -C ${buildir_dir}/site/usr/local/arkgate -xzvf ${dist_dir}/captiveportal.tar.gz
    else
        cp -v /usr/local/arkgate_templates/*.${app} ${dist_dir}/${app}/.env
        tar -C ${buildir_dir}/site/usr/local/arkgate -xzvf ${dist_dir}/${app}.tar.gz
    fi
    echo "Done moving $app files to site dir" 
done