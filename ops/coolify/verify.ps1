#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
& (Join-Path $PSScriptRoot 'render.ps1') -Check
$identities = @()
foreach ($project in @('coolify-rankme-acceptance-a','coolify-rankme-acceptance-b')) {
    $raw = & docker compose --project-directory $root --project-name $project --env-file (Join-Path $root '.env.example') -f (Join-Path $root 'docker-compose.coolify.rendered.yml') config --no-interpolate --no-path-resolution --format json
    if ($LASTEXITCODE -ne 0) { throw 'Standalone deployment definition is invalid.' }
    $config = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
    if ($config.services.Count -ne 6) { throw 'Expected six application services.' }
    foreach ($service in $config.services.Values) {
        if ($service.ports -or $service.container_name -or $service.privileged) { throw 'Unscoped host exposure or container identity found.' }
        if (-not $service.mem_limit -or -not $service.cpus -or -not $service.pids_limit -or -not $service.healthcheck) { throw 'Runtime health or resource controls missing.' }
    }
    $names = @($config.volumes.Values.name) + @($config.networks.Values.name)
    if (@($names | Where-Object {$_ -and $_ -notlike "${project}_*"}).Count) { throw 'Resources have a global identity.' }
    $identities += ,$names
}
if (@($identities[0] | Where-Object {$_ -in $identities[1]}).Count) { throw 'Two project instances would share persistent resources.' }
[pscustomobject]@{services=6;host_ports=0;separate_project_resources=$true;runtime_health_and_limits=$true;provider_operation_verified=$false;production_accepted=$false} | ConvertTo-Json
