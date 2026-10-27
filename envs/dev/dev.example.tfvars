# Template only. Placeholders deliberately fail validation. Never use test approval.
access_log_bucket_name = null # existing Dev sink; policy/retention/cost reviewed with owner
# Save real nonsecret inputs privately as ci.auto.tfvars.json for CI.
account_id                    = "REPLACE_WITH_APPROVED_ACCOUNT"
owner                         = "REPLACE_WITH_OWNER"
cost_center                   = "REPLACE_WITH_COST_CENTER"
az_names                      = ["sa-east-1a"] # verify AZ in the target account
provision_enabled             = false
permissions_boundary_arns     = null # exact shared outputs; required before enabling host
compute_enabled               = false
credit_approval               = null
ami_id                        = null # reviewed Amazon-owned AL2023 ARM64 AMI in sa-east-1
compose_version               = null # exact reviewed vMAJOR.MINOR.PATCH
compose_sha256                = null # official aarch64 release SHA256
repository_arns               = []   # all three shared ECR ARNs after reconciliation
backup_bucket_name            = null # unique chico-dev-* bucket, priced and reviewed
fixture_backup_retention_days = null # explicit priced retention, never assume Prod policy
logs_key_arn                  = null # CMK ownership/policy must be confirmed Dev
alarm_topic_arn               = null # reviewed encrypted SNS topic and confirmed destination
secrets_key_arn               = null # reviewed Dev CMK; required only when secret_names nonempty
secret_names                  = []   # synthetic proof: api/SYNTHETIC_TOKEN, no versions in Terraform
parameters                    = {}   # synthetic proof: api/FIXTURE_MODE = synthetic
dev_hostname                  = null
dns_zone_id                   = null # existing authoritative zone, no delegation change
dns_change_approved           = false
