variable "destination_env" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "prod"], var.destination_env)
    error_message = "Choose Dev compatibility or the separately reviewed Prod RDS export."
  }
}
variable "destination_key_arn" {
  type    = string
  default = null
}
variable "account_id" {
  type = string
  validation {
    condition     = var.account_id == "306915830875"
    error_message = "Conta aprovada da fase 1 obrigatória."
  }
}
variable "owner" { type = string }
variable "cost_center" { type = string }
variable "provision_enabled" {
  type    = bool
  default = false
}
variable "credit_approval" {
  type    = object({ account_id = string, evidence_reference = string, reviewed_on = string, expires_on = string, all_charges_covered = bool, shutdown_reserve_confirmed = bool })
  default = null
}
variable "ami_id" {
  type    = string
  default = null
}
variable "vpc_id" {
  type    = string
  default = null
}
variable "subnet_id" {
  type    = string
  default = null
}
variable "destination_bucket_name" {
  type    = string
  default = null
}
variable "import_id" {
  type    = string
  default = null
}
variable "source_manifest_sha256" {
  type    = string
  default = null
}
variable "source_list_prefixes" {
  type    = list(string)
  default = []
}
variable "source_version_policy_documents" {
  type    = list(string)
  default = []
}
variable "not_before_utc" {
  type    = string
  default = null
}
variable "expires_at_utc" {
  type    = string
  default = null
}
variable "toolchain_delivery" {
  description = "Optional private image-delivery review metadata. No grant unless explicitly supplied; does not approve image use or data handling."
  type        = object({ repository_arn = string, image_digest = string, evidence_reference = string })
  default     = null
  validation {
    condition = var.toolchain_delivery == null || try(
      var.toolchain_delivery.repository_arn == "arn:aws:ecr:sa-east-1:306915830875:repository/chico-workers" &&
      can(regex("^sha256:[a-f0-9]{64}$", var.toolchain_delivery.image_digest)) &&
      length(trimspace(var.toolchain_delivery.evidence_reference)) > 0 &&
      length(var.toolchain_delivery.evidence_reference) <= 200 &&
    !can(regex("[\\r\\n]", var.toolchain_delivery.evidence_reference)), false)
    error_message = "Only reviewed chico-workers digest/evidence metadata is accepted; no tag, foreign repository or empty reference."
  }
}
variable "restore_preflight" {
  description = "Private review metadata, not proof. Full source/cipher/toolchain/capacity evidence and saved-plan approval are retained by the private executor."
  type = object({
    evidence_reference                        = string
    source_manifest_sha256                    = string
    selected_versions_and_metadata_reviewed   = bool
    source_classification_reviewed            = bool
    data_handling_reviewed                    = bool
    capacity_160gib_48h_approved              = bool
    private_cipher_transfer_reviewed          = bool
    toolchain_and_pre_restore_checks_reviewed = bool
    destination_and_dev_ready                 = bool
    rds_export_destination_reviewed           = optional(bool, false)
    no_concurrent_arm_builder                 = bool
    business_writers_disabled                 = bool
  })
  default = null
}
provider "aws" {
  region              = "sa-east-1"
  allowed_account_ids = [var.account_id]
  default_tags {
    tags = { project = "chicoai", env = "restore", purpose = var.destination_env == "prod" ? "rds-restore" : "dev-restore", owner = var.owner, "cost-center" = var.cost_center, "managed-by" = "terraform" }
  }
}
module "funding" {
  source     = "../../../modules/funding"
  enabled    = var.provision_enabled
  account_id = var.account_id
  approval   = var.credit_approval
}
resource "terraform_data" "readiness" {
  input = var.provision_enabled
  lifecycle {
    precondition {
      condition = !var.provision_enabled || try(
        length(trimspace(var.restore_preflight.evidence_reference)) > 0 &&
        var.restore_preflight.source_manifest_sha256 == var.source_manifest_sha256 &&
        var.restore_preflight.selected_versions_and_metadata_reviewed &&
        var.restore_preflight.source_classification_reviewed &&
        var.restore_preflight.data_handling_reviewed &&
        var.restore_preflight.capacity_160gib_48h_approved &&
        var.restore_preflight.private_cipher_transfer_reviewed &&
        var.restore_preflight.toolchain_and_pre_restore_checks_reviewed &&
        (var.destination_env == "prod" ? var.restore_preflight.rds_export_destination_reviewed : var.restore_preflight.destination_and_dev_ready) &&
        var.restore_preflight.no_concurrent_arm_builder &&
        var.restore_preflight.business_writers_disabled &&
        timecmp(var.not_before_utc, plantimestamp()) <= 0 &&
        timecmp(var.expires_at_utc, plantimestamp()) > 0 &&
        timecmp(var.expires_at_utc, "${var.credit_approval.expires_on}T00:00:00Z") <= 0,
      false)
      error_message = "Staging exige lease atual e revisão privada real de seleção, capacidade, cipher, toolchain, destino e isolamento. Não preencher com fixture."
    }
  }
}
module "access" {
  count                           = var.provision_enabled ? 1 : 0
  source                          = "../../../modules/restore-access"
  enabled                         = true
  account_id                      = var.account_id
  source_manifest_sha256          = var.source_manifest_sha256
  source_list_prefixes            = var.source_list_prefixes
  source_version_policy_documents = var.source_version_policy_documents
  destination_bucket_name         = var.destination_bucket_name
  destination_env                 = var.destination_env
  destination_key_arn             = var.destination_key_arn
  import_id                       = var.import_id
  toolchain_delivery              = var.toolchain_delivery
  not_before_utc                  = var.not_before_utc
  expires_at_utc                  = var.expires_at_utc
  depends_on                      = [module.funding, terraform_data.readiness]
}
module "host" {
  count                 = var.provision_enabled ? 1 : 0
  source                = "../../../modules/restore-staging"
  enabled               = true
  ami_id                = var.ami_id
  vpc_id                = var.vpc_id
  subnet_id             = var.subnet_id
  instance_profile_name = module.access[0].access.instance_profile_name
  not_before_utc        = var.not_before_utc
  expires_at_utc        = var.expires_at_utc
  depends_on            = [module.access]
}
output "staging" {
  value = var.provision_enabled ? { host = module.host[0].host, access = module.access[0].access } : null
}

output "conversion_destination" {
  value = var.provision_enabled ? {
    environment                      = var.destination_env
    bucket                           = var.destination_bucket_name
    prefix                           = var.destination_env == "prod" ? "imports/${var.import_id}/" : "dev/database/import/${var.import_id}/"
    rds_import_and_validation_proven = false
  } : null
}
