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
    condition     = jsondecode(aws_iam_role_policy.support[0].policy).Statement[7].Sid == "NeverChangeLegacySource" && jsondecode(aws_iam_role_policy.support[0].policy).Statement[7].NotAction == ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObjectVersion"]
    error_message = "Acesso de source deve negar mutações e leitura sem VersionId, mesmo se outro grant for adicionado."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.support[0].policy).Statement[8].Condition.DateLessThan["aws:CurrentTime"] == var.not_before_utc && jsondecode(aws_iam_role_policy.support[0].policy).Statement[9].Condition.DateGreaterThanEquals["aws:CurrentTime"] == var.expires_at_utc
    error_message = "Janela deve negar leitura antes do início e a partir do vencimento."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.support[0].policy).Statement[6].Resource == "arn:aws:s3:::chico-dev-synthetic-backup/dev/database/import/synthetic-only/*" && alltrue([for s in local.support_statements : alltrue([for action in s.Action : !startswith(action, "iam:") && action != "ssm:SendCommand" && action != "s3:DeleteObject"])])
    error_message = "Escrita só no prefixo de conversão Dev, sem IAM, execução arbitrária ou exclusão S3."
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
