#!/bin/bash
# Bootstrap script that either sets up a fresh XDMoD test instance or upgrades
# an existing one.  This code is only designed to work inside the XDMoD test
# docker instances. However, since it is designed to test a real install, the
# set of commands that are run would work on a real production system.

BASEDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REF_SOURCE=`realpath $BASEDIR/../artifacts/xdmod/referencedata`
REPODIR=`realpath $BASEDIR/../../`
REF_DIR=/var/tmp/referencedata

function copy_template_httpd_conf {
    cp /usr/share/xdmod/templates/apache.conf /etc/httpd/conf.d/xdmod.conf
}

if [ -z $XDMOD_REALMS ]; then
    export XDMOD_REALMS=jobs,storage,cloud
fi

cp -r $REF_SOURCE /var/tmp/

set -e
set -o pipefail

PYTHON_SCIPY=python3-scipy
if [ `rpm -E %{rhel}` = 7 ]; then
    PYTHON_SCIPY=python36-scipy
fi

# Install python dependencies for the image hash comparison algorithm
yum install -y python3 python3-six python3-numpy python3-pillow ${PYTHON_SCIPY}
pip3 install imagehash==4.2.1
cp $REPODIR/tests/ci/scripts/imagehash /root/bin

# ensure php error logging is set to E_ALL (recommended setting for development)
sed -i 's/^error_reporting = .*/error_reporting = E_ALL/' /etc/php.ini

if [ "$XDMOD_TEST_MODE" = "fresh_install" ];
then
    rpm -qa | grep ^xdmod | xargs yum -y remove || true
    rm -rf /etc/xdmod

    rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql
    yum -y install ~/rpmbuild/RPMS/*/*.rpm
    copy_template_httpd_conf
    ~/bin/services start
    mysql -e "CREATE USER 'root'@'gateway' IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'gateway' WITH GRANT OPTION;
    FLUSH PRIVILEGES;"

    # TODO: Replace diff files with hard fixes
    # Modify integration sso tests to work with cloud realm
    if [ "$XDMOD_REALMS" = "cloud" ]; then
        if ! patch --dry-run -Rfsup1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff >/dev/null; then
            # -- Fix users searched in SSO test
            patch -up1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff
        fi
    else
        if patch --dry-run -Rfsup1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff >/dev/null; then
            # -- Reverse previous patch
            patch -R -up1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff
        fi
    fi

    expect $BASEDIR/scripts/xdmod-setup-start.tcl | col -b

    if [[ "$XDMOD_REALMS" == *"jobs"* ]]; then
        expect $BASEDIR/scripts/xdmod-setup-jobs.tcl | col -b
    fi
    if [[ "$XDMOD_REALMS" == *"storage"* ]]; then
        expect $BASEDIR/scripts/xdmod-setup-storage.tcl | col -b
    fi
    if [[  "$XDMOD_REALMS" == *"cloud"* ]]; then
        expect $BASEDIR/scripts/xdmod-setup-cloud.tcl | col -b
    fi

    expect $BASEDIR/scripts/xdmod-setup-finish.tcl | col -b


    xdmod-import-csv -t hierarchy -i $REF_DIR/hierarchy.csv
    xdmod-import-csv -t group-to-hierarchy -i $REF_DIR/group-to-hierarchy.csv

    if [[ "$XDMOD_REALMS" == *"jobs"* ]];
    then
        for resource in $REF_DIR/*.log; do
            sudo -u xdmod xdmod-shredder -r `basename $resource .log` -f slurm -i $resource;
        done
    fi

    sudo -u xdmod xdmod-ingestor

    if [[ "$XDMOD_REALMS" == *"cloud"* ]];
    then
        last_modified_start_date=$(date +'%F %T')
        sudo -u xdmod xdmod-shredder -r openstack -d $REF_DIR/openstack -f openstack
        sudo -u xdmod xdmod-shredder -r nutsetters -d $REF_DIR/nutsetters -f openstack
        sudo -u xdmod xdmod-shredder -r openstack -d $REF_DIR/openstack_resource_specs -f cloudresourcespecs

        sudo -u xdmod xdmod-import-csv -t cloud-project-to-pi -i $REF_DIR/cloud-pi-test.csv
        sudo -u xdmod xdmod-shredder -r openstack -d $REF_DIR/openstack_error_sessions -f openstack
        sudo -u xdmod xdmod-ingestor --datatype openstack
        sudo -u xdmod xdmod-ingestor --aggregate=cloud --last-modified-start-date "$last_modified_start_date"
    fi

    if [[ "$XDMOD_REALMS" == *"storage"* ]];
    then
        for storage_dir in $REF_DIR/storage/*; do
            sudo -u xdmod xdmod-shredder -f storage -r $(basename $storage_dir) -d $storage_dir
        done
        last_modified_start_date=$(date +'%F %T')
        sudo -u xdmod xdmod-ingestor --datatype storage
        sudo -u xdmod xdmod-ingestor --aggregate=storage --last-modified-start-date "$last_modified_start_date"
    fi

    sudo -u xdmod xdmod-import-csv -t names -i $REF_DIR/names.csv
    sudo -u xdmod xdmod-ingestor
    php $BASEDIR/scripts/create_xdmod_users.php

fi

if [ "$XDMOD_TEST_MODE" = "upgrade" ];
then
    yum -y install ~/rpmbuild/RPMS/*/*.rpm

    copy_template_httpd_conf
    sed -i 's#http://localhost:8080#https://localhost#' /etc/xdmod/portal_settings.ini

    ~/bin/services start

    # TODO: Replace diff files with hard fixes
    # Modify integration sso tests to work with cloud realm
    if [ "$XDMOD_REALMS" = "cloud" ]; then
        if ! patch --dry-run -Rfsup1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff >/dev/null; then
            # -- Fix users searched in SSO test
            patch -up1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff
        fi
    else
        if patch --dry-run -Rfsup1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff >/dev/null; then
            # -- Reverse previous patch
            patch -R -up1 --directory=$REPODIR < $BASEDIR/diff/SSOLoginTest.php.diff
        fi
    fi

    expect $BASEDIR/scripts/xdmod-upgrade.tcl | col -b

    if [[ "$XDMOD_REALMS" == *"storage"* ]];
    then
        for storage_dir in $REF_DIR/storage/*; do
            sudo -u xdmod xdmod-shredder -f storage -r $(basename $storage_dir) -d $storage_dir
        done
        last_modified_start_date=$(date +'%F %T')
        sudo -u xdmod xdmod-ingestor --datatype storage
        sudo -u xdmod xdmod-ingestor --aggregate=storage --last-modified-start-date "$last_modified_start_date"
    fi
fi
