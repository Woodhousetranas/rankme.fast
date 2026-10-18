#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Prepare','Preflight','TestGuard','Run','Status')][string]$Mode='Prepare',[string]$StateFile,[string]$LiveSource)
$ErrorActionPreference='Stop'
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(-not $LiveSource){$LiveSource='C:\Users\OlleG\Documents\Codex\2026-10-17\hitta-ett-gitrepo-som-heter-rankmefast'}
if(-not $StateFile){$StateFile=Join-Path $env:LOCALAPPDATA 'Coolify\production-evidence\rankme-recovery-state.json'}
function Invoke-RecoveryDocker([string[]]$Arguments){
 $output=& docker.exe @Arguments
 if($LASTEXITCODE -ne 0){
  $detail='';foreach($line in $output){try{$entry=$line|ConvertFrom-Json;if($entry.step -eq 'Recovery operation failed' -and $entry.error -is [string]){$detail=$entry.error.Substring(0,[Math]::Min(250,$entry.error.Length))}}catch{}}
  throw "RankMeFast Docker recovery command failed. $detail"
 };$output
}
function Save-State($state){$state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $StateFile -Encoding utf8}
if($Mode -eq 'Prepare'){
 if(@(& git -C $source status --porcelain).Count){throw 'Commit and check recovery source before freezing it.'}
 if(@(& git -C $source ls-files -s|Where-Object{$_ -match '^120000 '}).Count){throw 'Review source symlinks before freezing recovery code.'}
 $revision=(& git -C $source rev-parse HEAD).Trim()
 if($revision -notmatch '^[a-f0-9]{40}$' -or -not(Test-Path -LiteralPath (Join-Path $LiveSource '.env') -PathType Leaf)){throw 'An exact source revision and existing root environment are required.'}
 $id='coolify-'+[DateTime]::UtcNow.ToString('yyyyMMdd')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
 $volume='coolify-rankme-recovery-'+$id.Substring(8)
 $existing=& docker.exe volume inspect $volume 2>$null
 if($LASTEXITCODE -eq 0){throw 'Fresh operations volume already exists.'}
 $null=Invoke-RecoveryDocker @('volume','create','--label','gladly.recovery.source=rankme','--label',"gladly.recovery.id=$id",$volume)
 $mount=(Invoke-RecoveryDocker @('volume','inspect',$volume,'--format','{{.Mountpoint}}')|Out-String).Trim()
 if($mount -ne "/var/lib/docker/volumes/$volume/_data"){throw 'Unexpected operations volume mountpoint.'}
 $image=(Invoke-RecoveryDocker @('image','inspect','local/rankme-operations:20261018','--format','{{.Id}}')|Out-String).Trim()
 if($image -notmatch '^sha256:[a-f0-9]{64}$'){throw 'An exact maintenance image is required.'}
 $archive=Join-Path $env:LOCALAPPDATA "Coolify\production-evidence\rankme-source-$id.tar"
 $initializer='rankme-recovery-init-'+$id
 try{
  & git -C $source archive --format=tar "--output=$archive" HEAD
  if($LASTEXITCODE -ne 0){throw 'Committed source archive failed.'}
  $archiveHash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
  $null=Invoke-RecoveryDocker @('create','--name',$initializer,'--network','none','--user','0','--mount',"type=volume,source=$volume,target=$mount",'--entrypoint','sh',$image,'-c','set -eu; mkdir -p "$1/project" "$1/backups"; tar xf /source.tar -C "$1/project"; chown -R 1000:1000 "$1"; chmod 700 "$1" "$1/project" "$1/backups"','recovery-init',$mount)
  $null=Invoke-RecoveryDocker @('cp',$archive,"${initializer}:/source.tar")
  $null=Invoke-RecoveryDocker @('start','--attach',$initializer)
  if((Invoke-RecoveryDocker @('inspect',$initializer,'--format','{{.State.ExitCode}}')|Out-String).Trim() -ne '0'){throw 'Source extraction failed.'}
 }finally{if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive};$null=& docker.exe rm $initializer 2>$null}
 $state=[ordered]@{id=$id;volume=$volume;mountpoint=$mount;image=$image;source_revision=$revision;source_archive_sha256=$archiveHash;live_source=$LiveSource;prepared_at_utc=[DateTime]::UtcNow.ToString('o');preflight=$false;guard_test=$false;started=$false;job_name="rankme-recovery-$id";backup_path="$mount/backups/$id"}
 Save-State $state
 [pscustomobject]@{prepared=$true;id=$id;source_revision=$revision;volume=$volume;original_services_changed=$false}|ConvertTo-Json;exit
}
$state=Get-Content -LiteralPath $StateFile -Raw|ConvertFrom-Json -AsHashtable
if($state.id -notmatch '^coolify-[0-9]{8}-[a-f0-9]{8}$' -or $state.volume -ne ('coolify-rankme-recovery-'+$state.id.Substring(8)) -or $state.mountpoint -ne "/var/lib/docker/volumes/$($state.volume)/_data"){throw 'Invalid recovery state identity.'}
if($Mode -eq 'Status'){
 $raw=& docker.exe inspect $state.job_name --format '{"running":{{json .State.Running}},"status":{{json .State.Status}},"exit":{{.State.ExitCode}}}' 2>$null
 if($LASTEXITCODE -eq 0){$raw;& docker.exe logs --tail 8 $state.job_name}else{[pscustomobject]@{job_exists=$false;started=$state.started}|ConvertTo-Json}
 if($state.guard_name){& docker.exe inspect $state.guard_name --format '{"guard_running":{{json .State.Running}},"restarts":{{.RestartCount}}}'; & docker.exe logs --tail 2 $state.guard_name};exit
}
if(((& git -C $source rev-parse HEAD).Trim() -ne $state.source_revision) -or @(& git -C $source status --porcelain).Count){throw 'Recovery source changed after its frozen snapshot.'}
$script="$($state.mountpoint)/project/ops/coolify/recovery.ts"
$common=@('--network','none','--user','1000:1000','--group-add','0','--cap-drop','ALL','--security-opt','no-new-privileges:true','--memory','2g','--cpus','1.5','--pids-limit','256','--mount',"type=volume,source=$($state.volume),target=$($state.mountpoint)",'--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock','--workdir',"$($state.mountpoint)/project",'--env',"RECOVERY_MAINTENANCE_IMAGE=$($state.image)")
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
$writer='const fs=await import("node:fs/promises");const original=JSON.parse(await fs.readFile(process.argv[1],"utf8"));const apps={};for(const name of ["api","web","worker"])apps[name]={id:original[name].id,image:original[name].image};await fs.writeFile(process.argv[2],JSON.stringify({jobId:process.argv[3],jobName:process.argv[4],originals:apps}),{mode:0o600});'
$null=Invoke-RecoveryDocker (@('run','--rm')+$common+@($state.image,'-e',$writer,"$($state.mountpoint)/project/data/coolify-recovery/original.json","$($state.mountpoint)/project/data/coolify-recovery/intent.json",$id,$state.job_name))
$guardName=$state.job_name+'-guard'
$guardCommon=@();for($i=0;$i -lt $common.Count;$i++){if($common[$i] -eq '--memory'){$guardCommon+=@('--memory','128m');$i++}elseif($common[$i] -eq '--cpus'){$guardCommon+=@('--cpus','0.25');$i++}else{$guardCommon+=$common[$i]}}
$null=Invoke-RecoveryDocker (@('run','-d','--name',$guardName,'--restart','unless-stopped')+$guardCommon+@($state.image,$script,'--mode=guard'))
$state.container_id=$id;$state.guard_name=$guardName;Save-State $state
$ready=$false;for($attempt=0;$attempt -lt 20;$attempt++){$logs=(Invoke-RecoveryDocker @('logs','--tail','2',$guardName)|Out-String);if($logs.Contains('Recovery guard ready')){$ready=$true;break};Start-Sleep -Milliseconds 300}
if(-not $ready){throw 'Independent guard did not become ready; no original service was stopped.'}
$null=Invoke-RecoveryDocker @('start',$id);$state.started=$true;$state.started_at_utc=[DateTime]::UtcNow.ToString('o');Save-State $state
[pscustomobject]@{job=$state.job_name;container_id=$id;backup_started=$true;production_cutover=$false}|ConvertTo-Json
