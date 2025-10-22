variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "hun3d2"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones"
  type        = number
  default     = 2
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "key_pair_name" {
  description = "Name of the EC2 Key Pair for instance access"
  type        = string
}

# GPU Instance Configuration
variable "gpu_instance_type" {
  description = "EC2 instance type with GPU support for 24GB VRAM"
  type        = string
  default     = "g5.xlarge"
  
  validation {
    condition = can(regex("^(g4dn|g5|p3|p4|p5)\\.", var.gpu_instance_type))
    error_message = "Instance type must be a GPU-enabled instance with sufficient VRAM."
  }
}

variable "ecs_optimized_ami_id" {
  description = "ECS-optimized AMI ID with GPU support"
  type        = string
  default     = "" # Will use data source if empty
}

# Auto Scaling Configuration
variable "min_capacity" {
  description = "Minimum number of instances in ASG"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of instances in ASG"
  type        = number
  default     = 3
}

variable "desired_capacity" {
  description = "Desired number of instances in ASG"
  type        = number
  default     = 1
}

# ECS Task Configuration
variable "task_cpu" {
  description = "CPU units for ECS task (1024 = 1 vCPU)"
  type        = number
  default     = 4096 # 4 vCPUs
}

variable "task_memory" {
  description = "Memory for ECS task in MB"
  type        = number
  default     = 16384 # 16 GB
}

variable "service_desired_count" {
  description = "Desired number of tasks in ECS service"
  type        = number
  default     = 1
}

# Container Configuration
variable "image_tag" {
  description = "Docker image tag for the application"
  type        = string
  default     = "latest"
}

variable "huggingface_token" {
  description = "Hugging Face token for model downloads"
  type        = string
  default     = ""
  sensitive   = true
}

# Storage Configuration
variable "root_volume_size" {
  description = "Size of root EBS volume in GB"
  type        = number
  default     = 100
}

variable "model_volume_size" {
  description = "Size of model storage EBS volume in GB"
  type        = number
  default     = 500
}

# Logging Configuration
variable "log_retention_days" {
  description = "CloudWatch log retention period in days"
  type        = number
  default     = 14
}

# SNS Configuration
variable "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  type        = string
  default     = ""
}

# Application Configuration
variable "enable_multiview" {
  description = "Enable multiview model support"
  type        = bool
  default     = true
}

variable "enable_texture" {
  description = "Enable texture generation support"
  type        = bool
  default     = true
}

# GPU Requirements Guide
variable "gpu_instance_recommendations" {
  description = "GPU instance recommendations for different workloads"
  type = object({
    vram_24gb = object({
      instances = list(string)
      cost_per_hour = map(string)
      description = string
    })
    vram_16gb = object({
      instances = list(string)
      cost_per_hour = map(string)
      description = string
    })
  })
  default = {
    vram_24gb = {
      instances = ["g5.xlarge", "g5.2xlarge", "g5.4xlarge"]
      cost_per_hour = {
        "g5.xlarge"  = "$1.006"
        "g5.2xlarge" = "$1.212"
        "g5.4xlarge" = "$1.624"
      }
      description = "Recommended for multiview 3D generation with texture support"
    }
    vram_16gb = {
      instances = ["g4dn.xlarge", "p3.2xlarge"]
      cost_per_hour = {
        "g4dn.xlarge" = "$0.526"
        "p3.2xlarge"  = "$3.06"
      }
      description = "Suitable for single view generation"
    }
  }
}