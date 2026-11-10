mock_provider "aws" {
  override_during = plan
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::306915830875:policy/chico/restore/synthetic-only" }
  }
}
variables {
  account_id              = "306915830875"
  source_manifest_sha256  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  source_list_prefixes    = ["pgbackrest/sofascore-postgres/backup/main/backup.info"]
  destination_bucket_name = "chico-dev-synthetic-backup"
  import_id               = "synthetic-only"
  not_before_utc          = "2026-01-01T00:00:00Z"
  expires_at_utc          = "2026-01-03T00:00:00Z"
  source_version_policy_documents = [jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = ["s3:GetObjectVersion"], Resource = "arn:aws:s3:::chico-backup/pgbackrest/sofascore-postgres/backup/main/backup.info",
    Condition = { StringEquals = { "s3:VersionId" = "synthetic-version-only" } }
  }] })]
}
run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_role.restore) == 0 && length(aws_iam_policy.source_version) == 0 && length(aws_iam_policy.boundary) == 0
    error_message = "Preparação de código não pode habilitar acesso legado."
  }
}
run "version_grants_require_boundary_and_source_expiry" {
  command = plan
  variables { enabled = true }
  assert {
    condition     = aws_iam_role.restore[0].permissions_boundary == aws_iam_policy.boundary[0].arn && aws_iam_instance_profile.restore[0].role == aws_iam_role.restore[0].name && length(aws_iam_role_policy_attachment.source_version) == 1
    error_message = "Role separada precisa de boundary e profile próprios."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement : s if s.Sid == "NeverChangeLegacySource"]).NotAction == ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObjectVersion"]
    error_message = "Acesso de source deve negar mutações e leitura sem VersionId, mesmo se outro grant for adicionado."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement : s if s.Sid == "NoDataAccessBeforeLease"]).Condition.DateLessThan["aws:CurrentTime"] == var.not_before_utc && one([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement : s if s.Sid == "NoDataAccessAfterLease"]).Condition.DateGreaterThanEquals["aws:CurrentTime"] == var.expires_at_utc
    error_message = "Janela deve negar leitura antes do início e a partir do vencimento."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement : s if s.Sid == "ConversionOutputOnly"]).Resource == "arn:aws:s3:::chico-dev-synthetic-backup/dev/database/import/synthetic-only/*" && alltrue([for s in local.support_statements : alltrue([for action in s.Action : !startswith(action, "iam:") && action != "ssm:SendCommand" && action != "s3:DeleteObject"])])
    error_message = "Escrita só no prefixo de conversão Dev, sem IAM, execução arbitrária ou exclusão S3."
  }
}
run "ssm_group_discovery_is_regional_and_present_in_both_layers" {
  command = plan
  variables { enabled = true }
  assert {
    condition = alltrue([for doc in [aws_iam_role_policy.support[0].policy, aws_iam_policy.boundary[0].policy] :
      one([for s in jsondecode(doc).Statement : s if s.Sid == "SessionLogGroupDiscovery"]).Action == ["logs:DescribeLogGroups"] &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "SessionLogGroupDiscovery"]).Resource == "*" &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "SessionLogGroupDiscovery"]).Condition.StringEquals["aws:RequestedRegion"] == "sa-east-1"
    ])
    error_message = "SSM discovery deve existir na inline e boundary, só DescribeLogGroups em sa-east-1; o risco de metadata requer revisão humana."
  }
}
run "reject_current_object_and_unpinned_grant" {
  command = plan
  variables {
    enabled = true
    source_version_policy_documents = [jsonencode({ Version = "2012-10-17", Statement = [{
      Effect = "Allow", Action = ["s3:GetObject"], Resource = "arn:aws:s3:::chico-backup/pgbackrest/sofascore-postgres/*"
    }] })]
  }
  expect_failures = [var.source_version_policy_documents]
}
run "reject_window_longer_than_48_hours" {
  command = plan
  variables { expires_at_utc = "2026-01-03T00:00:01Z" }
  expect_failures = [var.expires_at_utc]
}
run "reject_repository_wide_listing" {
  command = plan
  variables { source_list_prefixes = ["pgbackrest/sofascore-postgres/"] }
  expect_failures = [var.source_list_prefixes]
}

run "no_ecr_without_delivery_metadata" {
  command = plan
  variables { enabled = true }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement :
      alltrue([for action in try(s.Action, []) : !startswith(action, "ecr:")])
    ])
    error_message = "Default preparation must not grant ECR access."
  }
}
run "reviewed_repository_pull_is_in_both_layers_and_lease_bound" {
  command = plan
  variables {
    enabled = true
    toolchain_delivery = {
      repository_arn     = "arn:aws:ecr:sa-east-1:306915830875:repository/chico-workers"
      image_digest       = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      evidence_reference = "synthetic-private-review-only"
    }
  }
  assert {
    condition = alltrue([for doc in [aws_iam_role_policy.support[0].policy, aws_iam_policy.boundary[0].policy] :
      one([for s in jsondecode(doc).Statement : s if s.Sid == "ReviewedToolchainRepository"]).Action == ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"] &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "ReviewedToolchainRepository"]).Resource == var.toolchain_delivery.repository_arn &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "ReviewedToolchainToken"]).Action == ["ecr:GetAuthorizationToken"] &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "ReviewedToolchainToken"]).Resource == "*" &&
      alltrue([for s in jsondecode(doc).Statement :
        try(s.Condition.StringEquals["aws:RequestedRegion"] == "sa-east-1" && s.Condition.DateGreaterThanEquals["aws:CurrentTime"] == var.not_before_utc && s.Condition.DateLessThan["aws:CurrentTime"] == var.expires_at_utc, false)
        if startswith(s.Sid, "ReviewedToolchain")
      ]) &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "NoToolchainPullBeforeLease"]).Condition.DateLessThan["aws:CurrentTime"] == var.not_before_utc &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "NoToolchainPullAfterLease"]).Condition.DateGreaterThanEquals["aws:CurrentTime"] == var.expires_at_utc &&
      one([for s in jsondecode(doc).Statement : s if s.Sid == "NoForeignToolchainRepository"]).NotResource == var.toolchain_delivery.repository_arn &&
      alltrue([for s in jsondecode(doc).Statement : alltrue([for action in try(s.Action, []) : !startswith(action, "ecr:") || contains(["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], action)])])
    ])
    error_message = "Both permission layers must bind read-only ECR access to one repository/region and both lease bounds."
  }
  assert {
    condition     = length(aws_iam_policy.source_version) == 1 && length(jsondecode(aws_iam_policy.boundary[0].policy).Statement) > 0 && length(aws_iam_policy.boundary[0].policy) <= 6144
    error_message = "Source grant partitioning and IAM boundary quota must remain valid."
  }
}
run "reject_foreign_image_repository" {
  command = plan
  variables {
    enabled = true
    toolchain_delivery = {
      repository_arn     = "arn:aws:ecr:sa-east-1:306915830875:repository/foreign"
      image_digest       = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      evidence_reference = "synthetic-only"
    }
  }
  expect_failures = [var.toolchain_delivery]
}
run "reject_image_tag_instead_of_digest" {
  command = plan
  variables {
    enabled = true
    toolchain_delivery = {
      repository_arn     = "arn:aws:ecr:sa-east-1:306915830875:repository/chico-workers"
      image_digest       = "latest"
      evidence_reference = "synthetic-only"
    }
  }
  expect_failures = [var.toolchain_delivery]
}

run "prod_export_is_scoped_and_encrypted" {
  command = plan
  variables {
    enabled                 = true
    destination_env         = "prod"
    destination_bucket_name = "chico-prod-recovery-306915830875-sa-east-1"
    destination_key_arn     = "arn:aws:kms:sa-east-1:306915830875:key/11111111-1111-1111-1111-111111111111"
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement : s if s.Sid == "ConversionOutputOnly"]).Resource == "arn:aws:s3:::chico-prod-recovery-306915830875-sa-east-1/imports/synthetic-only/*" && length([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement : s if startswith(s.Sid, "OwnDev")]) == 0
    error_message = "Prod output must never grant reads of Dev backups or write a Dev path."
  }
  assert {
    condition = alltrue([for document in [aws_iam_policy.boundary[0].policy, aws_iam_role_policy.support[0].policy] :
      one([for s in jsondecode(document).Statement : s if s.Sid == "EncryptOwnProdExport"]).Condition.StringEquals["kms:ViaService"] == "s3.sa-east-1.amazonaws.com" &&
      one([for s in jsondecode(document).Statement : s if s.Sid == "EncryptOwnProdExport"]).Condition.StringEquals["kms:EncryptionContext:aws:s3:arn"] == "arn:aws:s3:::chico-prod-recovery-306915830875-sa-east-1" &&
      one([for s in jsondecode(document).Statement : s if s.Sid == "EncryptOwnProdExport"]).Condition.DateLessThan["aws:CurrentTime"] == var.expires_at_utc
    ])
    error_message = "KMS access must be only through S3 for the exact Prod bucket and fixed lease in both layers."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.support[0].policy, "\"Condition\":null") && !strcontains(aws_iam_policy.boundary[0].policy, "\"Condition\":null")
    error_message = "Do not emit null IAM condition maps by unifying heterogeneous statements."
  }
}
run "prod_requires_explicit_cmk" {
  command = plan
  variables {
    enabled                 = true
    destination_env         = "prod"
    destination_bucket_name = "chico-prod-recovery-306915830875-sa-east-1"
  }
  expect_failures = [var.destination_key_arn]
}
run "prod_rejects_dev_bucket" {
  command = plan
  variables {
    enabled             = true
    destination_env     = "prod"
    destination_key_arn = "arn:aws:kms:sa-east-1:306915830875:key/11111111-1111-1111-1111-111111111111"
  }
  expect_failures = [var.destination_bucket_name]
}
run "dev_does_not_gain_prod_access_by_default" {
  command = plan
  variables { enabled = true }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.support[0].policy).Statement : s if s.Sid == "EncryptOwnProdExport" || s.Sid == "ReadOwnVersionedExport"]) == 0
    error_message = "The default Dev module must not gain Prod permissions."
  }
}

run "prod_export_and_pinned_ecr_delivery_fit_boundary" {
  command = plan
  variables {
    enabled                 = true
    destination_env         = "prod"
    destination_bucket_name = "chico-prod-recovery-306915830875-sa-east-1"
    destination_key_arn     = "arn:aws:kms:sa-east-1:306915830875:key/11111111-1111-1111-1111-111111111111"
    toolchain_delivery = {
      repository_arn     = "arn:aws:ecr:sa-east-1:306915830875:repository/chico-workers"
      image_digest       = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      evidence_reference = "synthetic-mock-only"
    }
  }
  assert {
    condition = length(aws_iam_policy.boundary[0].policy) <= 6144 && alltrue([for document in [aws_iam_policy.boundary[0].policy, aws_iam_role_policy.support[0].policy] :
      length([for s in jsondecode(document).Statement : s if s.Sid == "EncryptOwnProdExport"]) == 1 &&
      length([for s in jsondecode(document).Statement : s if s.Sid == "ReviewedToolchainRepository"]) == 1 &&
      length([for s in jsondecode(document).Statement : s if startswith(s.Sid, "OwnDev")]) == 0
    ])
    error_message = "Combined Prod export and ECR delivery must fit the IAM boundary without regaining Dev access."
  }
}
