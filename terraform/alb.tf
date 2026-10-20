resource "aws_lb" "principal" {
  name               = "fixa-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = local.public_subnet_ids

  lifecycle {
    precondition {
      condition = (
        length(distinct([
          for subnet in data.aws_subnet.selected :
          subnet.availability_zone
        ])) >= 2
      )

      error_message = "O ALB precisa de sub-redes em duas AZs distintas."
    }
  }

  tags = {
    Name = "fixa-alb"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.principal.arn

  port     = 80
  protocol = "HTTP"

  dynamic "default_action" {
    for_each = var.enable_https ? [1] : []

    content {
      type = "redirect"

      redirect {
        protocol    = "HTTPS"
        port        = "443"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.enable_https ? [] : [1]

    content {
      type = "fixed-response"

      fixed_response {
        content_type = "text/plain"
        message_body = "FIXA - infraestrutura inicializada"
        status_code  = "200"
      }
    }
  }
}