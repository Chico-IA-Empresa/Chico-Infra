param([ValidatePattern('^package-[0-9]{8}-[a-z0-9-]+$')][string]$RunId = 'package-20261026-run4',
      [ValidatePattern('^chico-package-[a-z0-9-]+$')][string]$Project = 'chico-package-20261026-b')
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/../..").Path.Replace('\','/')
$arguments = @('run','--rm','--platform','linux/arm64','--network',"${Project}_isolated",
 '-e','CHICO_CONSUMER=seed','-e','CHICO_CONFIG_FILE=/run/secrets/config',
 '--mount',"type=bind,source=/srv/chico/fixture/$RunId/config/seed.json,target=/run/secrets/config,readonly",
 '--mount',"type=bind,source=$workspace/chico-infra/scripts/package-pytest-runner.py,target=/checks/runner.py,readonly",
 '--mount','type=bind,source=/srv/chico/fixture/package-20261026-run2/test-wheels,target=/checks/wheels,readonly',
 '--mount',"type=bind,source=$workspace/chico-infra/tests/package-pg16/conftest.py,target=/suite/conftest.py,readonly")
$tests = @('unit/workers/test_worker_odds_bsd_cycle.py','unit/workers/test_worker_odds_surebetting_cycle.py',
 'unit/workers/test_sofascore_production_workers.py','test_worker_league_reports.py','test_worker_match_analysis.py',
 'unit/services/test_sofascore_production_orchestrator.py','unit/services/test_sofascore_staging_pipeline.py',
 'unit/services/test_sofascore_materialization_service.py')
foreach ($test in $tests) {
 $name = Split-Path $test -Leaf
 $arguments += @('--mount',"type=bind,source=$workspace/backend/tests/$test,target=/suite/$name,readonly")
}
$arguments += @('--entrypoint','python','chico-workers:local-fixture','/checks/runner.py')
& docker @arguments
if ($LASTEXITCODE) { throw 'Worker PG16 fixture suite failed' }
