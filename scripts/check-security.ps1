param([string]$Python, [string]$CheckovScript)
$ErrorActionPreference = 'Stop'
$taskBase = Split-Path -Parent $PSScriptRoot
$taskOriginalHashSeed = $env:PYTHONHASHSEED
Push-Location $taskBase
try {
  $env:PYTHONHASHSEED = '0'
  foreach ($taskScope in @('bootstrap', 'shared', 'dev')) {
    $taskDirectory = if ($taskScope -eq 'bootstrap') { 'bootstrap' } else { "envs/$taskScope" }
    $taskReport = "reports/checkov-$taskScope-scope.json"
    $taskScanArguments = @()
    if ($taskScope -eq 'dev') { $taskScanArguments = @('--var-file', (Join-Path $taskBase 'security/dev-scan.tfvars')) }
    & $Python $CheckovScript -d $taskDirectory --framework terraform --quiet --skip-download @taskScanArguments -o json > $taskReport
    if ($LASTEXITCODE -notin @(0, 1)) { throw "Checkov crashed in $taskScope" }
    node scripts/security-gate.mjs $taskReport $taskScope
    if ($LASTEXITCODE -ne 0) { throw "Security review failed in $taskScope" }
  }
} finally {
  if ([string]::IsNullOrEmpty($taskOriginalHashSeed)) { Remove-Item -LiteralPath Env:PYTHONHASHSEED -ErrorAction SilentlyContinue }
  else { $env:PYTHONHASHSEED = $taskOriginalHashSeed }
  Pop-Location
}
