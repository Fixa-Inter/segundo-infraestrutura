resource "aws_ecr_repository" "apis" {
  for_each = local.backends

  name = "${var.project_name}/${each.key}-api"

  image_tag_mutability = "IMMUTABLE"

  # Imagens sao esvaziadas apenas com destroy.sh --delete-images
  force_delete = false

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-${each.key}-api"
  }
}