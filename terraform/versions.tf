terraform {
  backend "local" {}
  required_version = ">= 1.10.5, < 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.0.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.expected_account_id == null ? null : [var.expected_account_id]

  default_tags {
    tags = {
      Project     = "fixa"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}


data "aws_caller_identity" "current" {}

