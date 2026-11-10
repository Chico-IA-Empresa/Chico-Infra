variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Explicit target account required."
  }
}
variable "ami_id" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "rds_security_group_id" { type = string }
variable "key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:sa-east-1:${var.account_id}:key/[a-zA-Z0-9-]+$", var.key_arn))
    error_message = "Only the target account's explicit Prod CMK is allowed."
  }
}
variable "proof_access_enabled" {
  type    = bool
  default = false
}
variable "proof_security_group_id" {
  type    = string
  default = null
  validation {
    condition     = !var.proof_access_enabled || try(startswith(var.proof_security_group_id, "sg-"), false)
    error_message = "Separate proof SG required when proof access is enabled."
  }
}
variable "master_secret_arns" {
  type = set(string)
  validation {
    condition = length(var.master_secret_arns) >= 1 && length(var.master_secret_arns) <= 2 && alltrue([
      for arn in var.master_secret_arns : startswith(arn, "arn:aws:secretsmanager:sa-east-1:${var.account_id}:secret:rds!")
    ])
    error_message = "Only the managed master secrets of target and optional proof RDS are allowed."
  }
}
variable "dump" {
  description = "Exact logical dump selected after recovery, never a physical repository or latest key."
  type        = object({ bucket = string, key = string, version_id = string, sha256 = string })
  validation {
    condition = (var.dump.bucket == "chico-prod-recovery-${var.account_id}-sa-east-1" &&
      can(regex("^imports/[A-Za-z0-9_-]+/database[.]dump$", var.dump.key)) &&
      try(length(var.dump.version_id) > 0 && var.dump.version_id != "null", false) &&
    can(regex("^[a-f0-9]{64}$", var.dump.sha256)))
    error_message = "Pin bucket, reviewed import path, non-null VersionId and SHA256 of the logical dump."
  }
}
variable "toolchain_digest" {
  type = string
  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.toolchain_digest))
    error_message = "Reviewed immutable toolchain digest required."
  }
}
variable "not_before_utc" { type = string }
variable "expires_at_utc" {
  type = string
  validation {
    condition = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.expires_at_utc)) && try(
      timecmp(var.expires_at_utc, var.not_before_utc) > 0 && timecmp(var.expires_at_utc, timeadd(var.not_before_utc, "48h")) <= 0, false
    )
    error_message = "Explicit UTC lease of at most 48 hours required."
  }
}
variable "volume_gib" {
  type    = number
  default = 40
  validation {
    condition     = var.volume_gib >= 40 && var.volume_gib <= 160 && floor(var.volume_gib) == var.volume_gib
    error_message = "Review actual dump/workspace against a 40-160 GiB integer allocation."
  }
}
locals {
  lease = {
    DateGreaterThanEquals = { "aws:CurrentTime" = var.not_before_utc }
    DateLessThan          = { "aws:CurrentTime" = var.expires_at_utc }
    StringEquals          = { "aws:RequestedRegion" = "sa-east-1" }
  }
  repository = "arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-workers"
  log_group  = "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/chico/prod/rds-importer"
  policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyBeforeLease"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { DateLessThan = { "aws:CurrentTime" = var.not_before_utc } }
      },
      {
        Sid       = "DenyAfterLease"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { DateGreaterThanEquals = { "aws:CurrentTime" = var.expires_at_utc } }
      },
      {
        Sid       = "SSMAgentChannels"
        Effect    = "Allow"
        Action    = ["ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
        Resource  = "*"
        Condition = local.lease
      },
      {
        Sid       = "ReadOneDumpVersion"
        Effect    = "Allow"
        Action    = ["s3:GetObjectVersion"]
        Resource  = "arn:aws:s3:::${var.dump.bucket}/${var.dump.key}"
        Condition = merge(local.lease, { StringEquals = merge(local.lease.StringEquals, { "s3:VersionId" = var.dump.version_id }) })
      },
      {
        Sid       = "ResolveOnlyManagedDatabaseCredentials"
        Effect    = "Allow"
        Action    = ["secretsmanager:GetSecretValue"]
        Resource  = sort(tolist(var.master_secret_arns))
        Condition = local.lease
      },
      {
        Sid       = "DecryptOnlyProdKeyThroughDataServices"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:DescribeKey"]
        Resource  = var.key_arn
        Condition = merge(local.lease, { StringEquals = merge(local.lease.StringEquals, { "kms:ViaService" = ["secretsmanager.sa-east-1.amazonaws.com", "s3.sa-east-1.amazonaws.com"] }) })
      },
      {
        Sid       = "EcrAuthorization"
        Effect    = "Allow"
        Action    = ["ecr:GetAuthorizationToken"]
        Resource  = "*"
        Condition = local.lease
      },
      {
        Sid       = "ReadOnlyReviewedToolchainRepository"
        Effect    = "Allow"
        Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource  = local.repository
        Condition = local.lease
      },
      {
        Sid       = "WriteOnlyImporterCommandOutput"
        Effect    = "Allow"
        Action    = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource  = "${local.log_group}:*"
        Condition = local.lease
      },
    ]
  }
}
data "aws_ami" "selected" {
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}
data "aws_subnet" "selected" { id = var.subnet_id }
resource "aws_iam_policy" "boundary" {
  name   = "chico-prod-rds-importer-boundary"
  path   = "/chico/prod/"
  policy = jsonencode(local.policy)
  lifecycle {
    precondition {
      condition     = length(jsonencode(local.policy)) <= 6144
      error_message = "Do not create an importer boundary exceeding IAM policy size limits."
    }
  }
}
resource "aws_iam_role" "this" {
  name                 = "chico-prod-rds-importer"
  path                 = "/chico/prod/"
  permissions_boundary = aws_iam_policy.boundary.arn
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "this" {
  name   = "reviewed-import-only"
  role   = aws_iam_role.this.id
  policy = jsonencode(local.policy)
}
resource "aws_iam_instance_profile" "this" {
  name = "chico-prod-rds-importer"
  path = "/chico/prod/"
  role = aws_iam_role.this.name
}
resource "aws_security_group" "this" {
  name        = "chico-prod-rds-importer"
  description = "Temporary SQL importer; no inbound network access"
  vpc_id      = var.vpc_id
  ingress     = []
  egress      = []
}
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "SSM, versioned S3, ECR and reviewed OS packages over TLS"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
resource "aws_vpc_security_group_egress_rule" "postgres" {
  security_group_id            = aws_security_group.this.id
  description                  = "SQL only to reviewed Prod RDS security group"
  referenced_security_group_id = var.rds_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id            = var.rds_security_group_id
  description                  = "Temporary importer; remove after proof and review"
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_cloudwatch_log_group" "commands" {
  name              = "/chico/prod/rds-importer"
  kms_key_id        = var.key_arn
  retention_in_days = 30
}
resource "aws_vpc_security_group_egress_rule" "proof" {
  count                        = var.proof_access_enabled ? 1 : 0
  security_group_id            = aws_security_group.this.id
  description                  = "Temporary SQL access only to independent proof instance"
  referenced_security_group_id = var.proof_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_vpc_security_group_ingress_rule" "proof" {
  count                        = var.proof_access_enabled ? 1 : 0
  security_group_id            = var.proof_security_group_id
  description                  = "Proof accepts only the temporary importer, never application SGs"
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_instance" "this" {
  ami                                  = var.ami_id
  instance_type                        = "t3.medium"
  subnet_id                            = var.subnet_id
  vpc_security_group_ids               = [aws_security_group.this.id]
  associate_public_ip_address          = true
  instance_initiated_shutdown_behavior = "stop"
  iam_instance_profile                 = aws_iam_instance_profile.this.name
  disable_api_termination              = true
  monitoring                           = true
  ebs_optimized                        = true
  user_data_replace_on_change          = false
  user_data                            = join("\n", ["#!/bin/bash", "export CHICO_IMPORT_EXPIRES_UTC='${var.expires_at_utc}'", file("${path.module}/bootstrap.sh")])
  credit_specification { cpu_credits = "standard" }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.volume_gib
    encrypted             = true
    kms_key_id            = var.key_arn
    delete_on_termination = false
  }
  tags = { Name = "chico-prod-rds-importer", purpose = "rds-import", "expires-at-utc" = var.expires_at_utc }
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = data.aws_ami.selected.architecture == "x86_64" && data.aws_ami.selected.state == "available" && startswith(data.aws_ami.selected.name, "al2023-ami-") && length(data.aws_ami.selected.product_codes) == 0 && data.aws_subnet.selected.vpc_id == var.vpc_id
      error_message = "Reviewed available x86 AMI and subnet in the target VPC required."
    }
    precondition {
      condition     = timecmp(var.not_before_utc, plantimestamp()) <= 0 && timecmp(var.expires_at_utc, plantimestamp()) > 0
      error_message = "Plan must be inside the fixed reviewed lease; do not extend a populated host silently."
    }
  }
  depends_on = [aws_iam_role_policy.this, aws_cloudwatch_log_group.commands]
}
output "instance_id" { value = aws_instance.this.id }
output "security_group_id" { value = aws_security_group.this.id }
output "toolchain_image" { value = "${var.account_id}.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@${var.toolchain_digest}" }
output "reviewed_dump" { value = var.dump }
