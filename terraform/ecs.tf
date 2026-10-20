resource "aws_ecs_cluster" "principal" {
  name = "cluster-fixa"

  tags = {
    Name = "cluster-fixa"
  }
}