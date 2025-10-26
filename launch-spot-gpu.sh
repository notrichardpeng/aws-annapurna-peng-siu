#!/bin/bash
set -e

export AWS_REGION=us-west-2
export INSTANCE_TYPE=g4dn.xlarge
export IMAGE_URI=960682159345.dkr.ecr.us-west-2.amazonaws.com/vllm-model-api:latest

echo "========================================="
echo "Launching EC2 Spot GPU Instance"
echo "========================================="
echo "Instance Type: $INSTANCE_TYPE"
echo "Current Spot Price: ~$0.23/hour (vs $0.53 on-demand)"
echo ""

# Get latest Deep Learning AMI with Docker & NVIDIA drivers
echo "Step 1: Finding Deep Learning AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 20.04)*" \
  "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --region ${AWS_REGION} \
  --output text)

echo "✓ Found AMI: $AMI_ID"
echo ""

# Create security group if needed
echo "Step 2: Setting up security group..."
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=vllm-spot-sg" \
  --region ${AWS_REGION} \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null)

if [ "$SECURITY_GROUP_ID" == "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region ${AWS_REGION} --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)

  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name vllm-spot-sg \
    --description "Security group for vLLM Spot instance" \
    --vpc-id ${VPC_ID} \
    --region ${AWS_REGION} \
    --output text \
    --query 'GroupId')

  # Allow HTTP (port 8000)
  aws ec2 authorize-security-group-ingress \
    --group-id ${SECURITY_GROUP_ID} \
    --protocol tcp --port 8000 --cidr 0.0.0.0/0 \
    --region ${AWS_REGION}

  # Allow SSH
  aws ec2 authorize-security-group-ingress \
    --group-id ${SECURITY_GROUP_ID} \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 \
    --region ${AWS_REGION}
fi

echo "✓ Security Group: $SECURITY_GROUP_ID"
echo ""

# Create user data script
cat > /tmp/spot-user-data.sh <<'USERDATA'
#!/bin/bash
set -e

# Log everything
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "Starting vLLM setup..."

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get update
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker
fi

# Configure Docker to use NVIDIA runtime
if [ ! -f /etc/docker/daemon.json ]; then
    echo '{"default-runtime": "nvidia", "runtimes": {"nvidia": {"path": "nvidia-container-runtime", "runtimeArgs": []}}}' > /etc/docker/daemon.json
    systemctl restart docker
fi

# Login to ECR
echo "Logging into ECR..."
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin 960682159345.dkr.ecr.us-west-2.amazonaws.com

# Pull and run container
echo "Pulling vLLM container..."
docker pull 960682159345.dkr.ecr.us-west-2.amazonaws.com/vllm-model-api:latest

echo "Starting vLLM container..."
docker run -d \
  --name vllm-api \
  --gpus all \
  -p 8000:8000 \
  --restart unless-stopped \
  960682159345.dkr.ecr.us-west-2.amazonaws.com/vllm-model-api:latest

echo "✓ vLLM container started successfully!"
USERDATA

# Launch spot instance
echo "Step 3: Requesting spot instance..."

# Create launch spec file
cat > /tmp/spot-launch-spec.json <<EOF
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "SecurityGroupIds": ["${SECURITY_GROUP_ID}"],
  "UserData": "$(cat /tmp/spot-user-data.sh | base64)",
  "IamInstanceProfile": {
    "Name": "ecsInstanceProfile-vLLM"
  }
}
EOF

SPOT_REQUEST=$(aws ec2 request-spot-instances \
  --spot-price "0.40" \
  --instance-count 1 \
  --type "one-time" \
  --launch-specification file:///tmp/spot-launch-spec.json \
  --region ${AWS_REGION} \
  --query 'SpotInstanceRequests[0].SpotInstanceRequestId' \
  --output text)

echo "✓ Spot request created: $SPOT_REQUEST"
echo ""

# Wait for spot request to be fulfilled
echo "Step 4: Waiting for spot instance to launch..."
sleep 5

MAX_WAIT=60
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  STATUS=$(aws ec2 describe-spot-instance-requests \
    --spot-instance-request-ids ${SPOT_REQUEST} \
    --region ${AWS_REGION} \
    --query 'SpotInstanceRequests[0].Status.Code' \
    --output text)

  if [ "$STATUS" == "fulfilled" ]; then
    echo "✓ Spot instance fulfilled!"
    break
  elif [ "$STATUS" == "price-too-low" ] || [ "$STATUS" == "capacity-not-available" ]; then
    echo "❌ Spot request failed: $STATUS"
    exit 1
  fi

  echo "Waiting... Status: $STATUS ($WAIT_COUNT/$MAX_WAIT)"
  sleep 5
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Get instance ID and public IP
INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
  --spot-instance-request-ids ${SPOT_REQUEST} \
  --region ${AWS_REGION} \
  --query 'SpotInstanceRequests[0].InstanceId' \
  --output text)

echo "✓ Instance ID: $INSTANCE_ID"
echo ""

echo "Step 5: Waiting for public IP..."
sleep 10

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids ${INSTANCE_ID} \
  --region ${AWS_REGION} \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "✓ Public IP: $PUBLIC_IP"
echo ""

echo "========================================="
echo "Spot GPU Instance Launched Successfully!"
echo "========================================="
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Cost: ~$0.23/hour (vs $0.53 on-demand)"
echo ""
echo "⏳ Container is starting (takes 5-10 minutes to pull image and load model)..."
echo ""
echo "Monitor progress:"
echo "  ssh -i your-key.pem ubuntu@$PUBLIC_IP 'tail -f /var/log/user-data.log'"
echo ""
echo "Test API (wait 10 minutes):"
echo "  curl http://$PUBLIC_IP:8000/health"
echo "  curl -X POST http://$PUBLIC_IP:8000/generate -H 'Content-Type: application/json' -d '{\"prompt\":\"Hello\"}'"
echo ""
echo "Stop instance when done:"
echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region us-west-2"
echo ""
