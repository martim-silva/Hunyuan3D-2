terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# VPC Configuration
resource "aws_vpc" "hun3d2_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.project_name}-vpc"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "hun3d2_igw" {
  vpc_id = aws_vpc.hun3d2_vpc.id

  tags = {
    Name        = "${var.project_name}-igw"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Public Subnets
resource "aws_subnet" "public_subnets" {
  count             = var.az_count
  vpc_id            = aws_vpc.hun3d2_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.project_name}-public-subnet-${count.index + 1}"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.hun3d2_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hun3d2_igw.id
  }

  tags = {
    Name        = "${var.project_name}-public-rt"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Route Table Associations
resource "aws_route_table_association" "public_rta" {
  count          = var.az_count
  subnet_id      = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

# Security Groups
resource "aws_security_group" "alb_sg" {
  name_prefix = "${var.project_name}-alb-sg"
  vpc_id      = aws_vpc.hun3d2_vpc.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Custom Port"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-alb-sg"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_security_group" "ecs_sg" {
  name_prefix = "${var.project_name}-ecs-sg"
  vpc_id      = aws_vpc.hun3d2_vpc.id

  ingress {
    description     = "Application Port"
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-ecs-sg"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ECR Repository
resource "aws_ecr_repository" "hun3d2_repo" {
  name                 = "${var.project_name}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name        = "${var.project_name}-ecr"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ECR Lifecycle Policy
resource "aws_ecr_lifecycle_policy" "hun3d2_lifecycle" {
  repository = aws_ecr_repository.hun3d2_repo.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Application Load Balancer
resource "aws_lb" "hun3d2_alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public_subnets[*].id

  enable_deletion_protection = false

  tags = {
    Name        = "${var.project_name}-alb"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Target Group
resource "aws_lb_target_group" "hun3d2_tg" {
  name     = "${var.project_name}-tg"
  port     = 8081
  protocol = "HTTP"
  vpc_id   = aws_vpc.hun3d2_vpc.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name        = "${var.project_name}-tg"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ALB Listener
resource "aws_lb_listener" "hun3d2_listener" {
  load_balancer_arn = aws_lb.hun3d2_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hun3d2_tg.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "hun3d2_cluster" {
  name = "${var.project_name}-cluster"

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.ecs_logs.name
      }
    }
  }

  tags = {
    Name        = "${var.project_name}-cluster"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ECS Cluster Capacity Providers
resource "aws_ecs_cluster_capacity_providers" "hun3d2_capacity_providers" {
  cluster_name = aws_ecs_cluster.hun3d2_cluster.name

  capacity_providers = ["hun3d2-capacity-provider"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "hun3d2-capacity-provider"
  }

  depends_on = [aws_ecs_capacity_provider.hun3d2_capacity_provider]
}

# Launch Template for GPU instances
resource "aws_launch_template" "gpu_launch_template" {
  name_prefix   = "${var.project_name}-gpu-lt"
  image_id      = var.ecs_optimized_ami_id
  instance_type = var.gpu_instance_type
  key_name      = var.key_pair_name

  vpc_security_group_ids = [aws_security_group.ecs_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  # Additional storage for models
  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_size           = var.model_volume_size
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data_ecs.sh", {
    cluster_name          = aws_ecs_cluster.hun3d2_cluster.name
    model_volume_device   = "/dev/sdf"
    model_mount_point     = "/opt/ml/models"
    cloudwatch_log_group  = aws_cloudwatch_log_group.ecs_logs.name
    aws_region           = var.aws_region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-gpu-instance"
      Project     = var.project_name
      Environment = var.environment
    }
  }

  tags = {
    Name        = "${var.project_name}-gpu-lt"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "gpu_asg" {
  name                = "${var.project_name}-gpu-asg"
  vpc_zone_identifier = aws_subnet.public_subnets[*].id
  target_group_arns   = [aws_lb_target_group.hun3d2_tg.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 300

  min_size         = var.min_capacity
  max_size         = var.max_capacity
  desired_capacity = var.desired_capacity

  launch_template {
    id      = aws_launch_template.gpu_launch_template.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = false
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-gpu-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
}

# ECS Capacity Provider
resource "aws_ecs_capacity_provider" "hun3d2_capacity_provider" {
  name = "hun3d2-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.gpu_asg.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      maximum_scaling_step_size = 1
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }

  tags = {
    Name        = "${var.project_name}-capacity-provider"
    Project     = var.project_name
    Environment = var.environment
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${var.project_name}-logs"
    Project     = var.project_name
    Environment = var.environment
  }
}

# CloudWatch Log Group for Application
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/ecs/${var.project_name}/application"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${var.project_name}-app-logs"
    Project     = var.project_name
    Environment = var.environment
  }
}