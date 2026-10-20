terraform {
  required_version = ">= 1.10.5, < 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "fixa"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

backend "local" {}

data "aws_caller_identity" "current" {}

