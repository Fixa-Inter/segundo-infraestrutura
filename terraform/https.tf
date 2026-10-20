variable "enable_https" {
  description = "Ativa o listener HTTPS apos o certificado ser emitido"
  type        = bool
  default     = false
}

resource "aws_lb_listener" "https" {
  count = var.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.principal.arn

  port     = 443
  protocol = "HTTPS"

  certificate_arn = aws_acm_certificate.fixa.arn
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Host nao configurado"
      status_code  = "404"
    }
  }

  tags = {
    Name = "fixa-https"
  }
}