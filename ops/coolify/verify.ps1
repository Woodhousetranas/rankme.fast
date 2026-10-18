#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& (Join-Path $PSScriptRoot 'render.ps1') -Check
$identities = @()
foreach ($project in @('coolify-rankme-acceptance-a','coolify-rankme-acceptance-b')) {
    $publicEnv = Join-Path ([IO.Path]::GetTempPath()) ('rankme-compose-check-' + [Guid]::NewGuid().ToString('N') + '.env')
    try {
        [IO.File]::WriteAllText($publicEnv,"COOLIFY_RESOURCE_UUID=$project`nAPP_BUILD_SHA=000000000000`nAPP_SOURCE_REVISION=0000000000000000000000000000000000000000`n",[Text.UTF8Encoding]::new($false))
        $raw = & docker compose --project-directory $root --project-name $project --env-file (Join-Path $root '.env.example') --env-file $publicEnv -f (Join-Path $root 'docker-compose.coolify.rendered.yml') config --no-path-resolution --format json
    } finally { Remove-Item -LiteralPath $publicEnv }
    if ($LASTEXITCODE -ne 0) { throw 'Standalone deployment definition is invalid.' }
    $config = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($config.services.Count -ne 6) { throw 'Expected six application services.' }
    foreach ($service in $config.services.Values) {
        if ($service.ports -or $service.container_name -or $service.privileged) { throw 'Unscoped host exposure or container identity found.' }
        if ($service.env_file) { throw 'A shared env file exposes credentials across service boundaries.' }
        if (-not $service.mem_limit -or -not $service.cpus -or -not $service.pids_limit -or -not $service.healthcheck) { throw 'Runtime health or resource controls missing.' }
    }
    $names = @($config.volumes.Values.name) + @($config.networks.Values.name)
    if (@($names | Where-Object {$_ -and $_ -ne $project -and $_ -notlike "${project}_*"}).Count) { throw 'Resources have a global identity.' }
    if (-not $config.networks.rankme.external -or $config.networks.rankme.name -ne $project) { throw 'Proxy network does not match the unique Coolify resource.' }
    if (@($config.services.web.networks.Keys).Count -ne 1 -or -not $config.services.web.networks.ContainsKey('rankme')) { throw 'The public web service has a backend network.' }
    foreach ($name in @('mongo','postgres','redis','worker')) { if (@($config.services[$name].networks.Keys).Count -ne 1 -or -not $config.services[$name].networks.ContainsKey('core')) { throw 'A database or worker is attached to the proxy network.' } }
    foreach ($key in @('MASTER_ENCRYPTION_KEY','BETTER_AUTH_SECRET','POSTGRES_PASSWORD','DATABASE_URL','RESEND_API_KEY')) { if ($config.services.web.environment.ContainsKey($key)) { throw 'The public web service receives an API or database secret.' } }
    $identities += ,$names
}
if (@($identities[0] | Where-Object {$_ -in $identities[1]}).Count) { throw 'Two project instances would share persistent resources.' }
[pscustomobject]@{services=6;host_ports=0;separate_project_resources=$true;runtime_health_and_limits=$true;provider_operation_verified=$false;production_accepted=$false} | ConvertTo-Json
