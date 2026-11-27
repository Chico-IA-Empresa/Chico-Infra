mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
}
variables {
  env                = "uat"
  account_id         = "123456789012"
  vpc_id             = "vpc-0123456789abcdef0"
  public_subnet_ids  = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  security_group_ids = { alb = "sg-0000000000000000a", api = "sg-0000000000000000b", frontend = "sg-0000000000000000c", workers = "sg-0000000000000000d", jobs = "sg-0000000000000000e" }
}
run "foundation_off_by_default" {
  command = plan
  assert {
    condition     = length(aws_kms_key.this) == 0 && length(aws_sns_topic.operations) == 0 && output.foundation == null
    error_message = "Sem as duas chaves, nenhuma CMK nem tópico de UAT."
  }
}
run "keys_and_topic_scoped_to_uat" {
  command = plan
  variables {
    enabled            = true
    foundation_enabled = true
  }
  assert {
    condition     = length(aws_kms_key.this) == 3 && alltrue([for key in aws_kms_key.this : key.enable_key_rotation && key.deletion_window_in_days == 30])
    error_message = "Três CMKs de UAT (logs, secrets, alerts) com rotação e janela de 30 dias."
  }
  assert {
    condition     = aws_kms_alias.this["logs"].name == "alias/chico/uat/logs" && aws_sns_topic.operations[0].name == "chico-uat-operations"
    error_message = "Alias e tópico no namespace de UAT."
  }
  assert {
    condition     = contains(one([for statement in jsondecode(aws_kms_key.this["logs"].policy).Statement : statement.Condition.StringEquals["kms:EncryptionContext:aws:logs:arn"] if statement.Sid == "RegionalLogEncryption"]), "arn:aws:logs:sa-east-1:123456789012:log-group:/chico/uat/workers") && contains(one([for statement in jsondecode(aws_kms_key.this["logs"].policy).Statement : statement.Condition.StringEquals["kms:EncryptionContext:aws:logs:arn"] if statement.Sid == "RegionalLogEncryption"]), "arn:aws:logs:sa-east-1:123456789012:log-group:aws-waf-logs-chico-uat-api")
    error_message = "A chave de logs só cifra os log groups que os blocos de UAT criam."
  }
  assert {
    condition     = length([for statement in jsondecode(aws_kms_key.this["secrets"].policy).Statement : statement if statement.Sid != "AccountRecoveryAndIAMDelegation"]) == 0
    error_message = "A chave de segredos só delega à conta; o uso exige kms:Decrypt explícito no papel."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_sns_topic_policy.operations[0].policy).Statement : statement.Condition.ArnEquals["aws:SourceArn"] if statement.Sid == "WorkerTaskFailedRuleOnly"]) == "arn:aws:events:sa-east-1:123456789012:rule/chico-uat-workers-task-failed"
    error_message = "Do EventBridge, só a regra de task parada dos workers publica no tópico."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_sns_topic_policy.operations[0].policy).Statement : statement.Condition.ArnLike["aws:SourceArn"] if statement.Sid == "UatAlarmsOnly"]) == "arn:aws:cloudwatch:sa-east-1:123456789012:alarm:chico-uat-*"
    error_message = "Do CloudWatch, só alarmes chico-uat-* publicam no tópico."
  }
}
run "prod_gets_its_own_namespace" {
  command = plan
  variables {
    env                = "prod"
    enabled            = true
    foundation_enabled = true
  }
  assert {
    condition     = aws_kms_alias.this["logs"].name == "alias/chico/prod/logs" && aws_sns_topic.operations[0].name == "chico-prod-operations"
    error_message = "Em Prod, alias e tópico no namespace de Prod."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_sns_topic_policy.operations[0].policy).Statement : statement.Condition.ArnLike["aws:SourceArn"] if statement.Sid == "ProdAlarmsOnly"]) == "arn:aws:cloudwatch:sa-east-1:123456789012:alarm:chico-prod-*"
    error_message = "Do CloudWatch, só alarmes chico-prod-* publicam no tópico de Prod."
  }
}
run "reject_unknown_environment" {
  command = plan
  variables { env = "dev" }
  expect_failures = [var.env]
}
