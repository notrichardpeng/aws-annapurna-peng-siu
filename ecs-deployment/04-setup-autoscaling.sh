#!/bin/bash
set -e

# Configuration
export AWS_REGION=us-west-2
export CLUSTER_NAME=vllm-gpu-cluster
export SERVICE_NAME=vllm-api-service

echo "========================================="
echo "Setting Up Auto-Scaling for ECS Service"
echo "========================================="
echo ""

# Step 1: Register scalable target
echo "Step 1: Registering scalable target..."

aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/${CLUSTER_NAME}/${SERVICE_NAME} \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 1 \
  --max-capacity 3 \
  --region ${AWS_REGION}

echo "✓ Scalable target registered (min: 1, max: 3)"
echo ""

# Step 2: Create target tracking scaling policy (CPU-based)
echo "Step 2: Creating CPU-based scaling policy..."

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/${CLUSTER_NAME}/${SERVICE_NAME} \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name cpu-target-tracking-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 180
  }' \
  --region ${AWS_REGION}

echo "✓ CPU-based auto-scaling configured (target: 70%)"
echo ""

# Step 3: Create target tracking scaling policy (Memory-based)
echo "Step 3: Creating memory-based scaling policy..."

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/${CLUSTER_NAME}/${SERVICE_NAME} \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name memory-target-tracking-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 80.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageMemoryUtilization"
    },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 180
  }' \
  --region ${AWS_REGION}

echo "✓ Memory-based auto-scaling configured (target: 80%)"
echo ""

echo "========================================="
echo "Auto-Scaling Setup Complete!"
echo "========================================="
echo ""
echo "Scaling Configuration:"
echo "  Min tasks: 1"
echo "  Max tasks: 3"
echo "  CPU target: 70%"
echo "  Memory target: 80%"
echo "  Scale out cooldown: 60s"
echo "  Scale in cooldown: 180s"
echo ""
echo "Note: Auto-scaling is limited by available GPU instances in your cluster."
echo "To scale beyond 1 task, you'll need multiple GPU instances in the cluster."
echo ""
