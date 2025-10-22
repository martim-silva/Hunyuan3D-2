# Example terraform.tfvars for Hun3D2 ECS deployment
# Copy this file to terraform.tfvars and customize for your environment

# Basic Configuration
project_name = "hun3d2"
environment  = "production"
aws_region   = "us-north-1"  # Choose region with GPU instances available

# EC2 Configuration
key_pair_name = "Martim.Silva@ctw.bmwgroup.com"  # Replace with your EC2 key pair name

# GPU Instance Configuration
# g5.xlarge:  24GB VRAM, 4 vCPUs, 16GB RAM (~$1.006/hour)
# g5.2xlarge: 48GB VRAM, 8 vCPUs, 32GB RAM (~$2.012/hour)
# g5.4xlarge: 96GB VRAM, 16 vCPUs, 64GB RAM (~$4.024/hour)
gpu_instance_type = "g5.xlarge"

# Auto Scaling Configuration
auto_scaling_min_capacity     = 1    # Minimum number of instances
auto_scaling_max_capacity     = 3    # Maximum number of instances
auto_scaling_desired_capacity = 1    # Initial number of instances

# Container Resource Configuration
container_cpu    = 4096   # CPU units (1024 = 1 vCPU)
container_memory = 15360  # Memory in MB (leave ~1GB for system)
container_port   = 8000   # Port the Hun3D2 service runs on

# Storage Configuration
root_volume_size  = 50    # Root EBS volume size in GB
model_volume_size = 100   # Model storage EBS volume size in GB

# Network Configuration (optional - uses defaults if not specified)
# vpc_cidr = "10.0.0.0/16"
# availability_zones = ["us-west-2a", "us-west-2b"]

# Monitoring and Alerts (optional)
# sns_topic_arn = "arn:aws:sns:us-west-2:123456789012:hun3d2-alerts"

# Custom AMI (optional - uses latest ECS GPU-optimized AMI if not specified)
# ecs_optimized_ami_id = "ami-0123456789abcdef0"

# Advanced Configuration (optional)
# enable_deletion_protection = true
# cloudwatch_log_retention_days = 14

# Cost Optimization Options (uncomment to enable)
# enable_spot_instances = true  # Use spot instances for cost savings
# spot_max_price = "0.50"       # Maximum price for spot instances

# Security Configuration (optional)
# allowed_cidr_blocks = ["0.0.0.0/0"]  # Restrict ALB access to specific CIDRs
# enable_waf = true                     # Enable WAF for ALB

# Performance Tuning (optional)
# container_gpu_memory_reservation = 20480  # GPU memory reservation in MB
# enable_container_insights = true          # Enhanced CloudWatch monitoring