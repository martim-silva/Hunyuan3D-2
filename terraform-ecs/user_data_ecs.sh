#!/bin/bash

# ECS GPU Instance User Data Script
# This script configures ECS instances with GPU support for hun3d2 service

set -e

# Variables (populated by Terraform template)
CLUSTER_NAME="${cluster_name}"
MODEL_VOLUME_DEVICE="${model_volume_device}"
MODEL_MOUNT_POINT="${model_mount_point}"
CLOUDWATCH_LOG_GROUP="${cloudwatch_log_group}"
AWS_REGION="${aws_region}"
S3_BUCKET="${s3_bucket}"

# Log all output to CloudWatch
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Starting ECS GPU instance configuration..."
echo "Cluster: $CLUSTER_NAME"
echo "Model volume: $MODEL_VOLUME_DEVICE -> $MODEL_MOUNT_POINT"
echo "S3 bucket: $S3_BUCKET"

# Update system packages
yum update -y

# Install required packages
yum install -y \
    docker \
    awscli \
    htop \
    nvtop \
    wget \
    curl \
    unzip

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm

# Install NVIDIA Docker runtime
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.repo | \
  tee /etc/yum.repos.d/nvidia-docker.repo

yum clean expire-cache
yum install -y nvidia-docker2

# Install latest NVIDIA drivers (GPU-optimized AMI should have these, but ensure they're up to date)
yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)

# Download and install latest NVIDIA driver for Tesla/compute GPUs
NVIDIA_DRIVER_VERSION="535.161.07"
wget -q "https://us.download.nvidia.com/tesla/$NVIDIA_DRIVER_VERSION/NVIDIA-Linux-x86_64-$NVIDIA_DRIVER_VERSION.run"
chmod +x NVIDIA-Linux-x86_64-$NVIDIA_DRIVER_VERSION.run
./NVIDIA-Linux-x86_64-$NVIDIA_DRIVER_VERSION.run --silent --dkms

# Verify NVIDIA installation
nvidia-smi || echo "WARNING: nvidia-smi not available, GPU may not be properly configured"

# Configure Docker daemon for NVIDIA runtime
cat > /etc/docker/daemon.json <<EOF
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "log-driver": "awslogs",
    "log-opts": {
        "awslogs-group": "$CLOUDWATCH_LOG_GROUP",
        "awslogs-region": "$AWS_REGION",
        "awslogs-stream-prefix": "docker"
    }
}
EOF

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Setup model storage volume
echo "Configuring model storage volume..."

# Wait for the volume to be available
while [ ! -e $MODEL_VOLUME_DEVICE ]; do
  echo "Waiting for volume $MODEL_VOLUME_DEVICE to be available..."
  sleep 5
done

# Check if volume is already formatted
if ! blkid $MODEL_VOLUME_DEVICE; then
  echo "Formatting model volume..."
  mkfs -t ext4 $MODEL_VOLUME_DEVICE
fi

# Create mount point
mkdir -p $MODEL_MOUNT_POINT

# Mount the volume
mount $MODEL_VOLUME_DEVICE $MODEL_MOUNT_POINT

# Add to fstab for persistence
echo "$MODEL_VOLUME_DEVICE $MODEL_MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab

# Set permissions for models directory
chown -R 1000:1000 $MODEL_MOUNT_POINT
chmod -R 755 $MODEL_MOUNT_POINT

# Create subdirectories for different model types
mkdir -p $MODEL_MOUNT_POINT/hun3d2
mkdir -p $MODEL_MOUNT_POINT/cache
mkdir -p $MODEL_MOUNT_POINT/temp

# Pre-download models from S3 if they exist
echo "Checking for pre-cached models in S3..."
aws s3 sync s3://$S3_BUCKET/models/ $MODEL_MOUNT_POINT/ --region $AWS_REGION --no-progress || echo "No models found in S3 or sync failed"

# Configure ECS agent
echo "Configuring ECS agent..."

# Set ECS cluster name
echo "ECS_CLUSTER=$CLUSTER_NAME" >> /etc/ecs/ecs.config

# Enable GPU support in ECS agent
echo "ECS_ENABLE_GPU_SUPPORT=true" >> /etc/ecs/ecs.config

# Enable container metadata
echo "ECS_ENABLE_CONTAINER_METADATA=true" >> /etc/ecs/ecs.config

# Set log level for debugging
echo "ECS_LOGLEVEL=info" >> /etc/ecs/ecs.config

# Configure instance attributes
echo "ECS_INSTANCE_ATTRIBUTES={\"gpu\":\"nvidia\",\"gpu_memory\":\"24GB\",\"instance_type\":\"g5.xlarge\"}" >> /etc/ecs/ecs.config

# Configure CloudWatch agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent"
  },
  "metrics": {
    "namespace": "ECS/Hun3D2",
    "metrics_collected": {
      "cpu": {
        "measurement": [
          "cpu_usage_idle",
          "cpu_usage_iowait",
          "cpu_usage_user",
          "cpu_usage_system"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "*"
        ],
        "totalcpu": false
      },
      "disk": {
        "measurement": [
          "used_percent"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "*"
        ]
      },
      "diskio": {
        "measurement": [
          "io_time",
          "read_bytes",
          "write_bytes",
          "reads",
          "writes"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "*"
        ]
      },
      "mem": {
        "measurement": [
          "mem_used_percent"
        ],
        "metrics_collection_interval": 60
      },
      "netstat": {
        "measurement": [
          "tcp_established",
          "tcp_time_wait"
        ],
        "metrics_collection_interval": 60
      },
      "swap": {
        "measurement": [
          "swap_used_percent"
        ],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/ecs/ecs-agent.log",
            "log_group_name": "$CLOUDWATCH_LOG_GROUP",
            "log_stream_name": "{instance_id}/ecs-agent"
          },
          {
            "file_path": "/var/log/ecs/ecs-init.log",
            "log_group_name": "$CLOUDWATCH_LOG_GROUP",
            "log_stream_name": "{instance_id}/ecs-init"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "$CLOUDWATCH_LOG_GROUP",
            "log_stream_name": "{instance_id}/user-data"
          }
        ]
      }
    }
  }
}
EOF

# Start CloudWatch agent
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# Configure log rotation
cat > /etc/logrotate.d/hun3d2 <<EOF
/var/log/hun3d2/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

# Create health check script
cat > /usr/local/bin/health-check.sh <<'EOF'
#!/bin/bash
# Health check script for hun3d2 service

# Check if GPU is available
if ! nvidia-smi &>/dev/null; then
    echo "ERROR: GPU not available"
    exit 1
fi

# Check if Docker is running
if ! systemctl is-active --quiet docker; then
    echo "ERROR: Docker not running"
    exit 1
fi

# Check if ECS agent is running
if ! systemctl is-active --quiet ecs; then
    echo "ERROR: ECS agent not running"
    exit 1
fi

# Check disk space for models
DISK_USAGE=$(df $MODEL_MOUNT_POINT | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$DISK_USAGE" -gt 90 ]; then
    echo "WARNING: Model disk usage is $DISK_USAGE%"
fi

echo "Health check passed"
exit 0
EOF

chmod +x /usr/local/bin/health-check.sh

# Create cleanup script for old models
cat > /usr/local/bin/cleanup-models.sh <<'EOF'
#!/bin/bash
# Cleanup old cached models

MODEL_DIR="$MODEL_MOUNT_POINT/cache"
DAYS_OLD=7

echo "Cleaning up models older than $DAYS_OLD days in $MODEL_DIR"
find "$MODEL_DIR" -name "*.safetensors" -mtime +$DAYS_OLD -delete
find "$MODEL_DIR" -name "*.bin" -mtime +$DAYS_OLD -delete
find "$MODEL_DIR" -name "*.pt" -mtime +$DAYS_OLD -delete

# Clean temp files older than 1 day
find "$MODEL_MOUNT_POINT/temp" -mtime +1 -delete

echo "Model cleanup completed"
EOF

chmod +x /usr/local/bin/cleanup-models.sh

# Setup cron jobs
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/cleanup-models.sh >> /var/log/hun3d2/cleanup.log 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/health-check.sh >> /var/log/hun3d2/health.log 2>&1") | crontab -

# Create log directory
mkdir -p /var/log/hun3d2
chown ec2-user:ec2-user /var/log/hun3d2

# Start ECS agent
systemctl enable ecs
systemctl start ecs

# Configure swap (helpful for large model loading)
if [ ! -f /swapfile ]; then
    echo "Creating 4GB swap file..."
    dd if=/dev/zero of=/swapfile bs=1024 count=4194304
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
fi

# Performance tuning for ML workloads
echo 'vm.swappiness=10' >> /etc/sysctl.conf
echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
echo 'net.core.rmem_max = 134217728' >> /etc/sysctl.conf
echo 'net.core.wmem_max = 134217728' >> /etc/sysctl.conf
sysctl -p

# Final verification
echo "Verifying installation..."
echo "Docker version:"
docker --version

echo "NVIDIA driver version:"
nvidia-smi --query-gpu=driver_version --format=csv,noheader || echo "GPU check failed"

echo "ECS agent status:"
systemctl status ecs --no-pager

echo "Available GPU memory:"
nvidia-smi --query-gpu=memory.total --format=csv,noheader,units=MiB || echo "GPU memory check failed"

echo "Model storage:"
df -h $MODEL_MOUNT_POINT

echo "ECS instance configuration completed successfully!"

# Signal to Auto Scaling that the instance is ready
/opt/aws/bin/cfn-signal -e $? --stack $(curl -s http://169.254.169.254/latest/meta-data/tags/instance/aws:cloudformation:stack-name) --resource AutoScalingGroup --region $AWS_REGION || echo "CloudFormation signal failed (expected in non-CF deployments)"

echo "User data script completed at $(date)"