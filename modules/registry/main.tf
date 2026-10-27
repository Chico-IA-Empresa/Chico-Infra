locals { repositories = toset(["chico-api", "chico-workers", "chico-frontend"]) }
resource "aws_ecr_repository" "this" {
  for_each             = local.repositories
  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  lifecycle { prevent_destroy = true }
}
# SHA expiration is deliberately performed by a reviewed digest-aware cleanup,
# not a count rule: a release can remain deployed beyond 30 builds.
resource "aws_ecr_lifecycle_policy" "untagged" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({ rules = [{ rulePriority = 1, description = "Untagged after 7 days; tagged releases protected", selection = {
    tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7
  }, action = { type = "expire" } }] })
}
output "repositories" { value = { for k, v in aws_ecr_repository.this : k => { arn = v.arn, url = v.repository_url } } }
