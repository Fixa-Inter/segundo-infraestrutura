output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "ecr_repositories" {
  value = {
    for name, repo in aws_ecr_repository.apis :
    name => repo.repository_url
  }
}

output "api_domains" {
  value = {
    for name, config in local.backends :
    name => config.hostname
  }
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}

output "public_subnet_ids" {
  value = local.public_subnet_ids
}

output "alb_dns" {
  value = aws_lb.principal.dns_name
}

output "alb_arn" {
  value = aws_lb.principal.arn
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.principal.arn
}


output "acm_certificate_arn" {
  value = aws_acm_certificate.fixa.arn
}

output "acm_validation_records" {
  value = [
    for dvo in aws_acm_certificate.fixa.domain_validation_options : {
      domain = dvo.domain_name
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      value  = dvo.resource_record_value
    }
  ]
}

output "api_hostnames" {
  value = {
    for name, config in local.backends :
    name => config.hostname
  }
}

output "api_services" {
  value = {
    for name, api in module.api :
    name => {
      service = api.service_name
      host    = api.hostname
      target_group = api.target_group_arn
    }
  }
}