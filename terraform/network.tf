# A VPC padrao e reutilizada, nunca gerenciada/destruida pelo projeto.
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}
data "aws_subnet" "all" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}
locals {
  # Uma subnet por AZ; a validacao de rotas e feita pelo preflight.
  subnets_by_az = {
    for id, subnet in data.aws_subnet.all : subnet.availability_zone => id...
  }
  public_subnet_ids = [for az in slice(sort(keys(local.subnets_by_az)), 0, min(2, length(local.subnets_by_az))) : sort(local.subnets_by_az[az])[0]]
}
data "aws_subnet" "selected" {
  for_each = toset(local.public_subnet_ids)
  id       = each.value
}
