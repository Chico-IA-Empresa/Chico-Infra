param([string]$Python, [string]$CheckovScript)
$ErrorActionPreference = 'Stop'
$taskBase = Split-Path -Parent $PSScriptRoot
Push-Location $taskBase
try {
  foreach ($taskScope in @('bootstrap', 'shared', 'dev')) {
    $taskDirectory = if ($taskScope -eq 'bootstrap') { 'bootstrap' } else { "envs/$taskScope" }
    $taskReport = "reports/checkov-$taskScope-scope.json"
    & $Python $CheckovScript -d $taskDirectory --framework terraform --quiet --skip-download -o json > $taskReport
    if ($LASTEXITCODE -notin @(0, 1)) { throw "Checkov crashed in $taskScope" }
    node scripts/security-gate.mjs $taskReport $taskScope
    if ($LASTEXITCODE -ne 0) { throw "Security review failed in $taskScope" }
  }
} finally { Pop-Location }
