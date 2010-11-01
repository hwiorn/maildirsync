#!/usr/local/bin/bash
ME=`whoami`
if [ $ME != "root" ] ; then
        echo "You must be root to run this script"
        exit
fi

echo "Have you configured mailbalance.conf? (yes or no)"
read -e A
if [ "${A}" = yes ] ; then
	echo "Proceeding..."
else
	echo "You must configure all values in mailbalance.conf before running this..."
	exit
fi






if (whereis drsync.pl | egrep "drsync.pl$") 2>&1 > /dev/null ; then 
	echo "drsync.pl found in runpath .. Continuing to install" ; 
else 
	echo "Please install drsync-0.4.2 or greater before continuing ( http://hacks.dlux.hu/drsync/ ).  Be sure that drsync.pl is in your runpath" ; 
	echo "Note: You must install this package on both this slave and the master that it will sync with!!!!"
	exit;
fi

if (whereis maildirsync.pl | egrep "maildirsync.pl$") 2>&1 > /dev/null ; then 
        echo "maildirsync.pl found in runpath .. Continuing to install" ;                                                 
else	
        echo "Please install maildirsync-0.5 or greater before continuing ( http://hacks.dlux.hu/maildirsync/ ).  Be sure that mailsync.pl is in your runpath" ;
	echo "Note: You must install this package on both this slave and the master that it will sync with!!!!"
	exit;
fi


echo "You will need a set of rsa keys for ${ME} to use this software" 
echo "Do you want to create a key for ${ME} now? (yes or no .. If you already have one say no)"
read -e A
if [ "${A}" = "yes" ] ; then
	ssh-keygen -t rsa -q -N "" -f ${HOME}/.ssh/id_rsa
fi



echo "Now you need to distribute the public key to this slave host's master"
echo "Would you like to transfer the key now? (yes or no .. you will need the password for ${ME} on the master)"
read -e A
if [ "${A}" = "yes" ] ; then
	echo "What is the FQDN or IP Address of the master? (yes or no)"
	read -e MASTER
	echo "HOME: ${HOME} on  MASTER: ${MASTER}"
	scp ${HOME}/.ssh/id_rsa.pub ${MASTER}:${HOME}/.ssh/authorized_keys
fi


source ./mailbalance.conf


#####################################################################################
# Set up remote sync environment                                                    #
#####################################################################################

PROGDIRNAME=`echo ${PROGDIR} | sed -e 's/\///' | sed -e 's/.*\///g'`
PROGDIRPATH=`dirname ${PROGDIR}`

if (ssh ${MASTER} "ls -a ${PROGDIRPATH}" 2>/dev/null | grep "${PROGDIRNAME}" > /dev/null); then
                echo "${PROGDIR} exists on the master""
        else
               echo "Creating ${PROGDIR} tree on master""
               ssh ${MASTER} "mkdir -p ${PROGDIR}/lib" ;
               ssh ${MASTER} "mkdir  ${PROGDIR}/log" ;
               ssh ${MASTER} "mkdir  ${PROGDIR}/trashbags"

fi

echo ''
echo "If all install routines of above questions completed, you are ready to use the software. Otherwise fix whatever broke the install and rerun the intaller."
