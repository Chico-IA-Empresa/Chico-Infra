mock_provider "aws" {
  override_during = plan
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:sa-east-1:123456789012:log-group:/chico/shared/audit" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:sa-east-1:123456789012:chico-shared-audit-events" }
  }
}
variables {
  bucket_name            = "synthetic-audit"
  access_log_bucket_name = "synthetic-audit-access"
  account_id             = "123456789012"
  kms_key_arn            = "arn:aws:kms:sa-east-1:123456789012:key/synthetic-test"
}
run "encrypted_audit_delivery" {
  command = plan
  assert {
    condition     = aws_cloudtrail.audit.cloud_watch_logs_group_arn == "arn:aws:logs:sa-east-1:123456789012:log-group:/chico/shared/audit:*" && aws_cloudtrail.audit.sns_topic_name == "arn:aws:sns:sa-east-1:123456789012:chico-shared-audit-events"
    error_message = "Trail deve integrar CloudWatch e SNS explicitamente."
  }
  assert {
    condition     = aws_cloudwatch_log_group.audit.kms_key_id == var.kms_key_arn && aws_sns_topic.audit.kms_master_key_id == var.kms_key_arn && aws_cloudtrail.audit.is_multi_region_trail && aws_cloudtrail.audit.enable_log_file_validation
    error_message = "Criptografia e auditoria multi-region devem ser preservadas."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.delivery.policy).Statement[0].Resource == "arn:aws:logs:sa-east-1:123456789012:log-group:/chico/shared/audit:log-stream:123456789012_CloudTrail_*" && jsondecode(aws_sns_topic_policy.audit.policy).Statement[0].Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:sa-east-1:123456789012:trail/chico-audit"
    error_message = "Permissões de delivery devem limitar streams e origem do trail."
  }
}
run "reject_recursive_access_logs" {
  command = plan
  variables { access_log_bucket_name = "synthetic-audit" }
  expect_failures = [aws_s3_bucket_logging.audit]
}
