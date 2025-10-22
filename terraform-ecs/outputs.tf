# Output values for the ECS deployment

output "alb_url" {
  description = "Application Load Balancer URL for accessing the hun3d2 service"
  value       = "http://${aws_lb.hun3d2_alb.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.hun3d2_alb.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the Application Load Balancer (for Route53 records)"
  value       = aws_lb.hun3d2_alb.zone_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for pushing hun3d2 Docker images"
  value       = aws_ecr_repository.hun3d2_repo.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name"
  value       = aws_ecr_repository.hun3d2_repo.name
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.hun3d2_cluster.name
}

output "ecs_cluster_arn" {
  description = "ARN of the ECS cluster"
  value       = aws_ecs_cluster.hun3d2_cluster.arn
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.hun3d2_service.name
}

output "ecs_task_definition_arn" {
  description = "ARN of the ECS task definition"
  value       = aws_ecs_task_definition.hun3d2_task.arn
}

output "s3_model_cache_bucket" {
  description = "S3 bucket name for model caching"
  value       = aws_s3_bucket.model_cache.bucket
}

output "s3_model_cache_bucket_arn" {
  description = "S3 bucket ARN for model caching"
  value       = aws_s3_bucket.model_cache.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for ECS logs"
  value       = aws_cloudwatch_log_group.ecs_logs.name
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.hun3d2_vpc.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public_subnets[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private_subnets[*].id
}

output "security_group_id" {
  description = "Security group ID for ECS instances"
  value       = aws_security_group.ecs_sg.id
}

output "alb_security_group_id" {
  description = "Security group ID for Application Load Balancer"
  value       = aws_security_group.alb_sg.id
}

output "auto_scaling_group_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.gpu_asg.name
}

output "auto_scaling_group_arn" {
  description = "ARN of the Auto Scaling Group"
  value       = aws_autoscaling_group.gpu_asg.arn
}

output "iam_task_execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = aws_iam_role.ecs_task_execution_role.arn
}

output "iam_task_role_arn" {
  description = "ARN of the ECS task role"
  value       = aws_iam_role.ecs_task_role.arn
}

output "iam_instance_role_arn" {
  description = "ARN of the ECS instance role"
  value       = aws_iam_role.ecs_instance_role.arn
}

# CloudWatch Dashboard URL (constructed)
output "cloudwatch_dashboard_url" {
  description = "URL to CloudWatch dashboard for monitoring"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${var.project_name}-dashboard"
}

# ECS Service URL (constructed)
output "ecs_service_url" {
  description = "URL to ECS service in AWS console"
  value       = "https://${var.aws_region}.console.aws.amazon.com/ecs/home?region=${var.aws_region}#/clusters/${aws_ecs_cluster.hun3d2_cluster.name}/services/${aws_ecs_service.hun3d2_service.name}/details"
}

# Cost estimation outputs
output "estimated_monthly_cost_info" {
  description = "Estimated monthly cost information (USD)"
  value = {
    instance_cost_per_hour = "~$1.006 per g5.xlarge instance"
    alb_cost_per_hour     = "~$0.0225 per ALB"
    ebs_cost_per_gb       = "~$0.08-0.10 per GB/month (gp3)"
    data_transfer_cost    = "~$0.09 per GB out to internet"
    cloudwatch_logs_cost  = "~$0.50 per GB ingested"
    note                  = "Actual costs depend on usage patterns and data transfer"
  }
}

# Deployment information
output "deployment_info" {
  description = "Important deployment information"
  value = {
    gpu_memory              = "24GB VRAM (NVIDIA A10G)"
    container_cpu           = "${var.container_cpu} CPU units"
    container_memory        = "${var.container_memory} MB"
    gpu_resources          = "1 GPU allocated per task"
    auto_scaling_min       = var.auto_scaling_min_capacity
    auto_scaling_max       = var.auto_scaling_max_capacity
    health_check_path      = "/health"
    load_balancer_port     = 80
    container_port         = var.container_port
    model_storage_size     = "${var.model_volume_size}GB EBS volume"
  }
}

# Quick start commands
output "quick_start_commands" {
  description = "Quick start commands for deployment"
  value = {
    build_and_push_image = "cd .. && docker build -t hun3d2 . && aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.hun3d2_repo.repository_url} && docker tag hun3d2:latest ${aws_ecr_repository.hun3d2_repo.repository_url}:latest && docker push ${aws_ecr_repository.hun3d2_repo.repository_url}:latest"
    force_new_deployment = "aws ecs update-service --cluster ${aws_ecs_cluster.hun3d2_cluster.name} --service ${aws_ecs_service.hun3d2_service.name} --force-new-deployment --region ${var.aws_region}"
    view_logs           = "aws logs tail ${aws_cloudwatch_log_group.ecs_logs.name} --follow --region ${var.aws_region}"
    scale_service       = "aws ecs update-service --cluster ${aws_ecs_cluster.hun3d2_cluster.name} --service ${aws_ecs_service.hun3d2_service.name} --desired-count <COUNT> --region ${var.aws_region}"
  }
}

# Monitoring URLs
output "monitoring_urls" {
  description = "URLs for monitoring the deployment"
  value = {
    ecs_cluster_console = "https://${var.aws_region}.console.aws.amazon.com/ecs/home?region=${var.aws_region}#/clusters/${aws_ecs_cluster.hun3d2_cluster.name}"
    alb_console        = "https://${var.aws_region}.console.aws.amazon.com/ec2/v2/home?region=${var.aws_region}#LoadBalancers:search=${aws_lb.hun3d2_alb.name}"
    cloudwatch_logs    = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#logsV2:log-groups/log-group/${aws_cloudwatch_log_group.ecs_logs.name}"
    auto_scaling_group = "https://${var.aws_region}.console.aws.amazon.com/ec2/autoscaling/home?region=${var.aws_region}#AutoScalingGroups:id=${aws_autoscaling_group.gpu_asg.name}"
    ecr_repository     = "https://${var.aws_region}.console.aws.amazon.com/ecr/repositories/private/${data.aws_caller_identity.current.account_id}/${aws_ecr_repository.hun3d2_repo.name}?region=${var.aws_region}"
  }
}