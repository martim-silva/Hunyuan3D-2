# Data source for ECS-optimized AMI with GPU support
data "aws_ssm_parameter" "ecs_gpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id"
}

# Use data source AMI if not provided
locals {
  ecs_ami_id = var.ecs_optimized_ami_id != "" ? var.ecs_optimized_ami_id : data.aws_ssm_parameter.ecs_gpu_ami.value
}

# Update launch template to use local AMI ID
resource "aws_launch_template" "gpu_launch_template" {
  name_prefix   = "${var.project_name}-gpu-lt"
  image_id      = local.ecs_ami_id
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
    s3_bucket            = aws_s3_bucket.model_cache.bucket
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

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.project_name}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ECS service CPU utilization"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    ServiceName = aws_ecs_service.hun3d2_service.name
    ClusterName = aws_ecs_cluster.hun3d2_cluster.name
  }

  tags = {
    Name        = "${var.project_name}-high-cpu"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  alarm_name          = "${var.project_name}-high-memory"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ECS service memory utilization"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    ServiceName = aws_ecs_service.hun3d2_service.name
    ClusterName = aws_ecs_cluster.hun3d2_cluster.name
  }

  tags = {
    Name        = "${var.project_name}-high-memory"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "service_unhealthy" {
  alarm_name          = "${var.project_name}-service-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1"
  alarm_description   = "This metric monitors ALB healthy host count"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    TargetGroup  = aws_lb_target_group.hun3d2_tg.arn_suffix
    LoadBalancer = aws_lb.hun3d2_alb.arn_suffix
  }

  tags = {
    Name        = "${var.project_name}-service-unhealthy"
    Project     = var.project_name
    Environment = var.environment
  }
}