# Descobre automaticamente a VPC padrão da conta
data "aws_vpc" "default" {
  default = true
}

# Descobre as sub-redes dessa VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Escolhe duas sub-redes para o ALB e ECS
locals {
  public_subnet_ids = slice(
    sort(data.aws_subnets.default.ids),
    0,
    2
  )
}

# Informações das sub-redes selecionadas
data "aws_subnet" "selected" {
  for_each = toset(local.public_subnet_ids)

  id = each.value
}