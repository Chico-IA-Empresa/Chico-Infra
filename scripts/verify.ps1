param([string]$Terraform = 'terraform', [string]$Tflint = 'tflint', [string]$PluginDirectory)
$ErrorActionPreference = 'Stop'
$taskRepo = Split-Path -Parent $PSScriptRoot
$taskReport = Join-Path $taskRepo 'reports/validation.txt'
$taskLogs = [System.Collections.Generic.List[string]]::new()
function Invoke-TaskTerraform([string]$Directory, [string[]]$Arguments) {
  Push-Location (Join-Path $taskRepo $Directory)
  try {
    $taskOutput = & $Terraform @Arguments 2>&1
    $taskCode = $LASTEXITCODE
    $taskLogs.Add("$Directory terraform $($Arguments -join ' ')`n$taskOutput`nexit=$taskCode")
    Write-Output "$Directory $($Arguments[0]): exit=$taskCode"
    if ($taskCode -ne 0) { throw "Terraform failed in $Directory" }
  } finally { Pop-Location }
}
try {
  Invoke-TaskTerraform '.' @('fmt', '-check', '-recursive')
  $taskRoots = @('bootstrap', 'envs/shared', 'envs/dev', 'envs/uat', 'envs/prod', 'modules/network', 'modules/funding', 'modules/oidc', 'modules/data', 'modules/web-service', 'modules/dev-box', 'modules/schedules', 'modules/budgets', 'modules/audit', 'modules/access-log-sink')
  foreach ($taskDir in $taskRoots) {
    $taskArgs = @('init', '-backend=false', '-input=false', '-no-color', '-lockfile=readonly')
    if ($PluginDirectory) { $taskArgs += "-plugin-dir=$PluginDirectory" }
    Invoke-TaskTerraform $taskDir $taskArgs
    Invoke-TaskTerraform $taskDir @('validate', '-no-color')
  }
  Invoke-TaskTerraform 'envs/dev' @('test', '-no-color')
  Invoke-TaskTerraform 'envs/shared' @('test', '-no-color')
  foreach ($taskModule in @('network', 'funding', 'oidc', 'data', 'schedules', 'web-service', 'dev-box', 'budgets', 'audit', 'access-log-sink')) {
    Invoke-TaskTerraform "modules/$taskModule" @('test', '-no-color')
  }
  Push-Location $taskRepo
  try {
    $taskOutput = & node --test 'tests/*.test.mjs' 2>&1
    $taskCode = $LASTEXITCODE
    $taskLogs.Add("node tests`n$taskOutput`nexit=$taskCode")
    if ($taskCode -ne 0) { throw 'Node tests failed' }
    $taskOutput = & $Tflint --recursive --format compact 2>&1
    $taskCode = $LASTEXITCODE
    $taskLogs.Add("tflint`n$taskOutput`nexit=$taskCode")
    if ($taskCode -ne 0) { throw 'TFLint failed' }
  } finally { Pop-Location }
} finally {
  $taskLogs | Set-Content -LiteralPath $taskReport -Encoding utf8
}
