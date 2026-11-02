
variable "name" {
  type = string
}

variable "project_name" {
  type = string
}

variable "hostname" {
  type = string
}

variable "port" {
  type = number
}

variable "cpu" {
  type = number
}

variable "memory" {
  type = number
}

variable "image" {
  type = string
}

variable "health_path" {
  type = string
}

variable "desired_count" {
  type = number
}

variable "rule_priority" {
  type = number
}

variable "cluster_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "https_listener_arn" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  type    = map(string)
  default = {}
}