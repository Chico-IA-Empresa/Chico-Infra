param([string]$OutputDirectory, [ValidateSet('api','workers','frontend')][string[]]$Targets = @('api','workers','frontend'))
$ErrorActionPreference = 'Stop'
if (!$OutputDirectory -or (Test-Path -LiteralPath $OutputDirectory)) { throw 'Choose a NEW private output directory outside all source contexts' }
$workspace = (Resolve-Path "$PSScriptRoot/../..").Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be outside source contexts' }
New-Item -ItemType Directory -Path $output | Out-Null
$backendSha = git -C "$workspace/backend" rev-parse HEAD
$frontendSha = git -C "$workspace/frontend" rev-parse HEAD
# Source contains local changes: preserve patch hashes alongside base SHAs.
foreach ($repo in @('backend','frontend')) {
    git -C "$workspace/$repo" diff --binary --output="$output/$repo.patch"
    if ($LASTEXITCODE) { throw 'Source diff failed' }
}
foreach ($target in $Targets) {
    $context = if ($target -eq 'frontend') { "$workspace/frontend" } else { "$workspace/backend" }
    $revision = if ($target -eq 'frontend') { $frontendSha } else { $backendSha }
    $arguments = @('buildx','build','--platform','linux/arm64','--provenance=mode=min','--tag',"chico-${target}:local-fixture",'--build-arg',"SOURCE_REVISION=$revision",'--metadata-file',"$output/$target.metadata.json",'--output',"type=oci,dest=$output/$target.oci.tar")
    if ($target -ne 'frontend') { $arguments += @('--target',$target) }
    & docker @arguments $context
    if ($LASTEXITCODE) { throw "Build failed: $target" }
}
Write-Output 'Local OCI builds exported; execution and inspection are still required. No ECR push.'
