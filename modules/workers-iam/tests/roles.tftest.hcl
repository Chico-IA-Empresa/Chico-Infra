mock_provider "aws" {}
variables {
  env         = "uat"
  account_id  = "123456789012"
  secret_arns = ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/odds-bsd-AbCdEf"]
}
run "one_task_role_per_consumer_without_permissions" {
  command = plan
  assert {
    condition     = length(aws_iam_role.task) == 14 && alltrue([for role in aws_iam_role.task : role.path == "/chico/uat/" && startswith(role.name, "chico-uat-")])
    error_message = "Catorze consumidores (3 contínuos + 11 jobs), cada um com papel próprio no path do ambiente."
  }
  assert {
    condition     = length(output.task_role_arns) == 14 && output.task_role_arns["data-freshness"] == "arn:aws:iam::123456789012:role/chico/uat/chico-uat-data-freshness" && output.task_role_arns["odds-bsd"] == "arn:aws:iam::123456789012:role/chico/uat/chico-uat-odds-bsd"
    error_message = "O mapa de papéis cobre todos os consumidores que o modules/workers exige."
  }
  assert {
    condition     = alltrue([for role in aws_iam_role.task : jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012"])
    error_message = "Trust do ecs-tasks preso à conta (confused deputy)."
  }
}
run "execution_role_reads_only_what_it_was_given" {
  command = plan
  assert {
    condition     = one([for statement in jsondecode(aws_iam_role_policy.execution.policy).Statement : statement.Resource if statement.Sid == "WorkerSecrets"]) == ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/odds-bsd-AbCdEf"]
    error_message = "Segredos: exatamente a lista recebida."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_iam_role_policy.execution.policy).Statement : statement.Resource if statement.Sid == "EcrPullWorkers"]) == "arn:aws:ecr:sa-east-1:123456789012:repository/chico-workers"
    error_message = "Pull só do repositório chico-workers."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_role_policy.execution.policy).Statement : statement.Resource != "*" || statement.Action == "ecr:GetAuthorizationToken"])
    error_message = "Curinga de recurso só onde a AWS exige (GetAuthorizationToken)."
  }
  assert {
    condition     = length([for statement in jsondecode(aws_iam_role_policy.execution.policy).Statement : statement if statement.Sid == "WorkerParameters" || statement.Sid == "DecryptWorkerSecrets"]) == 0
    error_message = "Sem parâmetros nem chave informados, nenhuma permissão a mais."
  }
}
run "scheduler_runs_only_jobs_and_passes_only_job_roles" {
  command = plan
  assert {
    condition     = length(one([for statement in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : statement.Resource if statement.Sid == "RunJobTasksOnWorkersCluster"])) == 11
    error_message = "RunTask só nas famílias dos onze jobs."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : statement.Condition.ArnEquals["ecs:cluster"] if statement.Sid == "RunJobTasksOnWorkersCluster"]) == "arn:aws:ecs:sa-east-1:123456789012:cluster/chico-uat-workers"
    error_message = "RunTask preso ao cluster dos workers do ambiente."
  }
  assert {
    condition     = !anytrue([for arn in one([for statement in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : statement.Resource if statement.Sid == "PassOnlyJobRoles"]) : endswith(arn, "/chico-uat-odds-bsd") || endswith(arn, "/chico-uat-odds-surebetting") || endswith(arn, "/chico-uat-telegram-update")])
    error_message = "O Scheduler não pode passar o papel dos contínuos."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_iam_role_policy.scheduler.policy).Statement : statement.Condition.StringEquals["iam:PassedToService"] if statement.Sid == "PassOnlyJobRoles"]) == "ecs-tasks.amazonaws.com"
    error_message = "PassRole só para o ECS."
  }
}
run "host_profile_matches_workers_module_input" {
  command = plan
  assert {
    condition     = output.instance_profile_arn == "arn:aws:iam::123456789012:instance-profile/chico/uat/chico-uat-workers-host" && aws_iam_instance_profile.host.path == "/chico/uat/"
    error_message = "Instance profile do host no formato que o modules/workers recebe."
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.host) == 2
    error_message = "Host com agente do ECS e SSM (sem SSH)."
  }
}
run "reject_secret_from_another_account" {
  command = plan
  variables { secret_arns = ["arn:aws:secretsmanager:sa-east-1:999999999999:secret:/chico/uat/workers/x"] }
  expect_failures = [var.secret_arns]
}
run "reject_dev" {
  command = plan
  variables { env = "dev" }
  expect_failures = [var.env]
}
