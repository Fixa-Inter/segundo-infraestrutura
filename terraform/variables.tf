variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "fixa"
}

variable "domain_name" {
  type    = string
  default = "fixa.solutions"
}

locals {
  backends = {
    mobile = {
      hostname = "mobile-api.${var.domain_name}"
      port     = 8080
    }

    web = {
      hostname = "web-api.${var.domain_name}"
      port     = 8080
    }

    nosql = {
      hostname = "nosql-api.${var.domain_name}"
      port     = 8080
    }

    ia = {
      hostname = "ia-api.${var.domain_name}"
      port     = 8000
    }
  }
}

variable "image_tags" {
  type = map(string)

  default = {
    mobile = "v1"
    web    = "v1"
    nosql  = "v1"
    ia     = "v1"
  }
}