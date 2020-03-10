#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
fully automatic, incremental documents backup script for SMB shares, used for cron tasks
based on 7zip command line utility, with full backup plus diffs per each day
IMPORTANT NOTE: file permissions are NOT preserved, hence this script is not suitable
for backing permission sensitive apps, it's primary purpose is to have incremental backups on media files
such as documents, images etc.
after the backup archive creation, script purges backup files older than predefined keep interval
entire archive including files list is encrypted with password
optionally, if you want to be absolutely sure about remote backup integrity
you can enable VERIFY_REMOTE_SHA256SUM set to 1
in this mode sha256 control sum is calculated after archive creation and upload to share aling with backup file
WARNING, sha256 sum calculaton over remote can be slow due to big files and/or slow network,
entire file is piped in and checksummed, unfortunately unlike SSH, for SMB shares remote sha256 calculation can not be started locally on remote server
so we have to pull in and checksum entire file
how strategy for automatic backup works:
script first checks for full backup, dated later than DAYS_TO_KEEP_BACKUP
if there is none, makes full backup, then deletes files older than DAYS_TO_KEEP_BACKUP days
from local and remote share folders
if there is full backup present with date later than DAYS_TO_KEEP_BACKUP
then make diff backup
for resilience against network failures, script attempts to repeat listing, upload and
(optionally, if enabled) sha256 sum calculation attempts on network and/or credentials failure with gradually increasing backoff interval
as a precaution against accidental remote failure, after local and remote file deletion cleanup,
complete file recync is performed to ensure remote folder does contain all locally available backup files
end_header_info

workdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -o pipefail

#############settings#################
BACKUP_ARCHIVE_CREDENTIALS_FILE="$workdir/backup_archive_credentials" # file with encryption password for backup archives
BACKUP_FOLDER="$workdir/backup"           # absolute path to backup folder
SMB_CREDENTIALS_FILE="$workdir/smb_credentials" # file with smb share credentials
DAYS_TO_KEEP_BACKUP=10                  # how long keep backups
VERIFY_REMOTE_SHA256SUM=1               # WARNING, can be slow due to big files and/or slow network, entire file is piped in and checksummed
VERIFY_ONLY_UPLOADED_ON_THIS_RUN_FILES=1  # if set, checksum is calculated only only for files uploaded during this script run, others remote files only checked against filename and size, othervise, if checksumming is enabled, all remote files are checksummed
SYNC_ENTIRE_BACKUP_FOLDER_ON_EACH_RUN=1 # if enabled, the script will sync to remote share all local backup files on each script run, both newly created and old ones, not older than DAYS_TO_KEEP_BACKUP, otherwise only freshly created archive and sha256 sum are synched to remote, useful if you want to be sure no files have been omitted from copying under any circumstances
MAX_UPLOAD_ATTEMPTS=10                  # how many times try to upload before ceasing up and aborting the script
MAX_BACKOFF_DELAY_IN_SECONDS=1024       # max delay time before each upload attempt
EXCLUDES_LIST_FILENAME=exclude_list.txt # put here folders and files you want to exclude from backup
INCLUDES_LIST_FILENAME=include_list.txt # put here folders and files you want to include into backup
SMB_SHARE=//teremsn.local/homes           # put here host and share name, can be either IP address or host name
SMB_FOLDER=andrey/backup_notebook # remote folder on SMB share

#############functions#################
function check_and_install_packages() {
  if ! dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep "ok installed" &> /dev/null; then
    echo required  package $1 is missing, installing it
    if [[ $(whoami) != "root" ]]; then
     echo cannot install packages, must be root to install them
     exit 1
    fi
    apt-get -qq install "$1"
  fi
}

function one_run_copy() {
  lockfile=/var/lock/incremental_smb_backup_lock
  tmplockfile=${lockfile}.$$
  echo $$ >$tmplockfile
  if ln $tmplockfile $lockfile 2>&-; then
    true # we are locked
  else
    echo "locked by process id=$(<$lockfile) only one running copy of the incremental backup script is allowed"
    rm $tmplockfile
    exit
  fi
  trap 'rm ${tmplockfile} ${lockfile}' EXIT
}

function check_programs_presence() {
  for pr in which smbclient 7za sha256sum; do
    if ! which $pr >/dev/null; then
      echo "program $pr not reachable, please install packages via apt then run the script again"
      echo required packages are samba-client, p7zip-full, sha256sum
      exit 1
    fi
  done
}

function calculate_backoff_delay() {
  local delayInSeconds
  delayInSeconds=$(printf '%.0f' "$(bc -l <<< "(1/2)*(2^$1-1)")")
  if (( delayInSeconds > MAX_BACKOFF_DELAY_IN_SECONDS )); then
    echo "$MAX_BACKOFF_DELAY_IN_SECONDS"
  else
    echo "$delayInSeconds"
  fi
}

function sync_local_to_smb_share() {
  echo resync local folder contents to remote share, checking filename and file size
  local upload_attempts_counter=0
  local fname_local
  local fsize_local
  local fsize_remote
  local smb_ls_output
  local sleep_interval
  local remote_ls_successful
  local remote_size_eq_to_local
  local remote_sha256sum_eq_to_local
  local new_backup_file_uploaded
  local new_backup_file_sha256sum_uploaded
  local new_file_uploaded
  new_backup_file_uploaded=0
  new_backup_file_sha256sum_uploaded=0
  while read -r line_fname_local; do
    fname_local=${line_fname_local%|*} && fname_local=${fname_local// /\\ }
    fsize_local=${line_fname_local#*|}
    upload_attempts_counter=0
    new_file_uploaded=0
    while true; do
      remote_ls_successful=0
      remote_size_eq_to_local=0
      remote_sha256sum_eq_to_local=0
      if smb_ls_output=$(smbclient -A "${SMB_CREDENTIALS_FILE}" ${SMB_SHARE} --directory "${SMB_FOLDER}" -c "ls ${fname_local##*/}" 2>/dev/null); then
        while read -r line_ls_remote; do
          if [[ $line_ls_remote =~ ^.*(backup_data_[0-9]{4,4}-[0-9]{2,2}-[0-9]{2,2}-[0-9]{2,2}-[0-9]{2,2}-[0-9]{2,2}-(diff|full)\.7z(\.sha256sum)?)[[:space:]]+[A-Za-z][[:space:]]+([0-9]{1,100})[[:space:]]+([A-Za-z]{3,3}[[:space:]]+[A-Za-z]{3,3}[[:space:]]+[0-9]{1,2}[[:space:]]+[0-9]{1,2}\:[0-9]{2,2}\:[0-9]{2,2}[[:space:]]+[0-9]{4,4})[[:space:]]*$ ]]; then
            fsize_remote=${BASH_REMATCH[4]}
            remote_ls_successful=1
            if (( fsize_remote == fsize_local )); then
              remote_size_eq_to_local=1
            else
              echo "file $fname_local exists on remote share. but has diffirent size, will reupload it again"
            fi
            break
          fi
        done <<< "$smb_ls_output"
      else
        while read -r line_ls_remote; do
          if [[ $line_ls_remote =~ ^.*NT_STATUS_NO_SUCH_FILE.*$ ]]; then
            remote_ls_successful=1
            echo "remote file does not exists for local file $fname_local"
          else
            echo -e "error while accessing remote share:\n$smb_ls_output\n"
          fi
        done <<< "$smb_ls_output"
      fi
      if (( remote_ls_successful == 1 && remote_size_eq_to_local == 0)); then
        if smbclient -A "${SMB_CREDENTIALS_FILE}" ${SMB_SHARE} --directory ${SMB_FOLDER} -c "put ${fname_local##*/}" 2>/dev/null; then
          echo "file $fname_local uploaded succesfully"
          new_file_uploaded=1
        fi
      fi
      if ! [[ ${fname_local} == *".sha256sum" ]] && [[ -e "${fname_local}.sha256sum" ]] && (( VERIFY_REMOTE_SHA256SUM == 1 && remote_size_eq_to_local == 1 \
          && (( VERIFY_ONLY_UPLOADED_ON_THIS_RUN_FILES == 0 || ( VERIFY_ONLY_UPLOADED_ON_THIS_RUN_FILES == 1 && new_file_uploaded == 1 ) )) )); then

       sha256_local=$(cut -d ' ' -f 1 < "${fname_local}.sha256sum" )

        if sha256_remote=$(smbclient -A "${SMB_CREDENTIALS_FILE}" "${SMB_SHARE}" --directory "${SMB_FOLDER}" -c "get ${fname_local##*/} /dev/fd/1 " 2>/dev/null | pv -s "$fsize_remote" | sha256sum | cut -d ' ' -f 1); then
          if [[ "${sha256_remote}" == "${sha256_local}" ]]; then
            echo local sha256 sum is identical to remote file sum
            remote_sha256sum_eq_to_local=1
          else
            echo local sha256 sum differs from remote file sum
          fi
        else
          echo -e "error while checksumming file ${fname_local}:\n${sha256_remote}\n"
        fi
      fi
      if (( VERIFY_REMOTE_SHA256SUM == 1 &&  remote_sha256sum_eq_to_local == 1 )); then
        echo "file $fname_local has identical size and sha256 control sum compared to remote file"
        break
      elif (( remote_ls_successful == 1 && remote_size_eq_to_local == 1 )); then
        echo "file $fname_local exists on remote and has size identical to remote file"
        break
      fi
      if (( new_file_uploaded != 1 )); then
        if (( ++upload_attempts_counter > MAX_UPLOAD_ATTEMPTS )); then
          echo "exceeded max amount of retry attempts set to $MAX_UPLOAD_ATTEMPTS , aborting the execution"
          exit 1
        fi
        sleep_interval=$(calculate_backoff_delay $upload_attempts_counter)
        if (( remote_ls_successful != 1 )); then
          echo "failed to retrieve remote info for file $fname_local, repeating listing attempt in $sleep_interval seconds"
        else
          echo "error while uploading file $fname_local, repeating upload in $sleep_interval seconds"
        fi
        sleep "$sleep_interval"
      fi
    done
    if (( SYNC_ENTIRE_BACKUP_FOLDER_ON_EACH_RUN != 1 )); then
      if [[ $fname_local == *"${bfname_archive}.sha256sum" ]]; then
        new_backup_file_sha256sum_uploaded=1
      elif [[ $fname_local == *"${bfname_archive}" ]]; then
        new_backup_file_uploaded=1
      fi
      if (( new_backup_file_uploaded == 1 && new_backup_file_sha256sum_uploaded == 1 )); then
        break
      fi
    fi
  done <<< "$(find "$BACKUP_FOLDER" -maxdepth 1 -name "backup_data*" -type f -printf '%p|%s\n' | sort -r)"
}

####################main##########################

[[ ! -e "$BACKUP_FOLDER" ]] && mkdir -p "$BACKUP_FOLDER"

cd "$BACKUP_FOLDER" || exit 1

one_run_copy

check_and_install_packages pv
check_and_install_packages smbclient
check_and_install_packages p7zip-full

check_programs_presence

while read -r line_creds; do
  if [[ $line_creds =~ ^[[:space:]]*password[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
    archive_pass=${BASH_REMATCH[1]}
    break
  fi
done < "${BACKUP_ARCHIVE_CREDENTIALS_FILE}"

if [[ -z "$archive_pass" ]]; then
 echo "Could not get password from ${BACKUP_ARCHIVE_CREDENTIALS_FILE}, aborting"
 exit 1
fi

bfname_keep_timestamp=$(date +%Y%m%d%H%M%S --date="-${DAYS_TO_KEEP_BACKUP} day")
bfname_create_timestamp=$(date +%Y-%m-%d-%H-%M-%S)
for bfname in $(find "$BACKUP_FOLDER"/backup_data* 2>/dev/null | sort -r); do
  if [[ "$bfname" =~ ^.+/backup_data_([0-9]{4,4})-([0-9]{2,2})-([0-9]{2,2})-([0-9]{2,2})-([0-9]{2,2})-([0-9]{2,2})-(diff|full)\.7z$ ]]; then
    bfname_timestamp=${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}
    bfname_type=${BASH_REMATCH[7]}
    echo "$bfname_timestamp ==  $bfname_type"
    if (( bfname_timestamp > bfname_keep_timestamp )) && [[ "$bfname_type" == "full" ]]; then
      bfname_full_base=$bfname
      break
    fi
  fi
done
if [[ -z "$bfname_full_base" ]]; then
  echo "no full backup younger than $DAYS_TO_KEEP_BACKUP days found, make a new one"
  bfname_archive="backup_data_${bfname_create_timestamp}-full.7z"  
  if ! ( 7za a -bt -t7z -mx=7 -mhe=on -p"${archive_pass}" -xr-@"${workdir}/${EXCLUDES_LIST_FILENAME}" \
    -ir-@"${workdir}/${INCLUDES_LIST_FILENAME}" \
    "${BACKUP_FOLDER}/${bfname_archive}"); then
    echo error while creating 7zip backup archive, aborting script execution
    exit 1
  fi
else
  bfname_archive="backup_data_${bfname_create_timestamp}-diff.7z"
  echo "found full backup $bfname_full_base younger than $DAYS_TO_KEEP_BACKUP, creating diff archive using it as a base"
  
  if ! ( 7za u "${bfname_full_base}" -bt -t7z -mx=7 -mhe=on -p"${archive_pass}" -xr-@"${workdir}/${EXCLUDES_LIST_FILENAME}" \
    -ir-@"${workdir}/${INCLUDES_LIST_FILENAME}" -u- -up0q3r2x2y2z0w2!"${BACKUP_FOLDER}/${bfname_archive}"); then
    echo error while creating 7zip backup archive, aborting script execution
    exit 1
  fi
fi

if ! sha256sum -b "${bfname_archive}" > "${bfname_archive}.sha256sum"; then
  echo error while calculating control sum for 7zip backup archive, deleting archive and aborting execution
  rm "${bfname_archive}" "${bfname_archive}.sha256sum"
  exit 1
fi

for bfname in $(find "$BACKUP_FOLDER/backup_data*" 2>/dev/null | sort -r); do
  if [[ "$bfname" =~ ^.+/backup_data_([0-9]{4,4})-([0-9]{2,2})-([0-9]{2,2})-([0-9]{2,2})-([0-9]{2,2})-([0-9]{2,2})-(diff|full)\.7z$ ]]; then
    bfname_timestamp=${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}
    bfname_type=${BASH_REMATCH[7]}
    if (( bfname_timestamp < bfname_keep_timestamp )); then
      echo "found local backup archive $bfname older than $DAYS_TO_KEEP_BACKUP , deleting it locally and in smb share"
      rm "$bfname"
      smbclient -A "${SMB_CREDENTIALS_FILE}" ${SMB_SHARE} --directory ${SMB_FOLDER} -c "rm ${bfname##*/}"
    fi
  fi
done

sync_local_to_smb_share
