#!/bin/bash
set -e

# Configuration
export AWS_REGION=us-west-2
export CLUSTER_NAME=vllm-gpu-cluster
export SERVICE_NAME=vllm-api-service
export TASK_FAMILY=vllm-model-api

echo "========================================="
echo "Registering Task Definition and Creating Service"
echo "========================================="
echo ""

# Step 1: Create execution role if it doesn't exist
echo "Step 1: Creating ECS Task Execution Role..."

cat > /tmp/ecs-task-execution-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document file:///tmp/ecs-task-execution-trust-policy.json \
  2>/dev/null || echo "Execution role already exists"

aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

echo "✓ Execution role ready"
echo ""

# Step 2: Register Task Definition
echo "Step 2: Registering ECS task definition..."

TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://ecs-deployment/02-create-task-definition.json \
  --region ${AWS_REGION} \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "✓ Task definition registered: $TASK_DEF_ARN"
echo ""

# Step 3: Wait for container instance to be available
echo "Step 3: Checking for available container instances..."

MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  INSTANCE_COUNT=$(aws ecs list-container-instances \
    --cluster ${CLUSTER_NAME} \
    --region ${AWS_REGION} \
    --query 'length(containerInstanceArns)' \
    --output text)

  if [ "$INSTANCE_COUNT" -gt 0 ]; then
    echo "✓ Container instance is available"
    break
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "Waiting for container instance... ($RETRY_COUNT/$MAX_RETRIES)"
  sleep 10
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "❌ Error: No container instances available after waiting"
  exit 1
fi

echo ""

# Step 4: Create ECS Service
echo "Step 4: Creating ECS service..."

SERVICE_ARN=$(aws ecs create-service \
  --cluster ${CLUSTER_NAME} \
  --service-name ${SERVICE_NAME} \
  --task-definition ${TASK_FAMILY} \
  --desired-count 1 \
  --launch-type EC2 \
  --scheduling-strategy REPLICA \
  --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100" \
  --region ${AWS_REGION} \
  --query 'service.serviceArn' \
  --output text 2>&1)

if [[ $SERVICE_ARN == arn:* ]]; then
  echo "✓ Service created: $SERVICE_ARN"
else
  echo "⚠️  Service may already exist or error occurred"
  SERVICE_ARN=$(aws ecs describe-services \
    --cluster ${CLUSTER_NAME} \
    --services ${SERVICE_NAME} \
    --region ${AWS_REGION} \
    --query 'services[0].serviceArn' \
    --output text)
  echo "Existing service: $SERVICE_ARN"
fi

echo ""

# Step 5: Get public IP of the instance
echo "Step 5: Getting instance public IP..."

CONTAINER_INSTANCE_ARN=$(aws ecs list-container-instances \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query 'containerInstanceArns[0]' \
  --output text)

EC2_INSTANCE_ID=$(aws ecs describe-container-instances \
  --cluster ${CLUSTER_NAME} \
  --container-instances ${CONTAINER_INSTANCE_ARN} \
  --region ${AWS_REGION} \
  --query 'containerInstances[0].ec2InstanceId' \
  --output text)

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids ${EC2_INSTANCE_ID} \
  --region ${AWS_REGION} \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "✓ Public IP: $PUBLIC_IP"
echo ""

echo "========================================="
echo "ECS Service Deployment Complete!"
echo "========================================="
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Service: $SERVICE_NAME"
echo "Instance: $EC2_INSTANCE_ID"
echo ""
echo "Your API is accessible at:"
echo "  http://$PUBLIC_IP:8000"
echo ""
echo "Test endpoints:"
echo "  Health check: curl http://$PUBLIC_IP:8000/health"
echo "  Generate: curl -X POST http://$PUBLIC_IP:8000/generate -H 'Content-Type: application/json' -d '{\"prompt\":\"Hello\"}'"
echo ""
echo "Monitor service:"
echo "  aws ecs describe-services --cluster ${CLUSTER_NAME} --services ${SERVICE_NAME} --region ${AWS_REGION}"
echo ""
echo "View logs:"
echo "  aws logs tail /ecs/vllm-model-api --follow --region ${AWS_REGION}"
echo ""
