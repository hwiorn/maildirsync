
#!/usr/local/bin/bash

# $@ SHOULD HOLD THREE ARGS:
# $1 =  THE MASTER'S HOSTNAME OR IP 
# $2 =  A USERNAME
# $3 =  THE PROGRAM DIRECTORY
# $4 =  MODE

ME=''
ME=`whoami`
if [ $ME != "root" ] ; then
        echo "You must be root to run this script"
        exit
fi

source ./functions.inc

HOME=/home/${2}
cd $HOME
PROGDIR=${3};
MDSDIGEST=MAILDIRSYNC.gz
DRDIGEST=DRSYNC.bz2
MAILDIRSYNC_OPTS="-r -a md5 --backup=${PROGDIR}/trashbags/${2} --rsh-sep=, --rsh=ssh,-C"

TOKEN='';

while [ "${TOKEN}" = '' ] ; do
rolllog ${2}
echo "Beginning to log..."
echo ">>>>-----> ${2} - `date "+%H:%M:%S on %m-%d-%Y"` <-----<<<<"

    maildirsync.pl $MAILDIRSYNC_OPTS $1:${HOME}/Maildir ${HOME}/Maildir ${PROGDIR}/lib/${2}.${MDSDIGEST}
	fixperms ${1} ${2}

    maildirsync.pl $MAILDIRSYNC_OPTS ${HOME}/Maildir $1:${HOME}/Maildir ${PROGDIR}/lib/${2}.${MDSDIGEST}
	fixperms  ${1} ${2}


    
    drsync.pl --verbose=2  --rsh=ssh --recursive  --state-file=${PROGDIR}/lib/${2}.master.${DRDIGEST} ${HOME}/Maildir $1:${HOME}    
	fixperms ${1} ${2}
    drsync.pl --verbose=2  --rsh=ssh --exclude=BACKUP --recursive --state-file=${PROGDIR}/lib/${2}.slave.${DRDIGEST} $1:${HOME}/Maildir ${HOME}	
	fixperms ${1} ${2}
    drsync.pl --delete-excluded --verbose=2 --backup --rsh=ssh --exclude=BACKUP --recursive --state-file=${PROGDIR}/lib/${2}.slave.${DRDIGEST} $1:${HOME}/Maildir ${HOME}
	fixperms ${1} ${2}


TOKEN=DONE

echo "Ending log entry..."
echo ">>>>-------------------------------------------------------------------------<<<<"
done 2>&1 | tee -a ${PROGDIR}/log/${2}-maildirsync-`date +%Y%m`.log

