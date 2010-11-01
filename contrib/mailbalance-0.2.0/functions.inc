
function checkuser {
        USER=${1}
        shift
        MATCH=`cat $FILE \
                | sed -e 's/#.*//g'  \
                | awk "/\$USER:.*/{print $1}" \
                | awk -F : '{print $2}' \
              `
        echo $MATCH
}


function fixperms {
	ssh ${1} "chown -R ${2} $HOME/Maildir"
	chown -R ${2} $HOME/Maildir
}

function doit  {
	if [ "${MODE}" = "daemon" ] ; then
		${PROGDIR}/do_ms.sh ${MASTER} ${1} ${PROGDIR} ${MODE} 2>&1 1>/dev/null
	else 
		${PROGDIR}/do_ms.sh ${MASTER} ${1} ${PROGDIR} ${MODE}
	fi
}

function luserprep {
echo "Running local user prep routines for ${1}..."
if [ -d /home/${1} ] ; then
                echo "HOME DIRECTORY EXISTS"
        else
                echo "NO HOME LOCAL DIRECTORY FOR USER: ${1}"
                echo "CREATING LOCAL HOME DIRECTORY"
                mkdir /home/${1}
		echo "NO LOCAL HOME DIRECTORY ON `hostname` FOR USER: ${1} .. CREATED IT"		
		if (chown ${1} /home/${1}) 2> /dev/null ; then 
                        echo "CHANGED OWNERSHIP OF LOCAL HOMEDIRECTORY TO: ${1}"   
		else 
                        echo "CANNOT CHANGE OWNERSHIP OF HOME DIRECTORY FOR USER: ${1} 2> /dev/null"
                        echo "THIS USER PROBABLY DOES NOT EXIST ON THIS SLAVE HOST: `hostname` 2> /dev/null"
                        notify ${1} "CANNOT CHANGE OWNERSHIP OF HOME DIRECTORY FOR USER: ${1}. THIS USER PROBABLY DOES NOT EXIST ON THIS SLAVE HOST: `hostname`"
		fi
fi
if [ -d /home/${1}/Maildir ] ; then
        echo "LOCAL MAILDIR EXISTS"
else
        echo "NO LOCAL MAILDIR .. CREATING NEW MAILDIR NOW"
        maildirmake /home/${1}/Maildir
        chown -R ${1} /home/${1}/Maildir
	if [ -d /home/${1}/Maildir ] ; then
                echo "CREATED TRASHBAGS DIRECTORY FOR USER: ${1}"
        else
                echo "CANNOT CREATE Maildir FOR USER: ${1}"
                notify ${1} "CANNOT CREATE LOCAL USER MAILDIR"
        fi
fi
if [ -d ${PROGDIR}/trashbags/${1} ] ; then
        echo "TRASHBAG DIRECTORY FOR USER EXISTS"
else
        echo "CREATING TRASHBAGS DIRECTORY FOR USER: ${1}"
        mkdir ${PROGDIR}/trashbags/${1}
	if [ -d ${PROGDIR}/trashbags/${1} ] ; then
		echo "CREATED TRASHBAGS DIRECTORY FOR USER: ${1}"
	else
		echo "CANNOT CREATE USER TRASHBAG DIRECTORY FOR USER: ${1}"
		notify ${1} "CANNOT CREATE USER TRASHBAG DIRECTORY"
	fi
fi
echo "Finished running local user prep routines for ${1}..."
}


function ruserprep {
echo "Running remote user prep routines for ${1}..."
if (ssh ${MASTER} "find /home/ -maxdepth 1 -type d -name ${1} | egrep \"${1}$\"") > /dev/null; then
		echo "REMOTE HOME DIRECTORY FOR THIS USER ALREADY EXISTS"
        else
                echo "NO REMOTE HOME DIRECTORY FOR THIS USER .. CREATING IT NOW"
		ssh ${MASTER} "mkdir /home/${1}"
                if (ssh ${MASTER} "find /home/ -maxdepth 1 -type d -name ${1} | egrep \"${1}$\"") > /dev/null; then
                	echo "CREATED REMOTE HOME DIRECTORY FOR USER: ${1}"
	        else
                	echo "CANNOT CREATE REMOTE HOME DIRECTORY FOR USER: ${1}"
			notify ${1} "CANNOT CREATE REMOTE HOME DIRECTORY FOR USER: ${1}.  PERHAPS I CANNOT CONNECT OR DO I HAVE RIGHTS?"
       		fi
		if (ssh ${MASTER} "chown ${1} /home/${1}") 2> /dev/null ; then 
                        echo "CHANGED OWNERSHIP OF REMOTE HOMEDIRECTORY TO: ${1}"
                else
                        echo "CANNOT CHANGE OWNERSHIP OF REMOTE HOME DIRECTORY FOR USER: ${1}"
                        echo "THIS USER PROBABLY DOES NOT EXIST ON THE MASTER HOST: `hostname`"
                        notify ${1} "CANNOT CHANGE OWNERSHIP OF REMOTE HOME DIRECTORY FOR USER: ${1}.  THIS USER PROBABLY DOES NOT EXIST ON THE MASTER HOST: `ssh ${MASTER} \"hostname\"`"
                fi
fi
if (ssh ${MASTER} "find /home/${1}/ -maxdepth 1 -type d -name Maildir | egrep \"Maildir$\"") > /dev/null; then
                echo "REMOTE MAILDIR FOR THIS USER ALREADY EXISTS"
        else
				echo "NO REMOTE MAILDIR .. CREATING NEW MAILDIR NOW"
	        ssh ${MASTER} "maildirmake /home/${1}/Maildir"
	        ssh ${MASTER} "chown -R ${1} /home/${1}/Maildir"
		if (ssh ${MASTER} "find /home/${1}/ -maxdepth 1 -type d -name Maildir | egrep \"Maildir$\"") > /dev/null; then
                        echo "CREATED REMOTE Maildir FOR USER: ${1}"
                else
                        echo "CANNOT CREATE REMOTE Maildir FOR USER: ${1}"       
                        notify ${1} "CANNOT CREATE REMOTE Maildir FOR USER: ${1}"
                 fi
fi
echo "Finished running remote user prep routines for ${1}..."
}


function writeok {
	sed "s/${1}:NOK/${1}:OK/g" ${FILE} 1> ${FILE}.tmp
	mv ${FILE}.tmp ${FILE}
	#for debugging - show if user OK or NOK
	#sed "s/${1}:NOK/${1}:OK/g" ${FILE}
}

function writenok {
	if (egrep "^${1}:NOK" ${FILE} 2>&1) ; then
		echo "USER ALREADY HAS AN ENTRY IN THE PREP DIGEST"
	else	
		echo "ADDED USER ${1} TO PREP DIGEST WITH NOK STATUS"
		echo "${1}:NOK" >> ${FILE} 
	fi
}


function notify {
	echo "There was a problem with $0 for user: $1 
	      ERROR MSG: $2	" \
	| mail -s "Mailbalance Alert" ${ADMIN}

}

function rolllog {
	LOGFILE="${PROGDIR}/log/${1}-maildirsync-`date +%Y%m`.log"
	if [ -f "${LOGFILE}" ] ; then
        	echo ''
	else
        	rm ${PROGDIR}/log/${1}-maildirsync*
	fi
}

#function setmode {
#	if [ "${1}"  = "-d" ] ; then
#		shift
#	        MODE=daemon;
#        	echo ${MODE}
#	else
#        	MODE=debug;
#        	echo ${MODE}
#fi
#}
