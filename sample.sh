#!/bin/sh
cd
MAILDIRSYNC_OPTS="-rvv -a md5 --backup=/tmp/emails_deleted --rsh-sep=, --rsh=ssh,-C"
SLEEP_FOR=300
# MAILDIRSYNC_OPTS="-rvv"
while true
do
    # calculating the MD5 sum of the old status file
    MD5OLD=`gunzip <lib/maildirsync_laptop_desktop.gz | md5sum`
    # do the synchronization
    echo "`date`: Synchronizing: desktop -> laptop"
    maildirsync $MAILDIRSYNC_OPTS $@ desktop:Maildir Maildir lib/maildirsync_desktop_laptop.gz
    echo "`date`: laptop -> desktop"
    maildirsync $MAILDIRSYNC_OPTS $@ Maildir desktop:Maildir lib/maildirsync_laptop_desktop.gz
    # checking if the status file is changed. If it is changed, then we
    # restart the synchronization. (We synchronize until it is not changed)
    if [ "$MD5OLD" = "`gunzip <lib/maildirsync_laptop_desktop.gz | md5sum`" ]
    then
	echo "`date`: sleeping for $SLEEP_FOR seconds and restart"
	sleep $SLEEP_FOR
    else
	echo "`date`: Data changed, resyncing..."
    fi
done 2>&1 | tee -a "$HOME/maildirsync-`date +%Y%m%d`.$$.log"

