#requires -Version 7.0
[CmdletBinding()]
param([string]$DataRoot=(Join-Path $env:USERPROFILE '.coolify'),[string]$StateFile=(Join-Path $DataRoot 'production-evidence\rankme-recovery-state.json'),[switch]$ResumeExport)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Run the exporter with PowerShell7 on the mini-PC.'}
. (Join-Path $PSScriptRoot 'private-files.ps1')
$state=Get-Content -LiteralPath $StateFile -Raw|ConvertFrom-Json -AsHashtable
if($state.id -notmatch '^coolify-[0-9]{8}-[a-f0-9]{8}$' -or $state.volume -ne ('coolify-rankme-recovery-'+$state.id.Substring(8))){throw 'Invalid original backup identity.'}
if($state.application_uuid -and ($state.application_uuid -cnotmatch '^[a-z0-9]{20,32}$' -or $state.docker_host -cne 'coolify-local-host')){throw 'Invalid Coolify application Docker identity.'}
$dockerPrefix=if($state.application_uuid){@('exec','-i','coolify-local-host','docker')}else{@()}
function Invoke-ApplicationDocker([string[]]$Arguments){$output=& docker.exe @dockerPrefix @Arguments;if($LASTEXITCODE -ne 0){throw 'Application Docker inspection failed.'};$output}
function Invoke-PrivateDocker([string[]]$Arguments,[string]$Step,[switch]$InApplicationEngine){
 $info=[Diagnostics.ProcessStartInfo]::new('docker.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $selected=if($InApplicationEngine){$dockerPrefix+@($Arguments|ForEach-Object{if($_ -ceq $image){$applicationCryptoImage}else{$_}})}else{$Arguments}
 foreach($argument in $selected){$info.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::new();$process.StartInfo=$info
 try{if(-not $process.Start()){throw 'Could not start the private Docker helper.'};$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit();$output=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult();if($process.ExitCode -ne 0){throw "Encrypted export step failed: $Step (exit $($process.ExitCode))."};$output.Trim()}finally{$process.Dispose()}
}
$jobId=if($state.verified_restore_container_id){$state.verified_restore_container_id}else{$state.container_id}
if($jobId -notmatch '^[a-f0-9]{64}$'){throw 'An exact completed verifier is required.'}
$job=(Invoke-ApplicationDocker @('inspect',$jobId)|ConvertFrom-Json)[0]
if($LASTEXITCODE -ne 0 -or $job.State.Running -or $job.State.ExitCode -ne 0){throw 'A successful completed verifier is required before export.'}
$getter=@'
const fs=await import("node:fs/promises");const p="/source/backups/"+process.argv[1];
const manifest=JSON.parse(await fs.readFile(p+"/manifest.json","utf8"));
const files=["baseline.json","mongo.archive.gz","postgres.dump","private/original-runtime.json","private/root-env","redis.rdb"];
if(manifest.version!==1||manifest.project!=="rankme"||JSON.stringify(Object.keys(manifest.hashes??{}).sort())!==JSON.stringify(files))throw Error("Unexpected manifest");
for(const name of files){const file=p+"/"+name;const info=await fs.lstat(file);if(!info.isFile()||info.isSymbolicLink())throw Error("Invalid backup file");const hash=new Bun.CryptoHasher("sha256");for await(const part of Bun.file(file).stream())hash.update(part);if(hash.digest("hex")!==manifest.hashes[name])throw Error("Backup hash mismatch");}
const original=JSON.parse(await fs.readFile(p+"/private/original-runtime.json","utf8"));const proof=JSON.parse(await fs.readFile(p+"/recovery-verified.json","utf8"));console.log(JSON.stringify({services:Object.keys(original).sort(),images:[...new Set(Object.values(original).map(x=>x.image))],proof}));
'@
$metadata=(Invoke-PrivateDocker @('run','--rm','--network','none','--user','1000:1000','--mount',"type=volume,source=$($state.volume),target=/source,readonly",$state.image,'-e',$getter,$state.id) 'read allowlisted verification metadata' -InApplicationEngine)|ConvertFrom-Json
if(-not $metadata.proof.completeSqlDataAndSchemaMatch -or -not $metadata.proof.mongoDocumentsAndIndexMetadataMatch -or -not $metadata.proof.completeRedisLogicalDataMatch -or -not $metadata.proof.redisAofRestartVerified -or $metadata.proof.apiStarted -or $metadata.proof.workerStarted -or $metadata.proof.providerCalled){throw 'Complete isolated recovery proof is required.'}
$images=@($metadata.images)
if(($metadata.services -join ',') -cne 'api,mongo,postgres,redis,web,worker' -or $images.Count -lt 5 -or $images.Count -gt 6 -or @($images|Where-Object{$_ -notmatch '^sha256:[a-f0-9]{64}$'}).Count){throw 'Unexpected original execution image inventory.'}
foreach($candidate in $images){$config=(Invoke-ApplicationDocker @('image','inspect',$candidate)|ConvertFrom-Json)[0].Config;if(@($config.Env|Where-Object{$parts=$_.Split('=',2);$parts[0] -match 'SECRET|TOKEN|PASSWORD|MASTER_ENCRYPTION_KEY|BETTER_AUTH_SECRET|API_KEY' -and $parts[1].Length}).Count){throw 'Do not export an execution image with baked credential environment values.'}}
$image=(& docker.exe image inspect local/coolify-backup-crypto:age-1.3.2 --format '{{.Id}}'|Out-String).Trim()
if($LASTEXITCODE -ne 0 -or $image -notmatch '^sha256:[a-f0-9]{64}$'){throw 'Build the pinned Dockerfile.backup-crypto helper first.'}
$applicationCryptoImage=$image
if($state.application_uuid){
 $parentImage=(& docker image inspect $image|ConvertFrom-Json)[0]
 $nestedImage=(Invoke-ApplicationDocker @('image','inspect','local/coolify-backup-crypto:age-1.3.2')|ConvertFrom-Json)[0]
 $selectedConfig={param($entry)[ordered]@{User=$entry.Config.User;WorkingDir=$entry.Config.WorkingDir;Entrypoint=@($entry.Config.Entrypoint);Cmd=@($entry.Config.Cmd);Env=@($entry.Config.Env);OS=$entry.Os;Architecture=$entry.Architecture;Layers=@($entry.RootFS.Layers)}|ConvertTo-Json -Depth 6 -Compress}
 if((& $selectedConfig $parentImage) -cne (& $selectedConfig $nestedImage)){throw 'The nested encryption helper differs from the verified parent image.'}
 $applicationCryptoImage=$nestedImage.Id
}
$root=[IO.Path]::GetFullPath($DataRoot);$keys=Join-Path $root 'recovery-keys';$archives=Join-Path $root 'application-backups';$destination=Join-Path $archives ('rankme-'+$state.id)
New-RecoveryDirectory $keys;New-RecoveryDirectory $archives
if(Test-Path -LiteralPath $destination){
 if(-not $ResumeExport -or -not $state.application_uuid){throw 'An encrypted export destination already exists; no backup will be overwritten.'}
 $residual=@(Get-ChildItem -LiteralPath $destination -Force)
 if(@($residual|Where-Object{$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -notin @('plaintext.sha256','rankme.tar.age.partial')}).Count){throw 'Refuse to resume a completed or unrecognized export directory.'}
}
if($ResumeExport -and (Invoke-ApplicationDocker @('ps','--filter',"volume=$($state.volume)",'--format','{{.ID}}')|Out-String).Trim()){throw 'A prior application recovery/export helper is still running; wait for it before resuming.'}
$common=@('run','--rm','--network','none','--user','1000:1000','--cap-drop','ALL','--security-opt','no-new-privileges:true','--memory','256m','--cpus','0.5','--pids-limit','64')
$keyScript=@'
set -eu
umask 077
if test ! -e /keys/mini-pc.agekey; then age-keygen -o /keys/mini-pc.agekey >/dev/null 2>/dev/null; fi
age-keygen -y /keys/mini-pc.agekey
'@
$recipient=Invoke-PrivateDocker ($common+@('--mount',"type=bind,source=$keys,target=/keys",$image,'-c',$keyScript)) 'load separate protected recovery identity'
if($recipient -notmatch '^age1[a-z0-9]{58}$'){throw 'Unexpected age recovery recipient.'}
Protect-RecoveryPath (Join-Path $keys 'mini-pc.agekey')
$negative=@'
set -euo pipefail
printf recovery-verification | age -r "$1" -o /tmp/test.age
test "$(age -d -i /keys/mini-pc.agekey /tmp/test.age)" = recovery-verification
head -c 100 /tmp/test.age > /tmp/truncated.age
if age -d -i /keys/mini-pc.agekey /tmp/truncated.age >/dev/null 2>/dev/null; then exit 1; fi
cp /tmp/test.age /tmp/corrupt.age
printf '\000' | dd of=/tmp/corrupt.age bs=1 count=1 conv=notrunc >/dev/null 2>/dev/null
if age -d -i /keys/mini-pc.agekey /tmp/corrupt.age >/dev/null 2>/dev/null; then exit 1; fi
age-keygen -o /tmp/wrong.agekey >/dev/null 2>/dev/null
if age -d -i /tmp/wrong.agekey /tmp/test.age >/dev/null 2>/dev/null; then exit 1; fi
'@
$null=Invoke-PrivateDocker ($common+@('--mount',"type=bind,source=$keys,target=/keys,readonly",$image,'-c',$negative,'crypto-check',$recipient)) 'reject wrong-key, corruption and truncation'
$bundle=@'
set -euo pipefail
umask 077
directory="/source/backups/$1"
shift
test -s "$directory/recovery-verified.json"
if test -e "$directory/execution-images.tar"; then
  test -s "$directory/export-attachments.sha256"
  cd "$directory"
  sha256sum -c export-attachments.sha256 >/dev/null
  exit 0
fi
docker image save --output "$directory/execution-images.tar.partial" "$@"
mv "$directory/execution-images.tar.partial" "$directory/execution-images.tar"
tar czf "$directory/recovery-source.tgz" --exclude=./.env --exclude=./data --exclude=./node_modules --exclude=./dist -C /source/project .
if test -d /verifier/project; then tar czf "$directory/recovery-verifier-source.tgz" --exclude=./.env --exclude=./data --exclude=./node_modules --exclude=./dist -C /verifier/project .; fi
cd "$directory"
sha256sum execution-images.tar recovery-source.tgz > export-attachments.sha256
if test -f recovery-verifier-source.tgz; then sha256sum recovery-verifier-source.tgz >> export-attachments.sha256; fi
'@
$socketGroup=if($state.application_uuid){(& docker exec coolify-local-host stat -c '%g' /var/run/docker.sock|Out-String).Trim()}else{'0'}
if($socketGroup -notmatch '^[0-9]{1,10}$'){throw 'Cannot resolve application Docker socket group.'}
$mounts=@('--group-add',$socketGroup,'--mount',"type=volume,source=$($state.volume),target=/source",'--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock')
if($state.verified_restore_volume){if($state.verified_restore_volume -notmatch '^coolify-rankme-recovery-[0-9]{8}-[a-f0-9]{8}$'){throw 'Invalid separate verifier volume.'};$mounts+=@('--mount',"type=volume,source=$($state.verified_restore_volume),target=/verifier,readonly")}
$null=Invoke-PrivateDocker ($common+$mounts+@($image,'-c',$bundle,'bundle-recovery-inputs',$state.id)+$images) 'bundle exact images and committed recovery source' -InApplicationEngine
New-RecoveryDirectory $destination
$export=@'
set -euo pipefail
umask 077
test ! -e /output/rankme.tar.age.partial
mkfifo /tmp/hash-pipe
sha256sum < /tmp/hash-pipe > /output/plaintext.sha256 &
hash_pid=$!
tar cf - -C "/source/backups/$1" . | tee /tmp/hash-pipe | age -r "$2" -o /output/rankme.tar.age.partial
wait "$hash_pid"
'@
$partial=Join-Path $destination 'rankme.tar.age.partial'
try{
 if($state.application_uuid){
  $encryptedRoot="/data/gladly/recovery-exports/rankme-$($state.id)"
  $null=& docker exec coolify-local-host test -e $encryptedRoot
  $existingTransfer=$LASTEXITCODE -eq 0
  if($existingTransfer){
   if(-not $ResumeExport){throw 'An encrypted transfer already exists; use explicit resume.'}
   $null=& docker exec coolify-local-host sh -c 'set -eu; test -d "$1"; test ! -L "$1"; test -s "$1/rankme.tar.age.partial"; test ! -L "$1/rankme.tar.age.partial"; test -s "$1/plaintext.sha256"; test ! -L "$1/plaintext.sha256"; test "$(find "$1" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2' rankme-existing-ciphertext $encryptedRoot
   if($LASTEXITCODE -ne 0){throw 'Unrecognized or incomplete encrypted transfer inputs.'}
  }else{
   $null=& docker exec coolify-local-host sh -c 'set -eu; test ! -e "$1"; umask 077; mkdir -p "$1"; chown 1000:1000 "$1"; chmod 700 "$1"' rankme-encrypted-export $encryptedRoot
   if($LASTEXITCODE -ne 0){throw 'Fresh protected encrypted transfer directory is required.'}
   $null=Invoke-PrivateDocker ($common+@('--mount',"type=volume,source=$($state.volume),target=/source,readonly",'--mount',"type=bind,source=$encryptedRoot,target=/output",$image,'-c',$export,'encrypt-application-backup',$state.id,$recipient)) 'encrypt inside application Docker without the private identity' -InApplicationEngine
  }
  if(Test-Path -LiteralPath $partial){if(-not $ResumeExport){throw 'A prior partial Windows transfer exists.'};Remove-Item -LiteralPath $partial}
  # Only ciphertext leaves the nested daemon. Native streams preserve binary bytes.
  $info=[Diagnostics.ProcessStartInfo]::new('docker.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  foreach($argument in @('exec','coolify-local-host','cat',"$encryptedRoot/rankme.tar.age.partial")){$info.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$file=[IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{if(-not $process.Start()){throw 'Encrypted transfer could not start.'};$stderr=$process.StandardError.ReadToEndAsync();$process.StandardOutput.BaseStream.CopyTo($file);$file.Flush($true);$process.WaitForExit();$null=$stderr.GetAwaiter().GetResult();if($process.ExitCode -ne 0){throw 'Encrypted binary transfer failed.'}}finally{$file.Dispose();$process.Dispose()}
  $plain=Invoke-PrivateDocker @('exec','coolify-local-host','cat',"$encryptedRoot/plaintext.sha256") 'read full plaintext digest only'
  [IO.File]::WriteAllText((Join-Path $destination 'plaintext.sha256'),$plain+"`n",[Text.UTF8Encoding]::new($false))
 }else{
  $null=Invoke-PrivateDocker ($common+@('--mount',"type=volume,source=$($state.volume),target=/source,readonly",'--mount',"type=bind,source=$destination,target=/output",$image,'-c',$export,'encrypt-application-backup',$state.id,$recipient)) 'stream directly to encrypted Windows archive'
 }
 Protect-RecoveryPath $partial;Protect-RecoveryPath (Join-Path $destination 'plaintext.sha256')
 $verify=@'
set -euo pipefail
age -d -i /keys/mini-pc.agekey /backup/rankme.tar.age.partial | sha256sum > /tmp/roundtrip.sha256
cmp /tmp/roundtrip.sha256 /backup/plaintext.sha256
'@
 $null=Invoke-PrivateDocker ($common+@('--mount',"type=bind,source=$keys,target=/keys,readonly",'--mount',"type=bind,source=$destination,target=/backup,readonly",$image,'-c',$verify)) 'authenticate the full decrypted stream and compare its hash'
 $archive=Join-Path $destination 'rankme.tar.age';Move-Item -LiteralPath $partial -Destination $archive;Protect-RecoveryPath $archive
 $plain=(Get-Content -LiteralPath (Join-Path $destination 'plaintext.sha256') -Raw).Trim();if($plain -notmatch '^([a-f0-9]{64})  -$'){throw 'Unexpected full plaintext stream hash.'};$plainHash=$Matches[1]
 $receipt=[ordered]@{version=1;project='rankme';application_uuid=$state.application_uuid;docker_host=$state.docker_host;completed_at_utc=[DateTime]::UtcNow.ToString('o');operation_id=$state.id;source_revision=$state.source_revision;restore_verifier_revision=$metadata.proof.restoreVerifierRevision;execution_images=$images;exact_images_included=$true;frozen_recovery_source_included=$true;format='age v1';tool_version='1.3.2';crypto_image=$image;archive=$archive;encrypted_bytes=(Get-Item -LiteralPath $archive).Length;encrypted_sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant();decrypted_archive_sha256=$plainHash;complete_roundtrip_verified=$true;wrong_key_rejected=$true;corruption_rejected=$true;truncation_rejected=$true;windows_plaintext_archive_created=$false;identity_file=Join-Path $keys 'mini-pc.agekey';key_separate_from_archive=$true;private_identity_in_application_engine=$false;windows_acl='current owner and SYSTEM only';off_host_copy_verified=$false;provider_called=$false}
 $receiptPath=Join-Path $destination 'receipt.json';[IO.File]::WriteAllText($receiptPath,($receipt|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false));Protect-RecoveryPath $receiptPath
 if($encryptedRoot){$null=& docker exec coolify-local-host sh -c 'set -eu; rm "$1/rankme.tar.age.partial" "$1/plaintext.sha256"; rmdir "$1"' rankme-encrypted-cleanup $encryptedRoot;if($LASTEXITCODE -ne 0){throw 'Verified export completed, but encrypted transfer cleanup failed.'}}
 [pscustomobject]@{receipt=$receiptPath;encrypted_bytes=$receipt.encrypted_bytes;roundtrip_verified=$true;off_host_copy_verified=$false;private_key_printed=$false}|ConvertTo-Json
}finally{if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial}}
