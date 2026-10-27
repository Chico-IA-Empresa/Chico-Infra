param(
    [Parameter(Mandatory=$true)][ValidatePattern('^package-[0-9]{8}-[a-z0-9-]+$')][string]$RunId,
    [Parameter(Mandatory=$true)][ValidatePattern('^chico-package-[a-z0-9-]+$')][string]$Project
)
# Dot-source this file. Only non-sensitive paths/image refs enter environment.
$env:API_IMAGE = 'chico-api:local-fixture'
$env:WORKERS_IMAGE = 'chico-workers:local-fixture'
$env:FRONTEND_IMAGE = 'chico-frontend:local-fixture'
$env:PACKAGE_DATA_ROOT = "/srv/chico/fixture/$RunId/data"
$env:PACKAGE_CONFIG_ROOT = "/srv/chico/fixture/$RunId/config"
$PackageProject = $Project
$PackageCompose = @('-p', $Project, '-f', "$PSScriptRoot/compose.yaml", '-f', "$PSScriptRoot/compose.emulated.yaml")
