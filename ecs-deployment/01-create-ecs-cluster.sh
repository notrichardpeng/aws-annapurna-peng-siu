#!/bin/bash
set -e

# Configuration
export AWS_REGION=us-west-2
export CLUSTER_NAME=vllm-gpu-cluster
export INSTANCE_TYPE=g4dn.xlarge
export KEY_NAME=your-ec2-keypair  # Change this to your SSH key name
export VPC_ID=$(aws ec2 describe-vpcs --region ${AWS_REGION} --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)

echo "========================================="
echo "Creating ECS Cluster with GPU Support"
echo "========================================="
echo "Region: $AWS_REGION"
echo "Cluster: $CLUSTER_NAME"
echo "Instance Type: $INSTANCE_TYPE"
echo "VPC: $VPC_ID"
echo ""

# Step 1: Create ECS Cluster
echo "Step 1: Creating ECS cluster..."
aws ecs create-cluster \
  --cluster-name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --tags key=Project,value=vLLM-Model-API

echo "✓ ECS cluster created"
echo ""

# Step 2: Create IAM Role for ECS Instances
echo "Step 2: Creating IAM roles..."

# Create instance role trust policy
cat > /tmp/ecs-instance-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create instance role
aws iam create-role \
  --role-name ecsInstanceRole-vLLM \
  --assume-role-policy-document file:///tmp/ecs-instance-trust-policy.json \
  2>/dev/null || echo "Role already exists"

# Attach managed policies
aws iam attach-role-policy \
  --role-name ecsInstanceRole-vLLM \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

aws iam attach-role-policy \
  --role-name ecsInstanceRole-vLLM \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Create instance profile
aws iam create-instance-profile \
  --instance-profile-name ecsInstanceProfile-vLLM \
  2>/dev/null || echo "Instance profile already exists"

aws iam add-role-to-instance-profile \
  --instance-profile-name ecsInstanceProfile-vLLM \
  --role-name ecsInstanceRole-vLLM \
  2>/dev/null || echo "Role already added to profile"

echo "✓ IAM roles configured"
echo "⏳ Waiting 10 seconds for IAM propagation..."
sleep 10
echo ""

# Step 3: Create Security Group
echo "Step 3: Creating security group..."

SECURITY_GROUP_ID=$(aws ec2 create-security-group \
  --group-name vllm-ecs-sg \
  --description "Security group for vLLM ECS instances" \
  --vpc-id ${VPC_ID} \
  --region ${AWS_REGION} \
  --output text \
  --query 'GroupId' 2>/dev/null || aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=vllm-ecs-sg" \
  --region ${AWS_REGION} \
  --query "SecurityGroups[0].GroupId" \
  --output text)

# Allow HTTP
aws ec2 authorize-security-group-ingress \
  --group-id ${SECURITY_GROUP_ID} \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region ${AWS_REGION} 2>/dev/null || echo "HTTP rule already exists"

# Allow model API port
aws ec2 authorize-security-group-ingress \
  --group-id ${SECURITY_GROUP_ID} \
  --protocol tcp \
  --port 8000 \
  --cidr 0.0.0.0/0 \
  --region ${AWS_REGION} 2>/dev/null || echo "Port 8000 rule already exists"

# Allow SSH
aws ec2 authorize-security-group-ingress \
  --group-id ${SECURITY_GROUP_ID} \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region ${AWS_REGION} 2>/dev/null || echo "SSH rule already exists"

echo "✓ Security group created: $SECURITY_GROUP_ID"
echo ""

# Step 4: Get latest ECS-optimized GPU AMI
echo "Step 4: Finding ECS-optimized GPU AMI..."

AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended \
  --region ${AWS_REGION} \
  --query "Parameters[0].Value" \
  --output text | jq -r '.image_id')

echo "✓ Found AMI: $AMI_ID"
echo ""

# Step 5: Create User Data script
cat > /tmp/ecs-user-data.sh <<'EOF'
#!/bin/bash
echo ECS_CLUSTER=vllm-gpu-cluster >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true >> /etc/ecs/ecs.config
EOF

# Step 6: Launch EC2 instance for ECS
echo "Step 5: Launching GPU instance for ECS..."

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ${AMI_ID} \
  --instance-type ${INSTANCE_TYPE} \
  --iam-instance-profile Name=ecsInstanceProfile-vLLM \
  --security-group-ids ${SECURITY_GROUP_ID} \
  --user-data file:///tmp/ecs-user-data.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=vLLM-ECS-GPU-Instance},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
  --region ${AWS_REGION} \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "✓ Instance launched: $INSTANCE_ID"
echo ""

echo "========================================="
echo "ECS Cluster Setup Complete!"
echo "========================================="
echo ""
echo "Cluster Name: $CLUSTER_NAME"
echo "Instance ID: $INSTANCE_ID"
echo "Security Group: $SECURITY_GROUP_ID"
echo ""
echo "Waiting for instance to join cluster (this takes 2-3 minutes)..."
echo ""
echo "Check status with:"
echo "  aws ecs list-container-instances --cluster ${CLUSTER_NAME} --region ${AWS_REGION}"
echo ""
