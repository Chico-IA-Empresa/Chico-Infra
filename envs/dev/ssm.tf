resource "aws_ssm_document" "fixture_status" {
  count           = local.host_enabled ? 1 : 0
  name            = "chico-dev-fixture-status"
  document_type   = "Command"
  document_format = "JSON"
  content         = jsonencode({ schemaVersion = "2.2", description = "Read-only fixed synthetic fixture status; no caller shell parameters", mainSteps = [{ action = "aws:runShellScript", name = "fixtureStatus", inputs = { timeoutSeconds = "60", runCommand = ["set -eu", "systemctl is-active docker amazon-ssm-agent", "docker compose -p chico-dev-fixture -f /opt/chico-dev-fixture/compose.yaml ps --status running --services"] } }] })
  depends_on      = [module.funding]
}
resource "aws_ssm_document" "session" {
  count           = local.host_enabled ? 1 : 0
  name            = "chico-dev-session"
  document_type   = "Session"
  document_format = "JSON"
  content         = jsonencode({ schemaVersion = "1.0", description = "Dev operator session with encrypted logs; explicitly select this document", sessionType = "Standard_Stream", inputs = { cloudWatchLogGroupName = "/chico/dev/ssm", cloudWatchEncryptionEnabled = true, cloudWatchStreamingEnabled = true, runAsEnabled = false, idleSessionTimeout = "15", maxSessionDuration = "60" } })
  depends_on      = [aws_cloudwatch_log_group.dev]
}
output "ssm_documents" {
  value = local.host_enabled ? { fixture_status = aws_ssm_document.fixture_status[0].arn, session = aws_ssm_document.session[0].name } : null
}
