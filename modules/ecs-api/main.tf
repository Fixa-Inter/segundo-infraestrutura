locals {
  api_name = "${var.project_name}-${var.name}-api"
}

# Security Group exclusivo da API
resource "aws_security_group" "api" {
  name        = local.api_name
  description = "Acesso do ALB para ${local.api_name}"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Somente ALB"
    from_port       = var.port
    to_port         = var.port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    description = "Saida para servicos externos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = local.api_name
  }
}

# Grupo de logs
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.api_name}"
  retention_in_days = 7
}

# Target Group
resource "aws_lb_target_group" "api" {
  name        = local.api_name
  port        = var.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = var.health_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = local.api_name
  }
}

# Task Definition
resource "aws_ecs_task_definition" "api" {
  lifecycle {
    create_before_destroy = true
  }

  family                   = local.api_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = tostring(var.cpu)
  memory = tostring(var.memory)

  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = local.api_name
      image     = var.image
      essential = true

      portMappings = [
        {
          containerPort = var.port
          hostPort      = var.port
          protocol      = "tcp"
        }
      ]

      environment = [
        for key, value in var.environment : {
          name  = key
          value = value
        }
      ]

      secrets = [
        for key, arn in var.secrets : {
          name      = key
          valueFrom = arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  tags = {
    Name = local.api_name
  }
}

# Regra HTTPS por subdominio
resource "aws_lb_listener_rule" "api" {
  listener_arn = var.https_listener_arn
  priority     = var.rule_priority

  condition {
    host_header {
      values = [var.hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = {
    Name = "${local.api_name}-routing"
  }
}

# ECS Service
resource "aws_ecs_service" "api" {
  name            = "${local.api_name}-service"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.api.arn

  launch_type      = "FARGATE"
  platform_version = "LATEST"
  desired_count    = var.desired_count

  health_check_grace_period_seconds = 120

  lifecycle {
    ignore_changes = [task_definition]
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = local.api_name
    container_port   = var.port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [
    aws_lb_listener_rule.api
  ]

  tags = {
    Name = "${local.api_name}-service"
  }
}