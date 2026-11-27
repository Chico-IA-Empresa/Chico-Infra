# A composição que vivia neste root (foundation, api, edge, migrate, workers)
# passou para modules/app-stack, que Prod também chama. Estes blocos levam o
# que já estiver no state para o endereço novo sem destruir nem recriar: as
# chaves de count/for_each são preservadas. Podem sair depois que todo state
# de UAT tiver passado por um apply com eles.
moved {
  from = aws_kms_key.uat
  to   = module.app_stack.aws_kms_key.this
}
moved {
  from = aws_kms_alias.uat
  to   = module.app_stack.aws_kms_alias.this
}
moved {
  from = aws_sns_topic.operations
  to   = module.app_stack.aws_sns_topic.operations
}
moved {
  from = aws_sns_topic_policy.operations
  to   = module.app_stack.aws_sns_topic_policy.operations
}
moved {
  from = aws_sns_topic_subscription.operations
  to   = module.app_stack.aws_sns_topic_subscription.operations
}
moved {
  from = aws_ecs_cluster.web
  to   = module.app_stack.aws_ecs_cluster.web
}
moved {
  from = aws_ecs_cluster_capacity_providers.web
  to   = module.app_stack.aws_ecs_cluster_capacity_providers.web
}
moved {
  from = aws_ecs_task_definition.migrate
  to   = module.app_stack.aws_ecs_task_definition.migrate
}
moved {
  from = module.alb
  to   = module.app_stack.module.alb
}
moved {
  from = module.api_deploy
  to   = module.app_stack.module.api_deploy
}
moved {
  from = module.web
  to   = module.app_stack.module.web
}
moved {
  from = module.edge
  to   = module.app_stack.module.edge
}
moved {
  from = module.workers_iam
  to   = module.app_stack.module.workers_iam
}
moved {
  from = module.workers
  to   = module.app_stack.module.workers
}
moved {
  from = module.schedules
  to   = module.app_stack.module.schedules
}
