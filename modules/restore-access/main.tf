variable "enabled" {
  type    = bool
  default = false
}
variable "account_id" {
  type = string
  validation {
    condition     = var.account_id == "306915830875"
    error_message = "Restore desta fase pertence somente ÃƒÂ  conta aprovada."
  }
}
variable "source_manifest_sha256" {
  type = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.source_manifest_sha256))
    error_message = "SHA256 do manifesto privado fixado obrigatÃƒÂ³rio."
  }
}
variable "source_list_prefixes" {
  type = list(string)
  validation {
    condition     = length(var.source_list_prefixes) > 0 && length(distinct(var.source_list_prefixes)) == length(var.source_list_prefixes) && alltrue([for p in var.source_list_prefixes : startswith(p, "pgbackrest/sofascore-postgres/") && p != "pgbackrest/sofascore-postgres/" && !strcontains(p, "*") && !strcontains(p, "?") && !strcontains(p, "..")])
    error_message = "Listagem somente dos prefixos exatos e necessÃƒÂ¡rios do conjunto fixado."
  }
}
variable "source_version_policy_documents" {
  type = list(string)
  validation {
    condition = (!var.enabled || length(var.source_version_policy_documents) > 0) && length(var.source_version_policy_documents) <= 9 && alltrue([for p in var.source_version_policy_documents : length(p) <= 6000 && try(
      jsondecode(p).Version == "2012-10-17" && length(jsondecode(p).Statement) > 0 &&
      length(setsubtract(toset(keys(jsondecode(p))), toset(["Version", "Statement"]))) == 0 &&
      alltrue([for s in jsondecode(p).Statement :
        length(setsubtract(toset(keys(s)), toset(["Effect", "Action", "Resource", "Condition"]))) == 0 &&
        s.Effect == "Allow" && s.Action == ["s3:GetObjectVersion"] &&
        can(regex("^arn:aws:s3:::chico-backup/pgbackrest/sofascore-postgres/[^*?]+$", s.Resource)) && !strcontains(s.Resource, "..") &&
        keys(s.Condition) == ["StringEquals"] && keys(s.Condition.StringEquals) == ["s3:VersionId"] &&
        can(regex("^\\S+$", s.Condition.StringEquals["s3:VersionId"])) && tostring(s.Condition.StringEquals["s3:VersionId"]) == s.Condition.StringEquals["s3:VersionId"] && s.Condition.StringEquals["s3:VersionId"] != "null"
      ]), false
    )])
    error_message = "AtÃƒÂ© nove policies de 6000 caracteres, somente GetObjectVersion com cada key/VersionId exatos. Sem GetObject, wildcards, grants extras ou NotAction."
  }
}
variable "destination_bucket_name" {
  type = string
  validation {
    condition     = can(regex("^chico-dev-[a-z0-9-]{3,50}$", var.destination_bucket_name)) && var.destination_bucket_name != "chico-backup"
    error_message = "Destino deve ser o bucket Dev prÃƒÂ³prio reconciliado."
  }
}
variable "import_id" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$", var.import_id))
    error_message = "Identificador fixado da conversÃƒÂ£o, sem caminho ou wildcard."
  }
}
variable "not_before_utc" { type = string }
variable "expires_at_utc" {
  type = string
  validation {
    condition     = try(timecmp(var.expires_at_utc, var.not_before_utc) > 0 && timecmp(var.expires_at_utc, timeadd(var.not_before_utc, "48h")) <= 0, false)
    error_message = "Janela UTC explÃƒÂ­cita, positiva e de no mÃƒÂ¡ximo 48h; renovaÃƒÂ§ÃƒÂ£o exige outro lote revisado."
  }
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
locals {
  toolchain_repository = "arn:aws:ecr:sa-east-1:306915830875:repository/chico-workers"
  toolchain_lease_condition = {
    StringEquals          = { "aws:RequestedRegion" = "sa-east-1" }
    DateGreaterThanEquals = { "aws:CurrentTime" = var.not_before_utc }
    DateLessThan          = { "aws:CurrentTime" = var.expires_at_utc }
  }
  toolchain_pull_statements = [for statement in [
    { Sid = "ReviewedToolchainToken", Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*", Condition = local.toolchain_lease_condition },
    { Sid = "ReviewedToolchainRepository", Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = local.toolchain_repository, Condition = local.toolchain_lease_condition }
  ] : statement if var.toolchain_delivery != null]
  toolchain_pull_guards = [for statement in [
    { Sid = "NoToolchainPullBeforeLease", Effect = "Deny", Action = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = "*", Condition = { DateLessThan = { "aws:CurrentTime" = var.not_before_utc } } },
    { Sid = "NoToolchainPullAfterLease", Effect = "Deny", Action = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = "*", Condition = { DateGreaterThanEquals = { "aws:CurrentTime" = var.expires_at_utc } } },
    { Sid = "NoForeignToolchainRepository", Effect = "Deny", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], NotResource = local.toolchain_repository }
  ] : statement if var.toolchain_delivery != null]
  source_bucket = "arn:aws:s3:::chico-backup"
  destination   = "arn:aws:s3:::${var.destination_bucket_name}"
  region        = { StringEquals = { "aws:RequestedRegion" = "sa-east-1" } }
  agent_actions = [
    "ssm:DescribeAssociation", "ssm:GetDeployablePatchSnapshotForInstance", "ssm:GetDocument", "ssm:DescribeDocument", "ssm:GetManifest", "ssm:ListAssociations", "ssm:ListInstanceAssociations", "ssm:PutInventory", "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult", "ssm:UpdateAssociationStatus", "ssm:UpdateInstanceAssociationStatus", "ssm:UpdateInstanceInformation",
    "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel", "ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage", "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:SendReply"
  ]
  support_statements = concat([
    { Sid = "AgentCore", Effect = "Allow", Action = local.agent_actions, Resource = "*", Condition = local.region },
    { Sid = "SessionLogs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"], Resource = "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/chico/dev/ssm:*", Condition = local.region },
    # Run Command's agent discovers the pre-existing output group. This action
    # cannot be scoped to its ARN; regional metadata visibility needs review.
    { Sid = "SessionLogGroupDiscovery", Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*", Condition = local.region },
    { Sid = "SourceLocation", Effect = "Allow", Action = ["s3:GetBucketLocation"], Resource = local.source_bucket },
    { Sid = "SelectedSourceListing", Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.source_bucket, Condition = { StringEquals = { "s3:prefix" = var.source_list_prefixes } } },
    { Sid = "OwnDevBackupListing", Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.destination, Condition = { StringLike = { "s3:prefix" = ["dev/database/", "dev/database/*"] } } },
    { Sid = "OwnDevBackupReads", Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = "${local.destination}/dev/database/*" },
    { Sid = "ConversionOutputOnly", Effect = "Allow", Action = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = "${local.destination}/dev/database/import/${var.import_id}/*" }
  ], local.toolchain_pull_statements)
  guard_statements = concat([
    { Sid = "NeverChangeLegacySource", Effect = "Deny", NotAction = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObjectVersion"], Resource = [local.source_bucket, "${local.source_bucket}/*"] },
    { Sid = "NoDataAccessBeforeLease", Effect = "Deny", Action = ["s3:*"], Resource = [local.source_bucket, "${local.source_bucket}/*", local.destination, "${local.destination}/*"], Condition = { DateLessThan = { "aws:CurrentTime" = var.not_before_utc } } },
    { Sid = "NoDataAccessAfterLease", Effect = "Deny", Action = ["s3:*"], Resource = [local.source_bucket, "${local.source_bucket}/*", local.destination, "${local.destination}/*"], Condition = { DateGreaterThanEquals = { "aws:CurrentTime" = var.expires_at_utc } } },
    { Sid = "RequireTLS", Effect = "Deny", Action = ["s3:*"], Resource = [local.source_bucket, "${local.source_bucket}/*", local.destination, "${local.destination}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ], local.toolchain_pull_guards)
}
resource "aws_iam_policy" "boundary" {
  count = var.enabled ? 1 : 0
  name  = "chico-dev-restore-boundary"
  path  = "/chico/restore/"
  # The boundary supplies a ceiling, not a source grant. Exact key/version
  # permissions below must also allow the request. No IAM or source writes.
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(local.support_statements, local.guard_statements, [{
    Sid = "VersionReadCeiling", Effect = "Allow", Action = ["s3:GetObjectVersion"], Resource = "${local.source_bucket}/pgbackrest/sofascore-postgres/*"
  }]) })
  lifecycle {
    precondition {
      condition     = length(jsonencode({ Version = "2012-10-17", Statement = concat(local.support_statements, local.guard_statements, [{ Sid = "VersionReadCeiling", Effect = "Allow", Action = ["s3:GetObjectVersion"], Resource = "${local.source_bucket}/pgbackrest/sofascore-postgres/*" }]) })) <= 6144
      error_message = "Boundary de restore deve caber na quota IAM antes de qualquer criaÃƒÂ§ÃƒÂ£o."
    }
  }
}
resource "aws_iam_role" "restore" {
  count                = var.enabled ? 1 : 0
  name                 = "chico-dev-restore"
  path                 = "/chico/restore/"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.boundary[0].arn
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
  tags = { "source-manifest-sha256" = var.source_manifest_sha256 }
}
resource "aws_iam_role_policy" "support" {
  count  = var.enabled ? 1 : 0
  name   = "selected-restore-support-and-expiry"
  role   = aws_iam_role.restore[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(local.support_statements, local.guard_statements) })
}
resource "aws_iam_policy" "source_version" {
  for_each = var.enabled ? { for index, document in var.source_version_policy_documents : tostring(index) => document } : {}
  name     = "chico-dev-restore-source-${each.key}"
  path     = "/chico/restore/"
  policy   = each.value
}
resource "aws_iam_role_policy_attachment" "source_version" {
  for_each   = aws_iam_policy.source_version
  role       = aws_iam_role.restore[0].name
  policy_arn = each.value.arn
}
resource "aws_iam_instance_profile" "restore" {
  count = var.enabled ? 1 : 0
  name  = "chico-dev-restore"
  path  = "/chico/restore/"
  role  = aws_iam_role.restore[0].name
}
output "access" {
  value = var.enabled ? {
    role_arn       = aws_iam_role.restore[0].arn, instance_profile_name = aws_iam_instance_profile.restore[0].name,
    boundary_arn   = aws_iam_policy.boundary[0].arn, source_manifest_sha256 = var.source_manifest_sha256,
    not_before_utc = var.not_before_utc, expires_at_utc = var.expires_at_utc, toolchain_delivery = var.toolchain_delivery
  } : null
}
