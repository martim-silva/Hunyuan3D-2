# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-ecs-task-execution-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

# IAM Policy for ECS Task Execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional policy for ECR access
resource "aws_iam_role_policy" "ecs_task_execution_custom_policy" {
  name = "${var.project_name}-ecs-task-execution-custom-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Role for ECS Task
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-ecs-task-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

# IAM Policy for ECS Task (application permissions)
resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "${var.project_name}-ecs-task-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.model_cache.arn,
          "${aws_s3_bucket.model_cache.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.app_logs.arn}:*"
      }
    ]
  })
}

# IAM Role for ECS Instance
resource "aws_iam_role" "ecs_instance_role" {
  name = "${var.project_name}-ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-ecs-instance-role"
    Project     = var.project_name
    Environment = var.environment
  }
}

# IAM Policy Attachments for ECS Instance Role
resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ssm_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Additional policy for ECS Instance
resource "aws_iam_role_policy" "ecs_instance_custom_policy" {
  name = "${var.project_name}-ecs-instance-custom-policy"
  role = aws_iam_role.ecs_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:CreateCluster",
          "ecs:DeregisterContainerInstance",
          "ecs:DiscoverPollEndpoint",
          "ecs:Poll",
          "ecs:RegisterContainerInstance",
          "ecs:StartTelemetrySession",
          "ecs:UpdateContainerInstancesState",
          "ecs:Submit*",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "${var.project_name}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name

  tags = {
    Name        = "${var.project_name}-ecs-instance-profile"
    Project     = var.project_name
    Environment = var.environment
  }
}

# S3 Bucket for Model Cache
resource "aws_s3_bucket" "model_cache" {
  bucket = "${var.project_name}-model-cache-${random_string.bucket_suffix.result}"

  tags = {
    Name        = "${var.project_name}-model-cache"
    Project     = var.project_name
    Environment = var.environment
  }
}

# Random string for bucket suffix
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# S3 Bucket Configuration
resource "aws_s3_bucket_versioning" "model_cache_versioning" {
  bucket = aws_s3_bucket.model_cache.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_encryption" "model_cache_encryption" {
  bucket = aws_s3_bucket.model_cache.id

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "model_cache_lifecycle" {
  bucket = aws_s3_bucket.model_cache.id

  rule {
    id     = "cleanup"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "hun3d2_task" {
  family                   = var.project_name
  requires_compatibilities = ["EC2"]
  network_mode            = "awsvpc"
  execution_role_arn      = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn           = aws_iam_role.ecs_task_role.arn

  # GPU resources
  cpu    = var.task_cpu
  memory = var.task_memory

  container_definitions = jsonencode([
    {
      name      = "hun3d2"
      image     = "${aws_ecr_repository.hun3d2_repo.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 8081
          hostPort      = 8081
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "HOST_PORT"
          value = "8081"
        },
        {
          name  = "PYTORCH_CUDA_ALLOC_CONF"
          value = "expandable_segments:True"
        },
        {
          name  = "CUDA_VISIBLE_DEVICES"
          value = "0"
        },
        {
          name  = "NVIDIA_VISIBLE_DEVICES"
          value = "all"
        },
        {
          name  = "NVIDIA_DRIVER_CAPABILITIES"
          value = "compute,utility"
        },
        {
          name  = "MODEL_PATH"
          value = "/app/models"
        },
        {
          name  = "TEX_MODEL_PATH"
          value = "/app/models"
        },
        {
          name  = "MV_MODEL_PATH"
          value = "/app/models"
        },
        {
          name  = "HF_TOKEN"
          value = var.huggingface_token
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "model-storage"
          containerPath = "/app/models"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app_logs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      resourceRequirements = [
        {
          type  = "GPU"
          value = "1"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "curl -f http://localhost:8081/ || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 120
      }

      linuxParameters = {
        devices = [
          {
            hostPath      = "/dev/nvidia0"
            containerPath = "/dev/nvidia0"
            permissions   = ["read", "write"]
          },
          {
            hostPath      = "/dev/nvidiactl"
            containerPath = "/dev/nvidiactl"
            permissions   = ["read", "write"]
          },
          {
            hostPath      = "/dev/nvidia-uvm"
            containerPath = "/dev/nvidia-uvm"
            permissions   = ["read", "write"]
          }
        ]
      }
    }
  ])

  volume {
    name      = "model-storage"
    host_path = "/opt/ml/models"
  }

  tags = {
    Name        = "${var.project_name}-task-definition"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ECS Service
resource "aws_ecs_service" "hun3d2_service" {
  name            = var.project_name
  cluster         = aws_ecs_cluster.hun3d2_cluster.id
  task_definition = aws_ecs_task_definition.hun3d2_task.arn
  desired_count   = var.service_desired_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.hun3d2_capacity_provider.name
    weight           = 100
  }

  network_configuration {
    subnets          = aws_subnet.public_subnets[*].id
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hun3d2_tg.arn
    container_name   = "hun3d2"
    container_port   = 8081
  }

  deployment_configuration {
    maximum_percent         = 200
    minimum_healthy_percent = 50
  }

  depends_on = [
    aws_lb_listener.hun3d2_listener,
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy
  ]

  tags = {
    Name        = "${var.project_name}-service"
    Project     = var.project_name
    Environment = var.environment
  }
}