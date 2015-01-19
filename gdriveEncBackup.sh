#!/bin/bash
######################################################################
#  Backup Script with Encryption													
#																					
#  Compresses with tar and algo of choice, encrypts with 							
#  GnuPG public Key, shreds the tar, creates par2 volumes 							
#  then uploads to Google drive.													
#  The tar will contain only the files newer than last backup.						
#																					
#  Tested on Ubuntu Thrusty													
#		
#  Needs:																		
#  GnuPG (with a trused PubKey in the Keyring)									
#  par2 (http://parchive.sourceforge.net/)										
#  gdrive (https://github.com/prasmussen/gdrive)								
#  GoogleDrive 																
#																					
#  usage:																		
#  gdriveEncBackup.sh [Source] [Destination] [Name] [Email] [DriveParent]
#  
#	all parameters are optional, set the config in gdriveEncBackup.sh.conf 

# Check and Get the config file
if [[ ! -f gdriveEncBackup.sh.conf ]]; then
	echo -e "\e[41mERROR:\e[49m\e[31m The configurations from gdriveEncBackup.sh.conf are missing!"
	exit 1
else
	source gdriveEncBackup.sh.conf
fi

######################################################################
#	Setting opts from parameters
######################################################################
if [[ ! $1 = ""  ]]; then
	BACKUP_SOURCE=$1
fi
if [[ ! $2 = ""  ]]; then
	BACKUP_DESTINATION=$2
fi
if [[ ! $3 = ""  ]]; then
	BACKUP_NAME=$3
fi
if [[ ! $4 = ""  ]]; then
	RECEPIENT_EMAIL=$4
fi
if [[ ! $5 = ""  ]]; then
	GOOGLE_DRIVE_PARENT_FOLDER_ID=$5
fi
if [[ ! $6 = ""  ]]; then
	COMPRESSOR=$6
fi
######################################################################
#	Several Variable Checks
######################################################################

# Check if incremental
if [[ -e gdriveEncBackup.sh.last ]]; then
	LAST_BACKUP_DATE=$(cat gdriveEncBackup.sh.last | tr '\n' ' ')
fi
# if incremental, set the tar --newer option
if [[ ! $LAST_BACKUP_DATE = "" ]]; then
	NEWER="--newer $LAST_BACKUP_DATE"
fi
TAR_OPTIONS_OPTIONAL=""
# Check if Exclude file for Tar is set
if [[ ! $EXCLUDE_FILE = "" ]]; then
	if [[ ! -e $EXCLUDE_FILE ]]; then
		touch $EXCLUDE_FILE
	fi
	TAR_OPTIONS_OPTIONAL="${TAR_OPTIONS_OPTIONAL} -X $EXCLUDE_FILE "
fi
# Exclude backup files
if [[ $EXCLUDE_FILE_BACKUP = "true" ]]; then
	TAR_OPTIONS_OPTIONAL="${TAR_OPTIONS_OPTIONAL} --exclude-backups"
fi
# exclude cache dirs
if [[ $EXCLUDE_CACHE_DIRS = "true" ]]; then
	TAR_OPTIONS_OPTIONAL="${TAR_OPTIONS_OPTIONAL} --exclude-caches"
fi
# exclude --exclude-vcs
if [[ $EXCLUDE_VCS = "true" ]]; then
	TAR_OPTIONS_OPTIONAL="${TAR_OPTIONS_OPTIONAL} --exclude-vcs"
fi
# Make $COMPRESSOR setting optonal with bzip2 as default
if [[ $COMPRESSOR = "" ]]; then
	COMPRESSOR="xz"
fi
# Make $BASE_DIR optional with defaule to /
if [[ $BASE_DIR = "" ]]; then
	TAR_OPTIONS_OPTIONAL="${TAR_OPTIONS_OPTIONAL} -C /"
fi
# $PAR2_REDUNDANCY is optional
if [[ $PAR2_REDUNDANCY = "" ]]; then
	PAR2_REDUNDANCY="30"
fi


#####################################################################
###  Program options Strins
#####################################################################
TAR_OPTIONS="--acls --xattrs -pv ${TAR_OPTIONS_OPTIONAL} --${COMPRESSOR} ${NEWER}" 
GPG_OPTIONS="-q --batch --yes -q --compress-algo none"
PAR2_OPTIONS="-r${PAR2_REDUNDANCY} -qq"



WHOLE_SCRIPT_TIME_START=$(date +%s)	  # Record Script Start Time
TIMESATMP=$(date +%Y-%m-%d)

#####################################################################
###  FUNCTIONS
#####################################################################

## GoogleDrive Folder creator
# uses https://github.com/prasmussen/gdriv
function createDriveFolder() {
	DRIVE_FOLDER_NAME=$1
	DRIVE_FOLDER_CREATE_REPLY=$(drive folder -p $2 -t ${DRIVE_FOLDER_NAME})
	
	DRIVE_FOLDER_ID=$(echo $DRIVE_FOLDER_CREATE_REPLY | grep -Po "(?<=Id: ).*(?= Title\:)")
	if [[ $? -eq 0 ]]; then
		echo $DRIVE_FOLDER_ID
		return 0
	else
		echo "something went wrong with uploading"
		echo $DRIVE_FOLDER_CREATE_REPLY
	fi 
}
## GoogleDrive File uploader
# uses https://github.com/prasmussen/gdrive
function uploadFile() {
	PARENT_ID=$1
	FILE_PATH=$2
	DRIVE_UPLOAD_REPLY=$(drive upload -p $PARENT_ID -f $FILE_PATH)
	if [[ $? -eq 0 ]]; then
		echo $(echo $DRIVE_UPLOAD_REPLY | grep -Po "(?<=Id: ).*(?= Title\:)")
		return 0
	elif [[ $? -eq 1 ]]; then
		echo "Something went wrong"
		echo $DRIVE_UPLOAD_REPLY
		return 1
	fi
}

## Calculate Time Used function
#  usage: calculateTimeUsed() $STARTTIME $ENDTIME [$FORMAT{human,log,filename}]
function calculateTimeUsed {
	TIME_START=$1
	TIME_FINISHED=$2
	if [[ ( $1 = "" || $2 = "") ]]; then   # Wrong usage, no parameters.
		return 1
	fi
	TIME_FINISHED_WHOLE_SCRIPT=$(date +%s)
	TIME_USED=$(($TIME_FINISHED - $TIME_START))
	HOURS=$(($TIME_USED / 60 / 60))
	HOURS_SECONDS=$(($HOURS * 60 * 60))
	MINUTES_NOHOURS=$(($TIME_USED - $HOURS_SECONDS))
	MINUTES=$(($MINUTES_NOHOURS / 60))
	MINUTES_SECONDS=$(($MINUTES * 60))
	SECONDS=$(($MINUTES_NOHOURS - $MINUTES_SECONDS))
	case $3 in
		"" )
			echo "${HOURS}${MINUTES}${SECONDS}"
			return
			;;
		"human" )
			echo "${HOURS} h ${MINUTES} m ${SECONDS} s"
			return
			;;
		"log" )
			echo "${HOURS}:${MINUTES}:${SECONDS}"
			return
			;;
		"filename" )
			echo "${HOURS}-${MINUTES}-${SECONDS}"
			return
			;;
	esac
	echo -e "\e[41mERROR:\e[49m\e[31m Your format option was wrong. Either: human, log or filename."
	return 1  # if none of the cases is true, something was wrong with $3
}


# Log the scrypt start at syslog
logger -t EncTarBak -p local0.info "${BACKUP_NAME}:${TIMESATMP}:${BACKUP_SOURCE}:${BACKUP_DESTINATION}:${COMPRESSOR}:${RECEPIENT_EMAIL}"

## Several pre checks to be made

# Ceck the source
if [[ ! ( -e $BACKUP_SOURCE && -d  $BACKUP_SOURCE && -r $BACKUP_SOURCE ) ]]; then
	if [[ ! -e $BACKUP_SOURCE ]]; then
		logger -t EncTarBak -p local0.warning "${BACKUP_SOURCE} is non existant."
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_SOURCE} is non existant!"
	elif [[ ! -d  $BACKUP_SOURCE ]]; then
		logger -t EncTarBak -p local0.warning "${BACKUP_SOURCE} is not a directory!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_SOURCE} is not a directory!"
	elif [[ ! -r $BACKUP_SOURCE ]]; then
		logger -t EncTarBak -p local0.warning "${BACKUP_SOURCE} is not readable!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_SOURCE} is not readable!"
	fi
	exit 1
fi
# Check the Destination
if [[ ! ( -e $BACKUP_DESTINATION && -d  $BACKUP_DESTINATION && -w $BACKUP_DESTINATION ) ]]; then
	if [[ ! -e $BACKUP_DESTINATION ]]; then
		logger -t EncTarBak -p local0.warning "${BACKUP_DESTINATION} is non existant."
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is non existant!"
	elif [[ ! -d  $BACKUP_DESTINATION ]]; then
		logger -t EncTarBak -p local0.warning "${BACKUP_DESTINATION} is not a directory!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is not a directory!"
	elif [[ ! -w $BACKUP_DESTINATION ]]; then
		logger -t EncTarBak -p local0.warning "${BACKUP_DESTINATION} is not writeable!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is not writeable!"
	fi
	exit 1
fi

# check source size
BACKUP_SOURCE_SIZE=$(du -s $BACKUP_SOURCE | tr '\t' ';' | cut -d';' -f1)		# get Size of source in bytes
# check if enought room on destination's/\/dev\/[a-zA-Z0-9_\-]*\/\([a-zA-Z0-9_\-]*\)/\1/')
BACKUP_DESTINATION_DIRS=$(echo "${BACKUP_DESTINATION}" | tr '/' ' ')
for i in $BACKUP_DESTINATION_DIRS; do
	grep -qs "$BACKUP_DESTINATION_MOUNT/$i" /proc/mounts
	if [[ $? -eq 0 ]]; then
		BACKUP_DESTINATION_MOUNT="${BACKUP_DESTINATION_MOUNT}/${i}"
	fi
done
if [[ $BACKUP_DESTINATION_MOUNT = "" ]]; then
	BACKUP_DESTINATION_MOUNT=" / "
fi
BACKUP_DESTINATION_FREE=$(df --output=avail /mnt/backup-one/ | tr '\n' ';' | cut -d';' -f2)
if [[ $(( $BACKUP_DESTINATION_FREE - $BACKUP_SOURCE_SIZE)) -lt $(( 100 * 1024 )) ]]; then
	logger -t EncTarBak -p local0.warning "${BACKUP_DESTINATION} full!"
	echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is FULL!\e[0m There is$(df -h --output=avail /mnt/backup-one/ | tr '\n' ';' | cut -d';' -f2) free, but ${BACKUP_SOURCE} is $(( $BACKUP_SOURCE_SIZE / 1024 )) M"
	exit 1
fi

#####################################################################
##### Compress
#####################################################################
 
TAR_FILE_NAME="${BACKUP_NAME}-${TIMESATMP}.tar.${COMPRESSOR}"
echo -e "\e[32mCompression starts:\e[0m ${BACKUP_SOURCE} is beeing tared with ${COMPRESSOR} to ${BACKUP_DESTINATION}${TAR_FILE_NAME}"	
TAR_TIME_START=$(date +%s)
tar ${TAR_OPTIONS} -cf ${BACKUP_DESTINATION}${TAR_FILE_NAME} ${BACKUP_SOURCE} &>"${BACKUP_NAME}-${TIMESATMP}.log"
TAR_EXIT_CODE=$?
TAR_TIME_FINISHED=$(date +%s)
TAR_TIME_HUMAN=$(calculateTimeUsed $TAR_TIME_START $TAR_TIME_FINISHED "human")
TAR_TIME_LOG=$(calculateTimeUsed $TAR_TIME_START $TAR_TIME_FINISHED "log")
if [[ ! $TAR_EXIT_CODE -eq 0 ]]; then
	logger -t EncTarBak -p local0.warning "tar compression failed with ${TAR_EXIT_CODE}. Time taken: ${TAR_TIME_LOG}"
	echo -e "\e[41mERROR:\e[49m\e[31m  Something went wrong with compression of ${TAR_FILE_NAME}. Time: ${TAR_TIME_HUMAN} ExitCode: ${TAR_EXIT_CODE}\e[0m"
	exit 1
else
	if [[ ! -d logs ]]; then # Checking for the log file dir 
		mkdir logs
	fi
	# pack the log file
	tar -cjf "logs/${BACKUP_NAME}-${TIMESATMP}.log.tar.bz2" "${BACKUP_NAME}-${TIMESATMP}.log"
	rm "${BACKUP_NAME}-${TIMESATMP}.log" # clean the uncompressed log
	logger -t EncTarBak -p local0.info "tar compression successfull. Time taken: ${TAR_TIME_LOG}"
	echo -e "\e[32mCompression finished:\e[0m Compressing the file ${TAR_FILE_NAME} took: ${TAR_TIME_HUMAN}."
fi


#####################################################################
##### Encrypt 
#####################################################################
TAR_FILE_SIZE=$(du -s ${BACKUP_DESTINATION}${TAR_FILE_NAME} | tr '\t' ';' | cut -d';' -f1)
BACKUP_DESTINATION_FREE=$(df --output=avail /mnt/backup-one/ | tr '\n' ';' | cut -d';' -f2)
if [[ $(($BACKUP_DESTINATION_FREE - $TAR_FILE_SIZE)) -lt $(( 100 * 1024 )) ]]; then
	logger -t EncTarBak -p local0.warning "${BACKUP_DESTINATION} full! Not enough room for GPG-file"
	echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is FULL!\e[0m There is$(df -h --output=avail /mnt/backup-one/ | tr '\n' ';' | cut -d';' -f2) free, but ${TAR_FILE_NAME} is $(( $TAR_FILE_SIZE / 1024 )) M. Cannot encrypt ${TAR_FILE_NAME}."
	exit 1
fi

GPG_FILE_NAME="${TAR_FILE_NAME}.gpg"
echo -e "\e[32mEncryption starts:\e[0m ${TAR_FILE_NAME} is beeing gpged to ${BACKUP_DESTINATION}${GPG_FILE_NAME}"	
GPG_TIME_START=$(date +%s)
gpg --output ${BACKUP_DESTINATION}${GPG_FILE_NAME} --recipient ${RECEPIENT_EMAIL} $GPG_OPTIONS --encrypt ${BACKUP_DESTINATION}$TAR_FILE_NAME
GPG_EXIT_CODE=$?
GPG_TIME_FINISHED=$(date +%s)
GPG_TIME_HUMAN=$(calculateTimeUsed $GPG_TIME_START $GPG_TIME_FINISHED "human")
GPG_TIME_LOG=$(calculateTimeUsed $GPG_TIME_START $GPG_TIME_FINISHED "log")
if [[ ! $GPG_EXIT_CODE -eq 0 ]]; then
	logger -t EncTarBak -p local0.warning "gpg encryption failed with ${GPG_EXIT_CODE}. Time taken: ${GPG_TIME_LOG}"
	echo -e "\e[41mERROR:\e[49m\e[31m  Something went wrong encrypting ${GPG_FILE_NAME}. Time: ${GPG_TIME_HUMAN} ExitCode: ${GPG_EXIT_CODE}\e[0m"
	exit 1
else
	logger -t EncTarBak -p local0.info "tar compression successfull. Time taken: ${GPG_TIME_LOG}"
	echo -e "\e[32mEncryption finished:\e[0m Encrypting the file ${GPG_FILE_NAME} took: ${GPG_TIME_HUMAN}."
fi
#####################################################################
##### Create PAR2
#####################################################################
PAR2_FILE_SIZE_CALC_STRING="print '%d' % (${TAR_FILE_SIZE}*0.${PAR2_REDUNDANCY})"
PAR2_FILE_SIZE=$(python -c "${PAR2_FILE_SIZE_CALC_STRING}")
BACKUP_DESTINATION_FREE=$(df --output=avail /mnt/backup-one/ | tr '\n' ';' | cut -d';' -f2)
PAR2_FILE_SIZE_ROOM=$(python -c "print '%d' % (${BACKUP_DESTINATION_FREE}-${PAR2_FILE_SIZE})")
if [[ $PAR2_FILE_SIZE_ROOM -lt $(( 100 * 1024 )) ]]; then
	logger -t EncTarBak -p local0.warning "${BACKUP_DESTINATION} full! Not enough room for PAR2-Volumes"
	echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is FULL!\e[0m There is$(df -h --output=avail /mnt/backup-one/ | tr '\n' ';' | cut -d';' -f2) free, but the PAR2-Volumes would take $(( $PAR2_FILE_SIZE / 1024 )) M. Cannot create PAR2-Volumes for ${GPG_FILE_NAME}."
	exit 1
fi
echo -e "\e[32mPAR2-Set creation starts:\e[0m ${GPG_FILE_NAME} is beeing PAR2ed to ${BACKUP_DESTINATION}${GPG_FILE_NAME}.par2"	
PAR2_TIME_START=$(date +%s)
par2create $PAR2_OPTIONS ${BACKUP_DESTINATION}$GPG_FILE_NAME
PAR2_EXIT_CODE=$?
PAR2_TIME_FINISHED=$(date +%s)
PAR2_TIME_HUMAN=$(calculateTimeUsed $PAR2_TIME_START $PAR2_TIME_FINISHED "human")
PAR2_TIME_LOG=$(calculateTimeUsed $PAR2_TIME_START $PAR2_TIME_FINISHED "log")
if [[ ! $PAR2_EXIT_CODE -eq 0 ]]; then
	logger -t EncTarBak -p local0.warning "par2 creation quit with ${PAR2_EXIT_CODE}. Time taken: ${PAR2_TIME_LOG}"
	echo -e "\e[41mERROR:\e[49m\e[31m  Something went wrong trying to create ${GPG_FILE_NAME}.par2. Time: ${PAR2_TIME_HUMAN} ExitCode: ${PAR2_EXIT_CODE}\e[0m"
	exit 1
else
	logger -t EncTarBak -p local0.info "PAR2 creation successfull. Time taken: ${PAR2_TIME_LOG}"
	echo -e "\e[32mPAR2 creation finished:\e[0m PAR2 the file ${GPG_FILE_NAME} took: ${PAR2_TIME_HUMAN}."
fi
shred -u ${BACKUP_DESTINATION}$TAR_FILE_NAME

#####################################################################
##   UPload files to Google Drive
#####################################################################
GDRIVE_FOLDER_ID=$(createDriveFolder $TIMESATMP $GOOGLE_DRIVE_PARENT_FOLDER_ID)
if [[ $? -eq 0 ]]; then
	echo -e "\e[32mGoole Drive folder created:\e[0m Name $TIMESATMP, Id: $GDRIVE_FOLDER_ID"
else
	echo "error"
	exit 1
fi
GPG_FILE_UPLOAD_ID=$(uploadFile $GDRIVE_FOLDER_ID ${BACKUP_DESTINATION}$GPG_FILE_NAME)
if [[ $? -eq 0 ]]; then
	echo -e "\e[32mUploaded successfully:\e[0m $GPG_FILE_NAME has Id: $GPG_FILE_UPLOAD_ID"
else
	echo "error"
	exit 1
fi
PAR2_FILE_S=${BACKUP_DESTINATION}$GPG_FILE_NAME.*par2
for PAR2_FILE in $PAR2_FILE_S; do
	PAR_FILE_UPLOAD_ID=$(uploadFile $GDRIVE_FOLDER_ID $PAR2_FILE)
	if [[ $? -eq 0 ]]; then
		echo -e "\e[32mUploaded successfully:\e[0m $PAR2_FILE has Id: $PAR_FILE_UPLOAD_ID"
	else
		echo "error"
		exit 1
	fi
done
# Log the action taken to a CSV database
echo "${BACKUP_NAME};${TIMESATMP};${BACKUP_SOURCE};${BACKUP_DESTINATION};${COMPRESSOR};${RECEPIENT_EMAIL}" >> gdriveEncBackup.sh.uses.csv
# Time save for next backup
echo $(date +%y%m%d) > gdriveEncBackup.sh.last
WHOLE_SCRIPT_TIME_FINISHED=$(date +%s)
WHOLE_SCRIPT_TIME_HUMAN=$(calculateTimeUsed $WHOLE_SCRIPT_TIME_START $WHOLE_SCRIPT_TIME_FINISHED "human")
WHOLE_SCRIPT_TIME_LOG=$(calculateTimeUsed $WHOLE_SCRIPT_TIME_START $WHOLE_SCRIPT_TIME_FINISHED "log")
logger -t EncTarBak -p local0.info "Backup successfull. Time taken: ${WHOLE_SCRIPT_TIME_LOG}"
echo -e "\e[32mBackup finished:\e[0m The whole process took ${HOURS} h ${MINUTES} m ${SECONDS} s to be completed."
exit 0
