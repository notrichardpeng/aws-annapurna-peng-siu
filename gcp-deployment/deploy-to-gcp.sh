#!/bin/bash
set -e

# Configuration
export GCP_PROJECT_ID=${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}
export GCP_REGION="us-central1"
export GCP_ZONE="us-central1-a"
export INSTANCE_NAME="vllm-gpu-instance"
export MACHINE_TYPE="n1-standard-4"
export GPU_TYPE="nvidia-tesla-t4"
export GPU_COUNT=1

echo "========================================="
echo "Deploying vLLM to Google Cloud Platform"
echo "========================================="
echo "Project: $GCP_PROJECT_ID"
echo "Region: $GCP_REGION"
echo "Zone: $GCP_ZONE"
echo "GPU: $GPU_TYPE"
echo ""

# Step 1: Enable required APIs
echo "Step 1: Enabling required APIs..."
gcloud services enable compute.googleapis.com \
  containerregistry.googleapis.com \
  --project=$GCP_PROJECT_ID

echo "✓ APIs enabled"
echo ""

# Step 2: Check GPU quota
echo "Step 2: Checking GPU quota..."
QUOTA=$(gcloud compute regions describe $GCP_REGION \
  --project=$GCP_PROJECT_ID \
  --format="value(quotas.filter(metric:NVIDIA_T4_GPUS).limit)" 2>/dev/null || echo "0")

if [ "$QUOTA" == "0" ]; then
  echo "⚠️  GPU quota is 0. Requesting quota increase..."
  echo ""
  echo "Please visit:"
  echo "https://console.cloud.google.com/iam-admin/quotas?project=$GCP_PROJECT_ID"
  echo ""
  echo "Search for: 'NVIDIA T4 GPUs'"
  echo "Region: $GCP_REGION"
  echo "Request: 1 GPU"
  echo ""
  read -p "Press Enter after requesting quota increase..."
else
  echo "✓ GPU quota available: $QUOTA"
fi
echo ""

# Step 3: Tag and push Docker image to GCR
echo "Step 3: Pushing Docker image to Google Container Registry..."

# Tag image for GCR
docker tag vllm-model-api:latest gcr.io/$GCP_PROJECT_ID/vllm-model-api:latest

# Configure Docker to use gcloud as credential helper
gcloud auth configure-docker --quiet

# Push to GCR
docker push gcr.io/$GCP_PROJECT_ID/vllm-model-api:latest

echo "✓ Image pushed to GCR"
echo ""

# Step 4: Create firewall rule
echo "Step 4: Creating firewall rule..."
gcloud compute firewall-rules create allow-vllm-api \
  --allow=tcp:8000 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=vllm-server \
  --project=$GCP_PROJECT_ID \
  2>/dev/null || echo "Firewall rule already exists"

echo "✓ Firewall configured"
echo ""

# Step 5: Create startup script
cat > /tmp/gcp-startup-script.sh <<'STARTUP'
#!/bin/bash
set -e

# Log everything
exec > >(tee /var/log/startup-script.log)
exec 2>&1

echo "Starting vLLM setup on GCP..."

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
fi

# Install nvidia-docker2
if ! dpkg -l | grep -q nvidia-docker2; then
    echo "Installing NVIDIA Docker..."
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
        tee /etc/apt/sources.list.d/nvidia-docker.list
    apt-get update
    apt-get install -y nvidia-docker2
    systemctl restart docker
fi

# Configure Docker to use GCR
gcloud auth configure-docker --quiet

# Pull and run container
echo "Pulling vLLM container from GCR..."
PROJECT_ID=$(curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/project/project-id)

docker pull gcr.io/$PROJECT_ID/vllm-model-api:latest

echo "Starting vLLM container..."
docker run -d \
  --name vllm-api \
  --gpus all \
  --restart unless-stopped \
  -p 8000:8000 \
  gcr.io/$PROJECT_ID/vllm-model-api:latest

echo "✓ vLLM container started successfully!"
STARTUP

# Step 6: Create GCE instance with GPU
echo "Step 5: Launching GPU instance..."

gcloud compute instances create $INSTANCE_NAME \
  --project=$GCP_PROJECT_ID \
  --zone=$GCP_ZONE \
  --machine-type=$MACHINE_TYPE \
  --accelerator=type=$GPU_TYPE,count=$GPU_COUNT \
  --maintenance-policy=TERMINATE \
  --image-family=pytorch-latest-gpu \
  --image-project=deeplearning-platform-release \
  --boot-disk-size=100GB \
  --boot-disk-type=pd-standard \
  --metadata-from-file startup-script=/tmp/gcp-startup-script.sh \
  --tags=vllm-server \
  --scopes=cloud-platform

echo "✓ Instance created"
echo ""

# Step 7: Get external IP
echo "Step 6: Getting external IP..."
sleep 10

EXTERNAL_IP=$(gcloud compute instances describe $INSTANCE_NAME \
  --zone=$GCP_ZONE \
  --project=$GCP_PROJECT_ID \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo "✓ External IP: $EXTERNAL_IP"
echo ""

echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Instance: $INSTANCE_NAME"
echo "External IP: $EXTERNAL_IP"
echo "Zone: $GCP_ZONE"
echo "GPU: $GPU_TYPE"
echo ""
echo "⏳ Container is starting (wait 5-10 minutes for image pull and model load)..."
echo ""
echo "Monitor progress:"
echo "  gcloud compute ssh $INSTANCE_NAME --zone=$GCP_ZONE --command='tail -f /var/log/startup-script.log'"
echo ""
echo "Test API (wait 10 minutes):"
echo "  curl http://$EXTERNAL_IP:8000/health"
echo "  curl -X POST http://$EXTERNAL_IP:8000/generate -H 'Content-Type: application/json' -d '{\"prompt\":\"Hello\"}'"
echo ""
echo "Stop instance when done:"
echo "  gcloud compute instances stop $INSTANCE_NAME --zone=$GCP_ZONE"
echo ""
echo "Delete instance:"
echo "  gcloud compute instances delete $INSTANCE_NAME --zone=$GCP_ZONE"
echo ""
