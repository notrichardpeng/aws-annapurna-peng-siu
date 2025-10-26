#!/bin/bash
set -e

# AWS Configuration
export AWS_ACCOUNT_ID=960682159345
export AWS_REGION=us-west-2
export ECR_REPO_NAME=vllm-model-api
export IMAGE_TAG=latest

echo "========================================="
echo "AWS Deployment Script for vLLM Model API"
echo "========================================="
echo "AWS Account: $AWS_ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo "ECR Repo: $ECR_REPO_NAME"
echo ""

# Step 1: Create ECR Repository (if it doesn't exist)
echo "Step 1: Creating ECR repository..."
aws ecr describe-repositories --repository-names ${ECR_REPO_NAME} --region ${AWS_REGION} 2>/dev/null || \
  aws ecr create-repository \
    --repository-name ${ECR_REPO_NAME} \
    --region ${AWS_REGION} \
    --image-scanning-configuration scanOnPush=true

echo "✓ ECR repository ready"
echo ""

# Step 2: Login to ECR
echo "Step 2: Logging into ECR..."
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

echo "✓ Logged into ECR"
echo ""

# Step 3: Tag the Docker image
echo "Step 3: Tagging Docker image..."
docker tag ${ECR_REPO_NAME}:${IMAGE_TAG} \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}

echo "✓ Image tagged"
echo ""

# Step 4: Push to ECR
echo "Step 4: Pushing image to ECR..."
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}

echo "✓ Image pushed to ECR"
echo ""

echo "========================================="
echo "Docker image successfully deployed to ECR!"
echo "========================================="
echo ""
echo "Image URI:"
echo "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}"
echo ""
echo "Next steps:"
echo "1. Deploy to EC2 with GPU (g4dn.xlarge or g5.xlarge)"
echo "2. Or deploy to ECS with GPU-enabled task definition"
echo ""
