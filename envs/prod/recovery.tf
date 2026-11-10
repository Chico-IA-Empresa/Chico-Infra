# Every new component defaults off. No source payload or secret value enters state.
variable "managed_data_key_enabled" {
  type    = bool
  default = false
}
variable "recovery_storage_enabled" {
  type    = bool
  default = false
}
variable "importer_enabled" {
  type    = bool
  default = false
}
variable "importer" {
  type = object({
    ami_id           = string
    not_before_utc   = string
    expires_at_utc   = string
    volume_gib       = number
    toolchain_digest = string
    dump             = object({ bucket = string, key = string, version_id = string, sha256 = string })
  })
  default = null
}
variable "recovery_proof_enabled" {
  type    = bool
  default = false
}
variable "validated_snapshot_arn" {
  description = "Snapshot created only after target import and full reconciliation; not the S3 source."
  type        = string
  default     = null
  validation {
    condition     = !var.recovery_proof_enabled || try(startswith(var.validated_snapshot_arn, "arn:aws:rds:sa-east-1:${var.account_id}:snapshot:chico-prod-validated-"), false)
    error_message = "Independent proof requires the exact post-validation Prod RDS snapshot ARN."
  }
}
locals {
  recovery_foundation_enabled = var.managed_data_key_enabled || var.recovery_storage_enabled
  effective_data_key_arn      = var.provision_enabled && local.recovery_foundation_enabled ? module.recovery_foundation[0].key_arn : var.data_key_arn
}
module "recovery_foundation" {
  count            = var.provision_enabled && local.recovery_foundation_enabled ? 1 : 0
  source           = "../../modules/rds-recovery-foundation"
  account_id       = var.account_id
  create_key       = var.managed_data_key_enabled
  external_key_arn = var.data_key_arn
  storage_enabled  = var.recovery_storage_enabled
  bucket_name      = "chico-prod-recovery-${var.account_id}-sa-east-1"
  depends_on       = [module.funding]
}
resource "terraform_data" "recovery_readiness" {
  count = var.provision_enabled && (var.importer_enabled || var.recovery_proof_enabled) ? 1 : 0
  lifecycle {
    precondition {
      condition     = local.rds_enabled
      error_message = "Importer and recovery proof require the managed private RDS target."
    }
    precondition {
      condition     = !var.importer_enabled || (var.importer != null && var.recovery_storage_enabled)
      error_message = "Importer requires reviewed inputs and the dedicated private Prod artifact store."
    }
  }
}
resource "aws_cloudwatch_log_group" "recovery_proof" {
  count             = var.provision_enabled && var.recovery_proof_enabled ? 1 : 0
  name              = "/aws/rds/instance/chico-prod-recovery-proof/postgresql"
  kms_key_id        = local.effective_data_key_arn
  retention_in_days = 30
  depends_on        = [module.funding, terraform_data.recovery_readiness]
}
resource "aws_db_instance" "recovery_proof" {
  count                           = var.provision_enabled && var.recovery_proof_enabled ? 1 : 0
  identifier                      = "chico-prod-recovery-proof"
  engine                          = "postgres"
  engine_version                  = var.postgres_version
  snapshot_identifier             = var.validated_snapshot_arn
  instance_class                  = "db.t4g.medium"
  db_subnet_group_name            = module.data[0].postgres_subnet_group_name
  parameter_group_name            = module.data[0].postgres_parameter_group_name
  vpc_security_group_ids          = [aws_security_group.recovery_proof[0].id]
  availability_zone               = module.network[0].worker_rds_az
  publicly_accessible             = false
  multi_az                        = false
  storage_encrypted               = true
  kms_key_id                      = local.effective_data_key_arn
  manage_master_user_password     = true
  master_user_secret_kms_key_id   = local.effective_data_key_arn
  enabled_cloudwatch_logs_exports = ["postgresql"]
  backup_retention_period         = 1
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = "chico-prod-recovery-proof-final"
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = false
  allow_major_version_upgrade     = false
  apply_immediately               = false
  tags                            = { purpose = "independent-recovery-proof" }
  depends_on                      = [module.funding, terraform_data.recovery_readiness, aws_cloudwatch_log_group.recovery_proof]
  lifecycle { prevent_destroy = true }
}
resource "aws_security_group" "recovery_proof" {
  count       = var.provision_enabled && var.recovery_proof_enabled ? 1 : 0
  name        = "chico-prod-rds-recovery-proof"
  description = "Independent recovery proof; no application or worker ingress"
  vpc_id      = module.network[0].vpc_id
  ingress     = []
  egress      = []
  depends_on  = [module.funding, terraform_data.recovery_readiness]
}
module "rds_importer" {
  count                   = var.provision_enabled && var.importer_enabled ? 1 : 0
  source                  = "../../modules/rds-importer"
  account_id              = var.account_id
  ami_id                  = var.importer.ami_id
  vpc_id                  = module.network[0].vpc_id
  subnet_id               = module.network[0].public_subnet_ids[0]
  rds_security_group_id   = module.network[0].security_group_ids["rds"]
  proof_access_enabled    = var.recovery_proof_enabled
  proof_security_group_id = try(aws_security_group.recovery_proof[0].id, null)
  key_arn                 = local.effective_data_key_arn
  master_secret_arns = concat(
    [module.data[0].postgres_master_secret_arn],
    var.recovery_proof_enabled ? [aws_db_instance.recovery_proof[0].master_user_secret[0].secret_arn] : []
  )
  dump             = var.importer.dump
  toolchain_digest = var.importer.toolchain_digest
  not_before_utc   = var.importer.not_before_utc
  expires_at_utc   = var.importer.expires_at_utc
  volume_gib       = var.importer.volume_gib
  depends_on       = [module.funding, terraform_data.recovery_readiness]
}
output "rds_target" {
  value = var.provision_enabled && local.rds_enabled ? {
    address           = module.data[0].postgres_address
    master_secret_arn = module.data[0].postgres_master_secret_arn
  } : null
}
output "rds_recovery_proof" {
  value = var.provision_enabled && var.recovery_proof_enabled ? {
    address           = aws_db_instance.recovery_proof[0].address
    master_secret_arn = aws_db_instance.recovery_proof[0].master_user_secret[0].secret_arn
  } : null
}
output "rds_importer_instance_id" { value = try(module.rds_importer[0].instance_id, null) }
