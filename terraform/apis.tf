# Comecamos sem APIs ativas para nao tentar
# executar imagens que ainda nao existem.
variable "enabled_apis" {
  type    = set(string)
  default = []

  validation {
    condition = length(
      setsubtract(
        var.enabled_apis,
        toset(["mobile", "web", "nosql", "ia"])
      )
    ) == 0

    error_message = "API desconhecida."
  }
  validation {
    condition = (
      length(var.enabled_apis) == 0 ||
      var.enable_https
    )

    error_message = "Para ativar APIs, enable_https deve ser true."
  }
}

# Role existente no AWS Academy
data "aws_iam_role" "lab" {
  name = "LabRole"
}

# Somente APIs habilitadas
locals {
  active_apis = {
    for name, config in local.backends :
    name => config
    if contains(var.enabled_apis, name)
  }


  api_settings = {
    mobile = {
      cpu         = 512
      memory      = 1024
      health_path = "/actuator/health"
      priority    = 10
    }

    web = {
      cpu         = 512
      memory      = 1024
      health_path = "/actuator/health"
      priority    = 20
    }

    nosql = {
      cpu         = 512
      memory      = 1024
      health_path = "/actuator/health"
      priority    = 30
    }

    ia = {
      cpu         = 512
      memory      = 1024
      health_path = "/api/v1/health"
      priority    = 40
    }
  }

}

data "aws_ecr_image" "apis" {
  for_each = local.active_apis

  repository_name = aws_ecr_repository.apis[each.key].name
  image_tag       = var.image_tags[each.key]
}

module "api" {
  for_each = local.active_apis

  source = "../modules/ecs-api"

  name         = each.key
  project_name = var.project_name
  hostname     = each.value.hostname
  port         = each.value.port

  cpu         = local.api_settings[each.key].cpu
  memory      = local.api_settings[each.key].memory
  health_path = local.api_settings[each.key].health_path

  rule_priority = local.api_settings[each.key].priority

  image = format(
    "%s@%s",
    aws_ecr_repository.apis[each.key].repository_url,
    data.aws_ecr_image.apis[each.key].image_digest
  )

  desired_count = 1

  cluster_id            = aws_ecs_cluster.principal.id
  vpc_id                = data.aws_vpc.default.id
  subnet_ids            = local.public_subnet_ids
  alb_security_group_id = aws_security_group.alb.id
  https_listener_arn    = aws_lb_listener.https[0].arn

  execution_role_arn = data.aws_iam_role.lab.arn
  task_role_arn      = data.aws_iam_role.lab.arn
  aws_region         = var.aws_region

  environment = merge(
    jsondecode(file("${var.manifest_dir}/${each.key}.public.json")),
    each.key == "mobile" ? jsondecode(file("${var.manifest_dir}/mobile.firebase.json")) : {}
  )
  secrets = jsondecode(file("${var.manifest_dir}/${each.key}.secrets.json"))
}
