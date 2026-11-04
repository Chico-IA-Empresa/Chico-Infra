# Scanner fixture only. Never pass to Terraform. The lease is deliberately
# expired and financial/readiness approval is absent. No real access is proven.
provision_enabled       = true
account_id              = "306915830875"
owner                   = "security-scan-only"
cost_center             = "security-scan-only"
ami_id                  = "ami-00000000000000000"
vpc_id                  = "vpc-00000000000000000"
subnet_id               = "subnet-00000000000000000"
destination_bucket_name = "chico-dev-backup-306915830875-sa-east-1"
import_id               = "security-scan-only"
source_manifest_sha256  = "0000000000000000000000000000000000000000000000000000000000000000"
not_before_utc          = "2026-01-01T00:00:00Z"
expires_at_utc          = "2026-01-02T00:00:00Z"
source_list_prefixes    = ["pgbackrest/sofascore-postgres/security-scan-only/"]
source_version_policy_documents = [<<-POLICY
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObjectVersion","Resource":"arn:aws:s3:::chico-backup/pgbackrest/sofascore-postgres/security-scan-only/metadata","Condition":{"StringEquals":{"s3:VersionId":"scanner-only-not-a-real-version"}}}]}
POLICY
]
