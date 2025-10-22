#!/bin/bash

# Deploy script for Hun3D2 ECS service
# This script automates the deployment process

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Check if required tools are installed
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check Terraform
    if ! command -v terraform &> /dev/null; then
        error "Terraform is not installed. Please install Terraform >= 1.0"
    fi
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install AWS CLI v2"
    fi
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Please install Docker"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured. Please run 'aws configure'"
    fi
    
    log "Prerequisites check passed"
}

# Get Terraform outputs
get_terraform_outputs() {
    cd "$TERRAFORM_DIR"
    
    if [ ! -f "terraform.tfstate" ]; then
        error "Terraform state not found. Please run 'terraform apply' first"
    fi
    
    # Get outputs
    ECR_REPO_URL=$(terraform output -raw ecr_repository_url 2>/dev/null || echo "")
    ALB_URL=$(terraform output -raw alb_url 2>/dev/null || echo "")
    ECS_CLUSTER=$(terraform output -raw ecs_cluster_name 2>/dev/null || echo "")
    ECS_SERVICE=$(terraform output -raw ecs_service_name 2>/dev/null || echo "")
    AWS_REGION=$(terraform output -raw aws_region 2>/dev/null || aws configure get region || echo "us-west-2")
    
    if [ -z "$ECR_REPO_URL" ]; then
        error "Could not get ECR repository URL from Terraform outputs"
    fi
    
    log "Retrieved Terraform outputs"
}

# Build Docker image
build_image() {
    log "Building Docker image..."
    
    cd "$SERVICE_DIR"
    
    # Build the image
    docker build -t hun3d2:latest .
    
    if [ $? -ne 0 ]; then
        error "Docker build failed"
    fi
    
    log "Docker image built successfully"
}

# Push image to ECR
push_image() {
    log "Pushing image to ECR..."
    
    # Login to ECR
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_REPO_URL"
    
    if [ $? -ne 0 ]; then
        error "ECR login failed"
    fi
    
    # Tag the image
    docker tag hun3d2:latest "$ECR_REPO_URL:latest"
    docker tag hun3d2:latest "$ECR_REPO_URL:$(date +%Y%m%d%H%M%S)"
    
    # Push the image
    docker push "$ECR_REPO_URL:latest"
    docker push "$ECR_REPO_URL:$(date +%Y%m%d%H%M%S)"
    
    if [ $? -ne 0 ]; then
        error "Docker push failed"
    fi
    
    log "Image pushed to ECR successfully"
}

# Deploy to ECS
deploy_service() {
    log "Deploying to ECS..."
    
    # Force new deployment
    aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "$ECS_SERVICE" \
        --force-new-deployment \
        --region "$AWS_REGION" \
        --output table
    
    if [ $? -ne 0 ]; then
        error "ECS service update failed"
    fi
    
    log "ECS service deployment initiated"
}

# Wait for deployment to complete
wait_for_deployment() {
    log "Waiting for deployment to complete..."
    
    local max_wait=1200  # 20 minutes
    local wait_time=0
    local check_interval=30
    
    while [ $wait_time -lt $max_wait ]; do
        # Check service status
        local running_count=$(aws ecs describe-services \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].runningCount' \
            --output text)
        
        local desired_count=$(aws ecs describe-services \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].desiredCount' \
            --output text)
        
        local deployment_status=$(aws ecs describe-services \
            --cluster "$ECS_CLUSTER" \
            --services "$ECS_SERVICE" \
            --region "$AWS_REGION" \
            --query 'services[0].deployments[0].status' \
            --output text)
        
        info "Running: $running_count/$desired_count, Status: $deployment_status"
        
        if [ "$running_count" = "$desired_count" ] && [ "$deployment_status" = "PRIMARY" ]; then
            log "Deployment completed successfully!"
            break
        fi
        
        if [ "$deployment_status" = "FAILED" ]; then
            error "Deployment failed"
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
    done
    
    if [ $wait_time -ge $max_wait ]; then
        warn "Deployment timeout reached. Check ECS console for status."
    fi
}

# Health check
health_check() {
    log "Performing health check..."
    
    local max_attempts=10
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        info "Health check attempt $attempt/$max_attempts"
        
        if curl -sf "$ALB_URL/health" > /dev/null 2>&1; then
            log "Service is healthy!"
            return 0
        fi
        
        sleep 30
        attempt=$((attempt + 1))
    done
    
    warn "Health check failed. Service may still be starting up."
    return 1
}

# Show deployment info
show_deployment_info() {
    log "Deployment Information:"
    echo "=========================="
    echo "Service URL: $ALB_URL"
    echo "ECS Cluster: $ECS_CLUSTER"
    echo "ECS Service: $ECS_SERVICE"
    echo "ECR Repository: $ECR_REPO_URL"
    echo "AWS Region: $AWS_REGION"
    echo ""
    echo "Test commands:"
    echo "  Health check: curl $ALB_URL/health"
    echo "  Generate 3D:  curl -X POST -F \"image=@test.jpg\" $ALB_URL/generate"
    echo ""
    echo "Monitoring:"
    echo "  ECS Console: https://$AWS_REGION.console.aws.amazon.com/ecs/home?region=$AWS_REGION#/clusters/$ECS_CLUSTER/services"
    echo "  Logs: aws logs tail /ecs/hun3d2 --follow --region $AWS_REGION"
    echo "=========================="
}

# Main deployment function
main() {
    local build_only=false
    local skip_build=false
    local skip_health_check=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --build-only)
                build_only=true
                shift
                ;;
            --skip-build)
                skip_build=true
                shift
                ;;
            --skip-health-check)
                skip_health_check=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --build-only         Only build and push image, don't deploy"
                echo "  --skip-build         Skip image build and push, only deploy"
                echo "  --skip-health-check  Skip health check after deployment"
                echo "  --help, -h           Show this help message"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    
    log "Starting Hun3D2 ECS deployment..."
    
    check_prerequisites
    get_terraform_outputs
    
    if [ "$skip_build" = false ]; then
        build_image
        push_image
    fi
    
    if [ "$build_only" = false ]; then
        deploy_service
        wait_for_deployment
        
        if [ "$skip_health_check" = false ]; then
            health_check
        fi
        
        show_deployment_info
    fi
    
    log "Deployment completed successfully!"
}

# Run main function with all arguments
main "$@"