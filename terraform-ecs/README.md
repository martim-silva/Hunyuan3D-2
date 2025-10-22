# Hun3D2 ECS Deployment with GPU Support

This Terraform configuration deploys the Hun3D2 3D model generation service on AWS ECS with GPU support, auto-scaling, and load balancing.

## Architecture Overview

- **Compute**: ECS cluster with GPU-enabled instances (g5.xlarge with 24GB VRAM)
- **Networking**: VPC with public/private subnets across 2 AZs
- **Load Balancing**: Application Load Balancer with health checks
- **Storage**: EBS volumes for models, S3 for model caching
- **Monitoring**: CloudWatch logs, metrics, and alarms
- **Security**: IAM roles, security groups, encrypted storage

## Prerequisites

1. **AWS CLI configured** with appropriate permissions
2. **Terraform >= 1.0** installed
3. **Docker** for building and pushing images
4. **EC2 Key Pair** in target region

## Required AWS Permissions

Your AWS credentials need permissions for:
- ECS (clusters, services, tasks)
- EC2 (instances, VPC, security groups, auto scaling)
- Application Load Balancer
- ECR (Elastic Container Registry)
- IAM (roles and policies)
- CloudWatch (logs, metrics, alarms)
- S3 (model caching bucket)

## Quick Start

### 1. Configure Variables

Create a `terraform.tfvars` file:

```hcl
# Basic Configuration
project_name = "hun3d2"
environment  = "production"
aws_region   = "us-west-2"

# EC2 Configuration
key_pair_name = "your-ec2-key-pair"

# GPU Instance Type (recommended for 24GB VRAM)
gpu_instance_type = "g5.xlarge"  # 24GB VRAM
# Alternative: "g5.2xlarge" for 48GB VRAM (higher cost)

# Scaling Configuration
auto_scaling_min_capacity     = 1
auto_scaling_max_capacity     = 3
auto_scaling_desired_capacity = 1

# Container Configuration
container_cpu    = 4096  # 4 vCPUs
container_memory = 15360 # 15GB RAM
container_port   = 8000

# Storage Configuration
root_volume_size  = 50   # GB
model_volume_size = 100  # GB for model storage

# Optional: Notification
sns_topic_arn = "arn:aws:sns:us-west-2:123456789012:hun3d2-alerts"

# Custom AMI (optional - will use latest ECS GPU-optimized AMI if not specified)
# ecs_optimized_ami_id = "ami-0123456789abcdef0"
```

### 2. Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Deploy (will take ~10-15 minutes)
terraform apply
```

### 3. Build and Push Docker Image

```bash
# Navigate to the service directory
cd ..

# Build the Docker image
docker build -t hun3d2 .

# Get ECR login token (replace REGION and ACCOUNT_ID)
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com

# Tag and push the image
docker tag hun3d2:latest ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/hun3d2:latest
docker push ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/hun3d2:latest
```

*Note: Replace `ACCOUNT_ID` with your AWS account ID. The exact commands are provided in Terraform outputs.*

### 4. Force Service Deployment

```bash
# Trigger deployment of the new image
aws ecs update-service --cluster hun3d2-cluster --service hun3d2-service --force-new-deployment --region us-west-2
```

## Accessing the Service

After deployment, the service will be available at the ALB URL (provided in Terraform outputs):

```bash
# Get the ALB URL
terraform output alb_url

# Test the service
curl http://ALB_DNS_NAME/health

# Upload an image for 3D generation
curl -X POST -F "image=@test.jpg" http://ALB_DNS_NAME/generate
```

## Monitoring and Logging

### CloudWatch Logs
- **Log Group**: `/ecs/hun3d2`
- **Streams**: Container logs, ECS agent logs, user data logs

### CloudWatch Metrics
- ECS service CPU/memory utilization
- ALB target health and request count
- Auto Scaling group metrics
- Custom GPU utilization (if configured)

### Alarms
- High CPU utilization (>80%)
- High memory utilization (>80%)
- Unhealthy targets in load balancer

## Cost Optimization

### Instance Costs (us-west-2)
- **g5.xlarge**: ~$1.006/hour (~$744/month)
- **g5.2xlarge**: ~$2.012/hour (~$1,489/month)

### Additional Costs
- **ALB**: ~$16/month
- **EBS Storage**: ~$8-10/month per 100GB
- **Data Transfer**: $0.09/GB outbound
- **CloudWatch Logs**: $0.50/GB ingested

### Cost Reduction Tips
1. **Use Spot Instances** (add to auto scaling group)
2. **Scale to Zero** during off-hours
3. **Optimize Container Resources** (reduce CPU/memory if possible)
4. **Use S3 Intelligent Tiering** for model storage

## Scaling Configuration

### Auto Scaling Policies
- **Scale Up**: CPU > 70% for 2 consecutive periods
- **Scale Down**: CPU < 30% for 5 consecutive periods
- **Cooldown**: 300 seconds between scaling actions

### Manual Scaling
```bash
# Scale to specific number of tasks
aws ecs update-service --cluster hun3d2-cluster --service hun3d2-service --desired-count 3 --region us-west-2

# Scale Auto Scaling Group
aws autoscaling set-desired-capacity --auto-scaling-group-name hun3d2-gpu-asg --desired-capacity 2 --region us-west-2
```

## Troubleshooting

### Common Issues

1. **Service Won't Start**
   ```bash
   # Check ECS service events
   aws ecs describe-services --cluster hun3d2-cluster --services hun3d2-service --region us-west-2
   
   # Check container logs
   aws logs tail /ecs/hun3d2 --follow --region us-west-2
   ```

2. **GPU Not Available**
   ```bash
   # Check instance logs
   aws logs tail /ecs/hun3d2 --filter-pattern "GPU" --region us-west-2
   
   # SSH to instance and check
   nvidia-smi
   docker run --rm --gpus all nvidia/cuda:11.8-base nvidia-smi
   ```

3. **Health Check Failures**
   ```bash
   # Check ALB target health
   aws elbv2 describe-target-health --target-group-arn TARGET_GROUP_ARN --region us-west-2
   
   # Test health endpoint directly
   curl http://INSTANCE_IP:8000/health
   ```

4. **Out of Memory**
   - Increase `container_memory` in variables
   - Reduce model precision or batch size
   - Add swap space (configured in user data)

### Instance Access

```bash
# Find instance IP
aws ec2 describe-instances --filters "Name=tag:Project,Values=hun3d2" --query "Reservations[].Instances[].PublicIpAddress" --region us-west-2

# SSH to instance
ssh -i your-key.pem ec2-user@INSTANCE_IP

# Check GPU status
nvidia-smi

# Check Docker containers
docker ps

# Check ECS agent
sudo systemctl status ecs
```

## Security Considerations

1. **Network Security**
   - ALB in public subnets, ECS instances in private subnets
   - Security groups restrict access to necessary ports
   - NACLs provide additional network layer security

2. **IAM Security**
   - Least privilege IAM roles for ECS tasks and instances
   - Separate roles for execution vs. runtime
   - S3 bucket access limited to specific resources

3. **Data Security**
   - EBS volumes encrypted at rest
   - S3 bucket encryption enabled
   - CloudWatch logs retention configured

## Maintenance

### Regular Tasks
1. **Update Container Images** monthly
2. **Review CloudWatch Costs** monthly
3. **Clean Old Logs** (automated via retention policy)
4. **Update Security Groups** as needed
5. **Monitor GPU Driver Updates**

### Backup Strategy
- **Model Cache**: S3 cross-region replication
- **Configuration**: Terraform state in S3 backend
- **Logs**: CloudWatch retention policy

## Advanced Configuration

### Custom Domain
```hcl
# Add to variables
variable "domain_name" {
  description = "Custom domain for the service"
  type        = string
  default     = ""
}

# Add Route53 record and ACM certificate
resource "aws_route53_record" "hun3d2" {
  count   = var.domain_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"
  
  alias {
    name                   = aws_lb.hun3d2_alb.dns_name
    zone_id                = aws_lb.hun3d2_alb.zone_id
    evaluate_target_health = true
  }
}
```

### Multiple Environments
```bash
# Use workspace or separate state files
terraform workspace new staging
terraform workspace new production

# Or use different directories
mkdir staging production
```

### GPU Monitoring
```bash
# Install nvidia-ml-py in container for GPU metrics
pip install nvidia-ml-py3

# Add custom CloudWatch metrics in application
```

## Cleanup

```bash
# Destroy all resources
terraform destroy

# Note: Manual cleanup may be needed for:
# - ECR images
# - CloudWatch logs (if retention is set)
# - S3 bucket contents
```

## Support

For issues with:
- **AWS Services**: AWS Support or AWS forums
- **Hun3D2 Application**: Check container logs and GitHub issues
- **Terraform**: Terraform documentation and community
- **GPU/CUDA**: NVIDIA developer forums

## Contributing

1. Test changes in a dev environment first
2. Update documentation for any configuration changes
3. Follow AWS security best practices
4. Consider cost implications of changes