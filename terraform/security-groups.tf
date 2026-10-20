resource "aws_security_group" "alb" {
  name        = "fixa-alb"
  description = "Acesso publico ao ALB do FIXA"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP - redirecionamento HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS - APIs FIXA"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Saida do ALB"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "fixa-alb"
  }
}