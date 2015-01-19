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
if [[ -e $LAST_USED_RECORD_FILE_NAME ]]; then
	LAST_BACKUP_DATE=$(cat $LAST_USED_RECORD_FILE_NAME | tr '\n' ' ')
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

function getFileDiskUsage {
	FILE_SIZE_1KBLOCKS=$(du -s $1 | tr '\t' ';' | cut -d';' -f1)
	case $2 in
		"" )
			echo $FILE_SIZE_1KBLOCKS
			return 0
			;;
		"M") ## return in Megabites
			echo $(python -c "print '%d M' % (${FILE_SIZE_1KBLOCKS}/1024.0)")
			return 0
			;;
		"G") ## return in Giga
			echo $(python -c "print '%d G' % (${FILE_SIZE_1KBLOCKS}/1024/1024.0)")
			return 0
			;;
		"b") ## return in bytes
			echo $(python -c "print '%d' % (${FILE_SIZE_1KBLOCKS}*1024.0)")
			return 0
			;;
	esac
}
function getMountSpaceFree {
	MOUNT_FREE_1KBLOCKS=$(df --output=avail $1 | tr '\n' ';' | cut -d';' -f2)
	case $2 in
		"" )
			echo $MOUNT_FREE_1KBLOCKS
			return 0
			;;
		"M") ## return in Megabites
			echo $(python -c "print '%f M' % (${MOUNT_FREE_1KBLOCKS}/1024.0)")
			return 0
			;;
		"G") ## return in Giga
			echo $(python -c "print '%f G' % (${MOUNT_FREE_1KBLOCKS}/1024/1024.0)")
			return 0
			;;
		"b") ## return in bytes
			echo $(python -c "print '%d' % (${MOUNT_FREE_1KBLOCKS}*1024.0)")
			return 0
			;;
	esac
}


# Log the scrypt start at syslog
logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_INFO} "${backup_name}:${timesatmp}:${backup_source}:${backup_destination}:${compressor}:${recepient_email}"

## Several pre checks to be made

# Ceck the source
if [[ ! ( -e $BACKUP_SOURCE && -d  $BACKUP_SOURCE && -r $BACKUP_SOURCE ) ]]; then
	if [[ ! -e $BACKUP_SOURCE ]]; then
		logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_source} is non existant."
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_SOURCE} is non existant!"
	elif [[ ! -d  $BACKUP_SOURCE ]]; then
		logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_source} is not a directory!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_SOURCE} is not a directory!"
	elif [[ ! -r $BACKUP_SOURCE ]]; then
		logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_source} is not readable!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_SOURCE} is not readable!"
	fi
	exit 1
fi
# Check the Destination
if [[ ! ( -e $BACKUP_DESTINATION && -d  $BACKUP_DESTINATION && -w $BACKUP_DESTINATION ) ]]; then
	if [[ ! -e $BACKUP_DESTINATION ]]; then
		logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_destination} is non existant."
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is non existant!"
	elif [[ ! -d  $BACKUP_DESTINATION ]]; then
		logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_destination} is not a directory!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is not a directory!"
	elif [[ ! -w $BACKUP_DESTINATION ]]; then
		logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_destination} is not writeable!"
		echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is not writeable!"
	fi
	exit 1
fi

# check source size
BACKUP_SOURCE_SIZE=$(getFileDiskUsage $BACKUP_SOURCE)		# get Size of source in bytes
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
BACKUP_DESTINATION_FREE_START=$(getMountSpaceFree $BACKUP_DESTINATION)
if [[ $(( $BACKUP_DESTINATION_FREE_START - $BACKUP_SOURCE_SIZE)) -lt $(( 100 * 1024 )) ]]; then
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_destination} full!"
	echo -e "\e[41mERROR:\e[49m\e[31m  ${BACKUP_DESTINATION} is FULL!\e[0m There is$(getMountSpaceFree $BACKUP_DESTINATION G) G free, but ${BACKUP_SOURCE} is $(getFileDiskUsage $BACKUP_SOURCE G) G"
	exit 1
fi

#####################################################################
##### Compress
#####################################################################
 
TAR_FILE_NAME="${BACKUP_NAME}-${TIMESATMP}.tar.${COMPRESSOR}"
echo -e "\e[32mCompression starts:\e[0m ${BACKUP_SOURCE} is beeing tared with ${COMPRESSOR} to ${BACKUP_DESTINATION}${TAR_FILE_NAME}"	
TAR_TIME_START=$(date +%s)
tar ${TAR_OPTIONS} -cf ${BACKUP_DESTINATION}${TAR_FILE_NAME} ${BACKUP_SOURCE} &>$TAR_PACK_LOG_FILE
TAR_EXIT_CODE=$?
TAR_TIME_FINISHED=$(date +%s)
TAR_TIME_HUMAN=$(calculateTimeUsed $TAR_TIME_START $TAR_TIME_FINISHED "human")
TAR_TIME_LOG=$(calculateTimeUsed $TAR_TIME_START $TAR_TIME_FINISHED "log")
if [[ ! $TAR_EXIT_CODE -eq 0 ]]; then
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "tar compression failed with ${tar_exit_code}. time taken: ${tar_time_log}"
	echo -e "\e[41mERROR:\e[49m\e[31m  Something went wrong with compression of ${TAR_FILE_NAME}. Time: ${TAR_TIME_HUMAN} ExitCode: ${TAR_EXIT_CODE}\e[0m"
	exit 1
else
	if [[ ! -d logs ]]; then # Checking for the log file dir 
		mkdir logs
	fi
	# pack the log file
	tar -cjf $TAR_PACK_LOG_FILE_PACKED $TAR_PACK_LOG_FILE
	rm $TAR_PACK_LOG_FILE # clean the uncompressed log
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_INFO} "tar compression successfull. time taken: ${tar_time_log}"
	echo -e "\e[32mCompression finished:\e[0m Compressing the file ${TAR_FILE_NAME} took: ${TAR_TIME_HUMAN}."
fi
# Remember Backup Time, right after Tar is finished.
WHOLE_SCRIPT_TIME_START_ISO8601=$(date +%FT%T%z)
echo $WHOLE_SCRIPT_TIME_START_ISO8601 > $LAST_USED_RECORD_FILE_NAME

#####################################################################
##### Encrypt 
#####################################################################
TAR_FILE_SIZE=$(getFileDiskUsage ${BACKUP_DESTINATION}${TAR_FILE_NAME})
BACKUP_DESTINATION_FREE=$(getMountSpaceFree $BACKUP_DESTINATION)
if [[ $(($BACKUP_DESTINATION_FREE - $TAR_FILE_SIZE)) -lt $(( 100 * 1024 )) ]]; then
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${BACKUP_DESTINATION} full! not enough room for gpg-file"
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
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "gpg encryption failed with ${gpg_exit_code}. time taken: ${gpg_time_log}"
	echo -e "\e[41mERROR:\e[49m\e[31m  Something went wrong encrypting ${GPG_FILE_NAME}. Time: ${GPG_TIME_HUMAN} ExitCode: ${GPG_EXIT_CODE}\e[0m"
	exit 1
else
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_INFO} "tar compression successfull. time taken: ${gpg_time_log}"
	echo -e "\e[32mEncryption finished:\e[0m Encrypting the file ${GPG_FILE_NAME} took: ${GPG_TIME_HUMAN}."
fi
#####################################################################
##### Create PAR2
#####################################################################
PAR2_FILE_SIZE_CALC_STRING="print '%d' % (${TAR_FILE_SIZE}*0.${PAR2_REDUNDANCY})"
PAR2_FILE_SIZE=$(python -c "${PAR2_FILE_SIZE_CALC_STRING}")
BACKUP_DESTINATION_FREE=$(getMountSpaceFree $BACKUP_DESTINATION)
PAR2_FILE_SIZE_ROOM=$(python -c "print '%d' % (${BACKUP_DESTINATION_FREE}-${PAR2_FILE_SIZE})")
if [[ $PAR2_FILE_SIZE_ROOM -lt $(( 100 * 1024 )) ]]; then
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "${backup_destination} full! not enough room for par2-volumes"
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
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_WARNING} "par2 creation quit with ${par2_exit_code}. time taken: ${par2_time_log}"
	echo -e "\e[41mERROR:\e[49m\e[31m  Something went wrong trying to create ${GPG_FILE_NAME}.par2. Time: ${PAR2_TIME_HUMAN} ExitCode: ${PAR2_EXIT_CODE}\e[0m"
	exit 1
else
	logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_INFO} "par2 creation successfull. time taken: ${par2_time_log}"
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
	GDRIVE_GPG_JSON='
{			
	"Name" : "'$GPG_FILE_NAME'",
	"Type" : "Google Drive File",
	"Title" 	  : "'$GPG_FILE_NAME'",
	"Id" 		  : "'$GPG_FILE_UPLOAD_ID'",
	"Uploaded At" : "'$(date --iso-8601='seconds')'",
	"Mime-Type" : "application/pgp-encrypted",
	"Size" : '$(getFileDiskUsage ${BACKUP_DESTINATION}${GPG_FILE_NAME} b)',
	"GnuPG":{
		"Key ID" : "'$RECEPIENT_EMAIL'",
		"GnuPG Options" : "'$GPG_OPTIONS'"
		"Process Time" :
		{
			"Start"   : "'$(date +%FT%T%z --date="@${GPG_TIME_START}")'",
			"End" 	  : "'$(date +%FT%T%z --date="@${GPG_TIME_FINISHED}")'",
			"Elapsed" : "'$(($GPG_TIME_FINISHED - $GPG_TIME_START))'"
		}
	}
		
}'
	echo -e "\e[32mUploaded successfully:\e[0m $GPG_FILE_NAME has Id: $GPG_FILE_UPLOAD_ID"
else
	echo "error"
	exit 1
fi
NOW_PWD=$PWD
PAR2_FILE_S=$(cd ${BACKUP_DESTINATION} && echo $GPG_FILE_NAME.*par2)
cd $NOW_PWD
for PAR2_FILE in $PAR2_FILE_S; do
	PAR_FILE_UPLOAD_ID=$(uploadFile $GDRIVE_FOLDER_ID ${BACKUP_DESTINATION}$PAR2_FILE)
	if [[ $? -eq 0 ]]; then
		PAR2_FILE_S_GDRIVE_JSON="${PAR2_FILE_S_GDRIVE_JSON},"'
{
	"Name" : "'$PAR2_FILE'",
	"Title" : "'$PAR2_FILE'",
	"Id" : "'$PAR_FILE_UPLOAD_ID'",
	"Type" : "Google Drive File",
	"Mime-Type" : "application/x-par2",
	"Uploaded At" : "'$(date +%FT%T%z)'",
	"Size" : '$(getFileDiskUsage ${BACKUP_DESTINATION}${PAR2_FILE} b)'
}'
		echo -e "\e[32mUploaded successfully:\e[0m $PAR2_FILE has Id: $PAR_FILE_UPLOAD_ID"
	else
		echo "error"
		exit 1
	fi
done


WHOLE_SCRIPT_TIME_FINISHED=$(date +%s)
WHOLE_SCRIPT_TIME_HUMAN=$(calculateTimeUsed $WHOLE_SCRIPT_TIME_START $WHOLE_SCRIPT_TIME_FINISHED "human")
WHOLE_SCRIPT_TIME_LOG=$(calculateTimeUsed $WHOLE_SCRIPT_TIME_START $WHOLE_SCRIPT_TIME_FINISHED "log")
BACKUP_JSON_RECORD='
{
	"Backup":{
		"Name" : "'$BACKUP_NAME'",
		"Host" : {
			"Source Directory" :
				{
					"Path" : "'$BACKUP_SOURCE'",
					"Size" : "'$(getFileDiskUsage ${BACKUP_SOURCE} b)'"
				},
			"Destination Directory" :
			{
				"Path" : "'$BACKUP_DESTINATION'",
				"Free" :
				{
					"Start" : "'$(( $BACKUP_DESTINATION_FREE_START * 1024))'",
					"End" 	: "'$(getMountSpaceFree $BACKUP_DESTINATION b)'"
				}
			},
			"Hostname":"'$(hostname -f)'",
			"OS":"'$(uname -a)'"
		},
		"Time" :
		{
			"Start"   : "'$WHOLE_SCRIPT_TIME_START_ISO8601'",
			"End"     : "'$(date +%FT%T%z --date="@${WHOLE_SCRIPT_TIME_FINISHED}")'",
			"Elapsed" : "'$(($WHOLE_SCRIPT_TIME_FINISHED - $WHOLE_SCRIPT_TIME_START))'",
			"Previous":"'$LAST_BACKUP_DATE'"
		},
		"Files"	:
			[
				{
					"Name" : "'$TAR_FILE_NAME'",
					"Path" : "'$BACKUP_DESTINATION'",
					"Type" : "Tar Archive",
					"Mime-Type" : "application/x-tar",
					"Size" : '$(( ${TAR_FILE_SIZE} * 1024 ))',
					"Tar":
					{
						"Tar Options": "'$TAR_OPTIONS'",
						"Process Time" :
						{
							"Start"   : "'$(date +%FT%T%z --date="@$TAR_TIME_START")'",
							"End" 	  : "'$(date +%FT%T%z --date="@$TAR_TIME_FINISHED")'",
							"Elapsed" : "'$(($TAR_TIME_FINISHED - $TAR_TIME_START))'"
						},
						"Log" : "'$TAR_PACK_LOG_FILE_PACKED'",
						"Compressor":"'$COMPRESSOR'",
						"Exclude Paterns" : "'$([[ -f $EXCLUDE_FILE ]] && cat $EXCLUDE_FILE | tr "\\n" ",")'"
					} 
				}
				,
				{
					"Title" : "'$GOOGLE_DRIVE_PARENT_FOLDER_TITLE'",
					"Type" : "Google Drive Folder",
					"Id" :	"'$GOOGLE_DRIVE_PARENT_FOLDER_ID'",
					"Childs" :
					[
						{
							"Title" : "'$TIMESATMP'",
							"Type" : "Google Drive Folder",
							"Id" :	"'$GDRIVE_FOLDER_ID'",
							"Childs" :
								[
									
									'$GDRIVE_GPG_JSON'
									
									'$PAR2_FILE_S_GDRIVE_JSON'
									
								]
						}
					]
				}
			]
	} 
		
		
}'
if [[ -f $JSON_BACKUP_RECORDS_DUMP ]]; then
	echo "," >> $JSON_BACKUP_RECORDS_DUMP
fi
echo $BACKUP_JSON_RECORD >> $JSON_BACKUP_RECORDS_DUMP
logger ${LOGGER_OPTIONS}${LOGGER_SEVERITY_INFO} "backup successfull. time taken: ${whole_script_time_log}"
echo -e "\e[32mBackup finished:\e[0m The whole process took ${HOURS} h ${MINUTES} m ${SECONDS} s to be completed."
exit 0
