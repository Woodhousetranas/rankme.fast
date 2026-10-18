#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Prepare','Preflight','TestGuard','Run','Status','RestoreExisting')][string]$Mode='Prepare',[string]$StateFile,[string]$LiveSource,[string]$BackupStateFile,[string]$ApplicationUuid,[switch]$HoldForCutover,[string]$DataRoot=(Join-Path $env:USERPROFILE '.coolify'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'private-files.ps1')
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if($HoldForCutover -and $Mode -ne 'Run'){throw 'An explicit cutover hold is a Run-only operation.'}
if(-not $StateFile){$StateFile=Join-Path $DataRoot $(if($ApplicationUuid){"production-evidence\rankme-$ApplicationUuid-recovery-state.json"}else{'production-evidence\rankme-recovery-state.json'})}
if($Mode -ne 'Prepare'){
 $selected=Get-Content -LiteralPath $StateFile -Raw|ConvertFrom-Json -AsHashtable
 if($ApplicationUuid -and $ApplicationUuid -cne $selected.application_uuid){throw 'The selected state belongs to another application.'}
 $ApplicationUuid=$selected.application_uuid
 if($ApplicationUuid -and $selected.docker_host -cne 'coolify-local-host'){throw 'Unknown Docker host in recovery state.'}
}
if($ApplicationUuid -and $ApplicationUuid -cnotmatch '^[a-z0-9]{20,32}$'){throw 'An exact Coolify application UUID is required.'}
if($ApplicationUuid -and $LiveSource){throw 'The Coolify source environment is selected by its application UUID.'}
$dockerPrefix=if($ApplicationUuid){@('exec','-i','coolify-local-host','docker')}else{@()}
$project=if($ApplicationUuid){$ApplicationUuid}else{'rankme'}
if(-not $LiveSource){$LiveSource=if($ApplicationUuid){"/data/gladly/rankme/$ApplicationUuid/source"}else{'C:\Users\OlleG\Documents\Codex\2026-10-17\hitta-ett-gitrepo-som-heter-rankmefast'}}
$socketGroup=if($ApplicationUuid){(& docker exec coolify-local-host stat -c '%g' /var/run/docker.sock|Out-String).Trim()}else{'0'}
if($socketGroup -notmatch '^[0-9]{1,10}$'){throw 'Cannot resolve the selected Docker socket group.'}
function Invoke-RecoveryDocker([string[]]$Arguments){
 $output=& docker.exe @dockerPrefix @Arguments
 if($LASTEXITCODE -ne 0){
  $detail='';foreach($line in $output){try{$entry=$line|ConvertFrom-Json;if($entry.step -eq 'Recovery operation failed' -and $entry.error -is [string]){$detail=$entry.error.Substring(0,[Math]::Min(250,$entry.error.Length))}}catch{}}
  throw "RankMeFast Docker recovery command failed. $detail"
 };$output
}
function Save-State($state){$state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $StateFile -Encoding utf8;Protect-RecoveryPath $StateFile}
if($Mode -eq 'Prepare'){
 New-RecoveryDirectory (Split-Path -Parent $StateFile)
 if(Test-Path -LiteralPath $StateFile){throw 'Select a fresh state file; existing recovery evidence is never overwritten.'}
 if(@(& git -C $source status --porcelain).Count){throw 'Commit and check recovery source before freezing it.'}
 if(@(& git -C $source ls-files -s|Where-Object{$_ -match '^120000 '}).Count){throw 'Review source symlinks before freezing recovery code.'}
 $revision=(& git -C $source rev-parse HEAD).Trim()
 if($LASTEXITCODE -ne 0 -or $revision -notmatch '^[a-f0-9]{40}$'){throw 'An exact source revision is required.'}
 if($ApplicationUuid){
  $null=& docker exec coolify-local-host sh -c 'set -eu; test -f "$1/.env"; test ! -L "$1/.env"; umask 077; mkdir -p "$2"; cp "$1/.env" "$2/.env"; chown 1000:1000 "$2" "$2/.env"; chmod 700 "$2"; chmod 600 "$2/.env"' rankme-recovery-source "/data/coolify/applications/$ApplicationUuid" $LiveSource
  if($LASTEXITCODE -ne 0){throw 'A protected Coolify root environment snapshot could not be prepared.'}
 }elseif(-not(Test-Path -LiteralPath (Join-Path $LiveSource '.env') -PathType Leaf)){throw 'The existing root environment is required.'}
 $id='coolify-'+[DateTime]::UtcNow.ToString('yyyyMMdd')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
 $volume='coolify-rankme-recovery-'+$id.Substring(8)
 $existing=& docker.exe @dockerPrefix volume inspect $volume 2>$null
 if($LASTEXITCODE -eq 0){throw 'Fresh operations volume already exists.'}
 $null=Invoke-RecoveryDocker @('volume','create','--label',"gladly.recovery.source=$project",'--label',"gladly.recovery.id=$id",$volume)
 $mount=(Invoke-RecoveryDocker @('volume','inspect',$volume,'--format','{{.Mountpoint}}')|Out-String).Trim()
 if($mount -ne "/var/lib/docker/volumes/$volume/_data"){throw 'Unexpected operations volume mountpoint.'}
 $image=(Invoke-RecoveryDocker @('image','inspect','local/rankme-operations:20261018','--format','{{.Id}}')|Out-String).Trim()
 if($image -notmatch '^sha256:[a-f0-9]{64}$'){throw 'An exact maintenance image is required.'}
 $archive=Join-Path (Split-Path -Parent $StateFile) "rankme-source-$id.tar"
 $initializer='rankme-recovery-init-'+$id
 try{
  & git -C $source archive --format=tar "--output=$archive" HEAD
  if($LASTEXITCODE -ne 0){throw 'Committed source archive failed.'}
  $archiveHash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  $null=Invoke-RecoveryDocker @('create','--name',$initializer,'--network','none','--user','0','--mount',"type=volume,source=$volume,target=$mount",'--entrypoint','sh',$image,'-c','set -eu; mkdir -p "$1/project" "$1/backups"; tar xf /source.tar -C "$1/project"; chown -R 1000:1000 "$1"; chmod 700 "$1" "$1/project" "$1/backups"','recovery-init',$mount)
  if($ApplicationUuid){
   $hostArchive="/data/gladly/recovery-source/rankme-source-$id.tar"
   $null=& docker exec coolify-local-host sh -c 'umask 077; mkdir -p /data/gladly/recovery-source; chmod 700 /data/gladly/recovery-source'
   if($LASTEXITCODE -ne 0){throw 'Cannot prepare the Docker source transfer directory.'}
   $null=& docker cp $archive "coolify-local-host:$hostArchive"
   if($LASTEXITCODE -ne 0){throw 'Committed source transfer failed.'}
   $null=Invoke-RecoveryDocker @('cp',$hostArchive,"${initializer}:/source.tar")
  }else{$null=Invoke-RecoveryDocker @('cp',$archive,"${initializer}:/source.tar")}
  $null=Invoke-RecoveryDocker @('start','--attach',$initializer)
  if((Invoke-RecoveryDocker @('inspect',$initializer,'--format','{{.State.ExitCode}}')|Out-String).Trim() -ne '0'){throw 'Source extraction failed.'}
 }finally{if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive};$null=& docker.exe @dockerPrefix rm $initializer 2>$null;if($hostArchive){$null=& docker exec coolify-local-host rm -f $hostArchive}}
 $state=[ordered]@{id=$id;volume=$volume;mountpoint=$mount;image=$image;source_revision=$revision;source_archive_sha256=$archiveHash;live_source=$LiveSource;prepared_at_utc=[DateTime]::UtcNow.ToString('o');preflight=$false;guard_test=$false;started=$false;job_name="rankme-recovery-$id";backup_path="$mount/backups/$id"}
 if($ApplicationUuid){$state.application_uuid=$ApplicationUuid;$state.docker_host='coolify-local-host'}
 Save-State $state
 [pscustomobject]@{prepared=$true;id=$id;source_revision=$revision;volume=$volume;original_services_changed=$false}|ConvertTo-Json;exit
}
$state=Get-Content -LiteralPath $StateFile -Raw|ConvertFrom-Json -AsHashtable
if($state.id -notmatch '^coolify-[0-9]{8}-[a-f0-9]{8}$' -or $state.volume -ne ('coolify-rankme-recovery-'+$state.id.Substring(8)) -or $state.mountpoint -ne "/var/lib/docker/volumes/$($state.volume)/_data" -or $state.job_name -cne "rankme-recovery-$($state.id)" -or $state.backup_path -cne "$($state.mountpoint)/backups/$($state.id)" -or $state.image -notmatch '^sha256:[a-f0-9]{64}$' -or ($ApplicationUuid -and $state.live_source -cne $LiveSource)){throw 'Invalid recovery state identity.'}
if($Mode -eq 'Status'){
 $raw=& docker.exe @dockerPrefix inspect $state.job_name --format '{"running":{{json .State.Running}},"status":{{json .State.Status}},"exit":{{.State.ExitCode}}}' 2>$null
 if($LASTEXITCODE -eq 0){$raw;& docker.exe @dockerPrefix logs --tail 8 $state.job_name}else{[pscustomobject]@{job_exists=$false;started=$state.started}|ConvertTo-Json}
 if($state.guard_name){& docker.exe @dockerPrefix inspect $state.guard_name --format '{"guard_running":{{json .State.Running}},"restarts":{{.RestartCount}}}'; & docker.exe @dockerPrefix logs --tail 2 $state.guard_name};exit
}
if(((& git -C $source rev-parse HEAD).Trim() -ne $state.source_revision) -or @(& git -C $source status --porcelain).Count){throw 'Recovery source changed after its frozen snapshot.'}
$script="$($state.mountpoint)/project/ops/coolify/recovery.ts"
$common=@('--network','none','--user','1000:1000','--group-add',$socketGroup,'--cap-drop','ALL','--security-opt','no-new-privileges:true','--memory','2g','--cpus','1.5','--pids-limit','256','--mount',"type=volume,source=$($state.volume),target=$($state.mountpoint)",'--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock','--workdir',"$($state.mountpoint)/project",'--env',"RECOVERY_MAINTENANCE_IMAGE=$($state.image)",'--env',"RECOVERY_SOCKET_GID=$socketGroup",'--env',"RANKME_DOCKER_PROJECT=$project")
if($Mode -eq 'RestoreExisting'){
 if($state.started -or -not $BackupStateFile){throw 'Use a fresh prepared verifier and an explicit original backup state file.'}
 $backup=Get-Content -LiteralPath $BackupStateFile -Raw|ConvertFrom-Json -AsHashtable
 if($backup.application_uuid -cne $state.application_uuid -or $backup.docker_host -cne $state.docker_host){throw 'A restore retry must use the same application Docker daemon.'}
 if($backup.id -notmatch '^coolify-[0-9]{8}-[a-f0-9]{8}$' -or $backup.volume -ne ('coolify-rankme-recovery-'+$backup.id.Substring(8)) -or $backup.mountpoint -ne "/var/lib/docker/volumes/$($backup.volume)/_data" -or $backup.backup_path -ne "$($backup.mountpoint)/backups/$($backup.id)"){throw 'Invalid original backup identity.'}
 $job=(Invoke-RecoveryDocker (@('run','-d','--name',$state.job_name,'--label',"gladly.recovery.id=$($state.id)",'--label','gladly.recovery.mode=restore-only')+$common+@('--mount',"type=volume,source=$($backup.volume),target=$($backup.mountpoint)",$state.image,$script,'--mode=restore',"--id=$($state.id)","--backup=$($backup.backup_path)","--revision=$($state.source_revision)"))|Out-String).Trim()
 if($job -notmatch '^[a-f0-9]{64}$'){throw 'Invalid isolated verifier identity.'}
 $state.started=$true;$state.container_id=$job;$state.mode='restore-only';Save-State $state
 $backup.verified_restore_container_id=$job;$backup.verified_restore_volume=$state.volume;$backup.verified_restore_mountpoint=$state.mountpoint;$backup.verified_restore_revision=$state.source_revision
 $backup|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $BackupStateFile -Encoding utf8
 [pscustomobject]@{job=$state.job_name;container_id=$job;original_applications_stopped=$false;live_source_mounted=$false;backup_reused=$true}|ConvertTo-Json;exit
}
if($Mode -eq 'Preflight'){
 $null=Invoke-RecoveryDocker (@('run','--rm')+$common+@('--mount',"type=bind,source=$($state.live_source),target=/live-source,readonly",$state.image,$script,'--mode=preflight'))
 $state.preflight=$true;Save-State $state;[pscustomobject]@{preflight=$true;original_services_stopped=$false}|ConvertTo-Json;exit
}
if($Mode -eq 'TestGuard'){
 $testId='coolify-'+[DateTime]::UtcNow.ToString('yyyyMMdd')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
 $null=Invoke-RecoveryDocker (@('run','--rm')+$common+@($state.image,$script,'--mode=test-guard',"--id=$testId","--image=$($state.image)"))
 $state.guard_test=$true;Save-State $state;[pscustomobject]@{sigkill_guard_test=$true;original_services_changed=$false}|ConvertTo-Json;exit
}
if(-not $state.preflight -or -not $state.guard_test -or $state.started){throw 'A fresh successful preflight and independent guard test are required.'}
$id=(Invoke-RecoveryDocker (@('create')+$common+@('--name',$state.job_name,'--label',"gladly.recovery.id=$($state.id)",'--mount',"type=bind,source=$($state.live_source),target=/live-source,readonly",$state.image,$script,'--mode=backup',"--id=$($state.id)","--revision=$($state.source_revision)"))|Out-String).Trim()
if($id -notmatch '^[a-f0-9]{64}$'){throw 'Invalid maintenance container identity.'}
$writer='const fs=await import("node:fs/promises");const original=JSON.parse(await fs.readFile(process.argv[1],"utf8"));const apps={};for(const name of ["api","web","worker"])apps[name]={id:original[name].id,image:original[name].image};await fs.writeFile(process.argv[2],JSON.stringify({jobId:process.argv[3],jobName:process.argv[4],project:process.argv[5],holdOnSuccess:process.argv[6]==="true",originals:apps}),{mode:0o600});'
$null=Invoke-RecoveryDocker (@('run','--rm')+$common+@($state.image,'-e',$writer,"$($state.mountpoint)/project/data/coolify-recovery/original.json","$($state.mountpoint)/project/data/coolify-recovery/intent.json",$id,$state.job_name,$project,$HoldForCutover.ToString().ToLowerInvariant()))
$guardName=$state.job_name+'-guard'
$guardCommon=@();for($i=0;$i -lt $common.Count;$i++){if($common[$i] -eq '--memory'){$guardCommon+=@('--memory','128m');$i++}elseif($common[$i] -eq '--cpus'){$guardCommon+=@('--cpus','0.25');$i++}else{$guardCommon+=$common[$i]}}
$null=Invoke-RecoveryDocker (@('run','-d','--name',$guardName,'--restart','unless-stopped')+$guardCommon+@($state.image,$script,'--mode=guard'))
$state.container_id=$id;$state.guard_name=$guardName;Save-State $state
$ready=$false;for($attempt=0;$attempt -lt 20;$attempt++){$logs=(Invoke-RecoveryDocker @('logs','--tail','2',$guardName)|Out-String);if($logs.Contains('Recovery guard ready')){$ready=$true;break};Start-Sleep -Milliseconds 300}
if(-not $ready){throw 'Independent guard did not become ready; no original service was stopped.'}
$null=Invoke-RecoveryDocker @('start',$id);$state.started=$true;$state.started_at_utc=[DateTime]::UtcNow.ToString('o');Save-State $state
[pscustomobject]@{job=$state.job_name;container_id=$id;backup_started=$true;production_cutover=$false}|ConvertTo-Json
