fully automatic, incremental documents backup script for SMB shares, used for cron tasks
based on 7zip command line utility, with full backup plus diffs per each day

**IMPORTANT NOTE** file permissions are NOT preserved, hence this script is not suitable 
for backing permission sensitive apps, it's primary purpose is to have incremental backups on media files
such as documents, images etc. 

After the backup archive creation, script purges backup files older than predefined keep interval
entire archive including files list is encrypted with password. Optionally, if you want to be absolutely sure about remote backup integrity, you can enable VERIFY_REMOTE_SHA256SUM set to 1. In this mode sha256 control sum is calculated after archive creation and upload to share aling with backup file

**WARNING** sha256 sum calculaton over remote can be slow due to big files and/or slow network,
entire file is piped in and checksummed, unfortunately unlike SSH, for SMB shares remote sha256 calculation can not be started locally on remote server, so we have to pull in and checksum entire file.

How strategy for automatic backup works:
script first checks for full backup archive, dated later than DAYS_TO_KEEP_BACKUP
If there is none, makes full backup, then deletes files older than DAYS_TO_KEEP_BACKUP days from local and remote share folders.
If there is full backup present with date later than DAYS_TO_KEEP_BACKUP
then make diff backup.
For resilience against network failures, script attempts to repeat listing, upload and 
(optionally, if enabled) sha256 sum calculation attempts on network and/or credentials failure with gradually increasing backoff interval.
As a precaution against accidental remote failure, after local and remote file deletion cleanup, 
complete file recync is performed to ensure remote folder does contain all locally available backup files
