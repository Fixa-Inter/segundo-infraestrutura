resource "aws_acm_certificate" "fixa" {
  domain_name = var.domain_name

  subject_alternative_names = [
    "*.${var.domain_name}"
  ]

  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "fixa-certificate"
  }
}