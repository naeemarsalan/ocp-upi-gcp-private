# Manual OpenShift UPI Deployment Walkthrough

This guide provides a complete step-by-step manual deployment process for OpenShift 4.19 UPI on GCP. Use this when you want to understand each step in detail or prefer manual control over the automated deployment scripts.

## Overview

This walkthrough covers the complete manual process:
1. Prerequisites and GCP setup
2. Service account creation and permissions
3. OpenShift ignition config generation
4. RHCOS image preparation
5. Infrastructure deployment with gcloud
6. Bootstrap monitoring and DNS transitions
7. Worker node joining and CSR approval
8. Cluster validation and access

**Time Estimate**: 45-60 minutes for experienced users, 90+ minutes for first-time deployments.

## Phase 1: Prerequisites and Setup

### 1.1 Verify Required Tools

```bash
# Check all required tools are installed
gcloud --version
ansible --version
kubectl version --client
ssh -V

# Download OpenShift installer if not present
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.19.10/openshift-install-linux.tar.gz
tar -xzf openshift-install-linux.tar.gz
chmod +x openshift-install
sudo mv openshift-install /usr/local/bin/
```

### 1.2 GCP Project Setup

```bash
# Authenticate with GCP
gcloud auth login
gcloud auth application-default login

# Set your project
export PROJECT_ID="your-project-id"
gcloud config set project $PROJECT_ID

# Enable required APIs
gcloud services enable compute.googleapis.com
gcloud services enable dns.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable iamcredentials.googleapis.com
gcloud services enable serviceusage.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com

# Verify APIs are enabled
gcloud services list --enabled --filter="name:(compute.googleapis.com OR dns.googleapis.com OR storage.googleapis.com)"
```

### 1.3 SSH Key Generation

```bash
# Create keys directory and generate SSH key pair
mkdir -p keys
ssh-keygen -t rsa -b 4096 -f keys/id_rsa -N ''

# Verify key generation
ls -la keys/
cat keys/id_rsa.pub
```

## Phase 2: Service Accounts and IAM

### 2.1 Create Service Accounts

```bash
# Create OpenShift node service account for cluster operations
gcloud iam service-accounts create ocp-node-sa \
    --display-name="OpenShift Node Service Account" \
    --description="Service account for OpenShift cluster nodes"

# Verify service account created
gcloud iam service-accounts list --filter="email~ocp-node-sa"
```

### 2.2 Assign IAM Roles to Node Service Account

```bash
# OpenShift node service account permissions (ongoing cluster operations)
NODE_SA="ocp-node-sa@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/compute.viewer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/storage.objectViewer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/monitoring.metricWriter"

gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/logging.logWriter"
```

### 2.3 Authentication Notes

No service account keys are required for this walkthrough. Use your user credentials via `gcloud auth login`; the node service account will be attached to VMs as needed.

## Phase 3: OpenShift Configuration

### 3.1 Prepare Install Config

```bash
# Create config directory
mkdir -p config
mkdir -p clusterconfig

# Create install-config.yaml
cat > config/install-config.yaml << 'EOF'
apiVersion: v1
baseDomain: example.com
compute:
- hyperthreading: Enabled
  name: worker
  platform:
    gcp:
      type: e2-standard-4
      zones:
      - us-central1-a
      - us-central1-b
      - us-central1-c
  replicas: 3
controlPlane:
  hyperthreading: Enabled
  name: master
  platform:
    gcp:
      type: e2-standard-4
      zones:
      - us-central1-a
      - us-central1-b
      - us-central1-c
  replicas: 3
metadata:
  creationTimestamp: null
  name: ocp
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  gcp:
    projectID: your-project-id
    region: us-central1
pullSecret: 'your-pull-secret-here'
sshKey: |
  ssh-rsa AAAAB3NzaC1yc2E...your-public-key-here
EOF

# Edit the file with your actual values
vi config/install-config.yaml
```

**Important**: Update the following in `install-config.yaml`:
- `baseDomain`: Your domain name
- `platform.gcp.projectID`: Your GCP project ID
- `pullSecret`: Your Red Hat pull secret from https://console.redhat.com/openshift/install/pull-secret
- `sshKey`: Content of your `keys/id_rsa.pub` file

### 3.2 Generate Ignition Configs

```bash
# Copy install-config.yaml to clusterconfig (it gets consumed)
cp config/install-config.yaml clusterconfig/

# Generate ignition configurations
openshift-install create ignition-configs --dir=clusterconfig

# Verify ignition files created
ls -la clusterconfig/
echo "Bootstrap ignition size: $(wc -c < clusterconfig/bootstrap.ign) bytes"
echo "Master ignition size: $(wc -c < clusterconfig/master.ign) bytes"
echo "Worker ignition size: $(wc -c < clusterconfig/worker.ign) bytes"
```

## Phase 4: RHCOS Image Preparation

### 4.1 Check if RHCOS Image Exists

```bash
# Check if RHCOS image already exists
RHCOS_IMAGE_NAME="rhcos-4-19-10"
if gcloud compute images describe $RHCOS_IMAGE_NAME >/dev/null 2>&1; then
    echo "RHCOS image $RHCOS_IMAGE_NAME already exists"
else
    echo "RHCOS image $RHCOS_IMAGE_NAME does not exist - will create it"
fi
```

### 4.2 Download and Create RHCOS Image (if needed)

```bash
# Only run this section if the image doesn't exist
if ! gcloud compute images describe rhcos-4-19-10 >/dev/null 2>&1; then
    echo "Creating RHCOS image..."
    
    # Create artifacts directory
    mkdir -p artifacts
    
    # Download RHCOS image
    echo "Downloading RHCOS image (this may take 5-10 minutes)..."
    curl -o artifacts/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz \
        https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.19/4.19.10/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz
    
    # Create temporary GCS bucket
    echo "Creating temporary GCS bucket..."
    gsutil mb gs://${PROJECT_ID}-rhcos-temp
    
    # Upload to GCS
    echo "Uploading RHCOS image to GCS (this may take 5-10 minutes)..."
    gsutil cp artifacts/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz gs://${PROJECT_ID}-rhcos-temp/
    
    # Create GCP image
    echo "Creating GCP image..."
    gcloud compute images create rhcos-4-19-10 \
        --source-uri=gs://${PROJECT_ID}-rhcos-temp/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz \
        --guest-os-features=UEFI_COMPATIBLE \
        --description="Red Hat Enterprise Linux CoreOS 4.19.10"
    
    # Cleanup
    echo "Cleaning up temporary files..."
    gsutil rm gs://${PROJECT_ID}-rhcos-temp/rhcos-4.19.10-x86_64-gcp.x86_64.tar.gz
    gsutil rb gs://${PROJECT_ID}-rhcos-temp
    
    echo "RHCOS image created successfully!"
fi
```

## Phase 5: Infrastructure Deployment with gcloud

### 5.1 Set Environment Variables

```bash
# Core variables
export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export CLUSTER_NAME="ocp"
export REGION="us-central1"
export ZONES=("us-central1-a" "us-central1-b" "us-central1-c")
export DOMAIN="ocp.example.com"   # Update with your domain

# Network & CIDRs
export SUBNET_CIDRS=("10.0.1.0/24" "10.0.2.0/24" "10.0.3.0/24")
export POD_CIDRS=("10.128.0.0/16" "10.129.0.0/16" "10.130.0.0/16")
export SERVICE_CIDR="172.30.0.0/16"

# Compute sizing
export CONTROL_TYPE="e2-standard-4"
export WORKER_TYPE="e2-standard-4"
export CONTROL_DISK_GB=120
export WORKER_DISK_GB=120

# Derived variables
export NETWORK="${CLUSTER_NAME}-vpc"
export NODE_SA="ocp-node-sa@${PROJECT_ID}.iam.gserviceaccount.com"
```

### 5.2 Create Network, Subnets, Cloud Router and NAT

```bash
# VPC (custom subnets, regional routing)
gcloud compute networks create ${NETWORK} \
  --subnet-mode=custom \
  --bgp-routing-mode=regional

# Subnets (one per zone) with private Google access and a per-AZ pod secondary range
for i in 0 1 2; do
  gcloud compute networks subnets create ${CLUSTER_NAME}-subnet-$((i+1)) \
    --network=${NETWORK} \
    --region=${REGION} \
    --range=${SUBNET_CIDRS[$i]} \
    --enable-private-ip-google-access \
    --secondary-range pod-cidr-$((i+1))=${POD_CIDRS[$i]}
done

# Cloud Router and NAT for outbound internet
gcloud compute routers create ${CLUSTER_NAME}-router \
  --region=${REGION} \
  --network=${NETWORK}

gcloud compute routers nats create ${CLUSTER_NAME}-nat \
  --router=${CLUSTER_NAME}-router \
  --region=${REGION} \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips \
  --enable-logging --log-filter=errors-only
```

### 5.3 Create Firewall Rules

```bash
# Allow internal cluster communication (tcp/udp/icmp)
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-internal \
  --network=${NETWORK} \
  --allow=tcp,udp,icmp \
  --source-ranges=${SUBNET_CIDRS[0]},${SUBNET_CIDRS[1]},${SUBNET_CIDRS[2]},${POD_CIDRS[0]},${POD_CIDRS[1]},${POD_CIDRS[2]},${SERVICE_CIDR} \
  --target-tags=${CLUSTER_NAME}-cluster

# Allow SSH from internal ranges (adjust as needed)
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-ssh \
  --network=${NETWORK} \
  --allow=tcp:22 \
  --source-ranges=10.0.0.0/8 \
  --target-tags=${CLUSTER_NAME}-cluster

# Allow API server (6443) to control plane
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-api-server \
  --network=${NETWORK} \
  --allow=tcp:6443 \
  --source-ranges=10.0.0.0/8 \
  --target-tags=${CLUSTER_NAME}-control-plane

# Allow Machine Config Server (22623) to bootstrap and control plane
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-mcs \
  --network=${NETWORK} \
  --allow=tcp:22623 \
  --source-ranges=${SUBNET_CIDRS[0]},${SUBNET_CIDRS[1]},${SUBNET_CIDRS[2]} \
  --target-tags=${CLUSTER_NAME}-control-plane,${CLUSTER_NAME}-bootstrap

# Allow Ingress (HTTP/HTTPS) to workers
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-ingress \
  --network=${NETWORK} \
  --allow=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=${CLUSTER_NAME}-worker

# Allow etcd between control planes
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-etcd \
  --network=${NETWORK} \
  --allow=tcp:2379-2380 \
  --source-tags=${CLUSTER_NAME}-control-plane \
  --target-tags=${CLUSTER_NAME}-control-plane

# Allow kubelet from control planes to all nodes
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-kubelet \
  --network=${NETWORK} \
  --allow=tcp:10250 \
  --source-tags=${CLUSTER_NAME}-control-plane \
  --target-tags=${CLUSTER_NAME}-cluster
```

### 5.4 Optional: Bastion Host Access Rules

```bash
# SSH to bastion from anywhere (optional)
gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-bastion-ssh \
  --network=${NETWORK} \
  --allow=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=${CLUSTER_NAME}-bastion

# Allow bastion to access internal cluster ports
gcloud compute firewall-rules create ${CLUSTER_NAME}-bastion-to-internal \
  --network=${NETWORK} \
  --allow=tcp:22,tcp:80,tcp:443,tcp:6443,tcp:22623 \
  --source-tags=${CLUSTER_NAME}-bastion \
  --target-tags=${CLUSTER_NAME}-cluster
```

### 5.5 Prepare Bootstrap Ignition Delivery (GCS)

```bash
# Create a bucket and upload bootstrap.ign (pointer pattern to bypass metadata limit)
export BOOTSTRAP_BUCKET="${CLUSTER_NAME}-bootstrap-ignition-$(openssl rand -hex 4)"
gsutil mb -l ${REGION} gs://${BOOTSTRAP_BUCKET}

# Make objects publicly readable so RHCOS can fetch early in boot (restrict later)
gsutil iam ch allUsers:objectViewer gs://${BOOTSTRAP_BUCKET}

# Upload bootstrap ignition
gsutil cp clusterconfig/bootstrap.ign gs://${BOOTSTRAP_BUCKET}/bootstrap.ign

# Create a tiny pointer ignition referencing the GCS object
mkdir -p artifacts
cat > artifacts/bootstrap-pointer.ign <<EOF
{ "ignition": { "version": "3.2.0", "config": { "merge": [ { "source": "https://storage.googleapis.com/${BOOTSTRAP_BUCKET}/bootstrap.ign" } ] } } }
EOF
```

### 5.6 Create Compute Instances

```bash
# Bootstrap (no external IP)
gcloud compute instances create ${CLUSTER_NAME}-bootstrap \
  --zone=${ZONES[0]} \
  --machine-type=${CONTROL_TYPE} \
  --image=rhcos-4-19-10 \
  --image-project=${PROJECT_ID} \
  --subnet=${CLUSTER_NAME}-subnet-1 \
  --no-address \
  --tags=${CLUSTER_NAME}-bootstrap,${CLUSTER_NAME}-cluster \
  --scopes=cloud-platform \
  --service-account=${NODE_SA} \
  --metadata-from-file=user-data=artifacts/bootstrap-pointer.ign \
  --create-disk=auto-delete=yes,boot=yes,device-name=${CLUSTER_NAME}-bootstrap,image-project=${PROJECT_ID},image=rhcos-4-19-10,mode=rw,size=${CONTROL_DISK_GB},type=pd-ssd

# Control planes (3) across zones (no external IPs)
for i in 0 1 2; do
  gcloud compute instances create ${CLUSTER_NAME}-control-$((i+1)) \
    --zone=${ZONES[$i]} \
    --machine-type=${CONTROL_TYPE} \
    --image=rhcos-4-19-10 \
    --image-project=${PROJECT_ID} \
    --subnet=${CLUSTER_NAME}-subnet-$((i+1)) \
    --no-address \
    --tags=${CLUSTER_NAME}-control-plane,${CLUSTER_NAME}-cluster \
    --scopes=cloud-platform \
    --service-account=${NODE_SA} \
    --metadata-from-file=user-data=clusterconfig/master.ign \
    --create-disk=auto-delete=yes,boot=yes,device-name=${CLUSTER_NAME}-control-$((i+1)),image-project=${PROJECT_ID},image=rhcos-4-19-10,mode=rw,size=${CONTROL_DISK_GB},type=pd-ssd
done

# Workers (3) across zones (no external IPs)
for i in 0 1 2; do
  gcloud compute instances create ${CLUSTER_NAME}-worker-$((i+1)) \
    --zone=${ZONES[$i]} \
    --machine-type=${WORKER_TYPE} \
    --image=rhcos-4-19-10 \
    --image-project=${PROJECT_ID} \
    --subnet=${CLUSTER_NAME}-subnet-$((i+1)) \
    --no-address \
    --tags=${CLUSTER_NAME}-worker,${CLUSTER_NAME}-cluster \
    --scopes=cloud-platform \
    --service-account=${NODE_SA} \
    --metadata-from-file=user-data=clusterconfig/worker.ign \
    --create-disk=auto-delete=yes,boot=yes,device-name=${CLUSTER_NAME}-worker-$((i+1)),image-project=${PROJECT_ID},image=rhcos-4-19-10,mode=rw,size=${WORKER_DISK_GB},type=pd-ssd
done

# Optional Bastion (with external IP) for admin access
gcloud compute instances create ${CLUSTER_NAME}-bastion \
  --zone=${ZONES[0]} \
  --machine-type=e2-micro \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --subnet=${CLUSTER_NAME}-subnet-1 \
  --tags=${CLUSTER_NAME}-bastion \
  --metadata="ssh-keys=ubuntu:$(cat keys/id_rsa.pub)" \
  --create-disk=auto-delete=yes,boot=yes,device-name=${CLUSTER_NAME}-bastion,size=20,type=pd-standard
```

### 5.7 Configure Private DNS

```bash
# Create private managed zone
gcloud dns managed-zones create ${CLUSTER_NAME}-zone \
  --dns-name="${DOMAIN}." \
  --visibility=private \
  --private-visibility-network=${NETWORK}

# Collect internal IPs
export BOOTSTRAP_IP=$(gcloud compute instances describe ${CLUSTER_NAME}-bootstrap --zone=${ZONES[0]} --format='get(networkInterfaces[0].networkIP)')
export CONTROL_IP1=$(gcloud compute instances describe ${CLUSTER_NAME}-control-1 --zone=${ZONES[0]} --format='get(networkInterfaces[0].networkIP)')
export CONTROL_IP2=$(gcloud compute instances describe ${CLUSTER_NAME}-control-2 --zone=${ZONES[1]} --format='get(networkInterfaces[0].networkIP)')
export CONTROL_IP3=$(gcloud compute instances describe ${CLUSTER_NAME}-control-3 --zone=${ZONES[2]} --format='get(networkInterfaces[0].networkIP)')
export WORKER_IP1=$(gcloud compute instances describe ${CLUSTER_NAME}-worker-1 --zone=${ZONES[0]} --format='get(networkInterfaces[0].networkIP)')
export WORKER_IP2=$(gcloud compute instances describe ${CLUSTER_NAME}-worker-2 --zone=${ZONES[1]} --format='get(networkInterfaces[0].networkIP)')
export WORKER_IP3=$(gcloud compute instances describe ${CLUSTER_NAME}-worker-3 --zone=${ZONES[2]} --format='get(networkInterfaces[0].networkIP)')

# Create initial records (api -> control planes, api-int -> bootstrap, *.apps -> workers)
gcloud dns record-sets transaction start --zone=${CLUSTER_NAME}-zone
gcloud dns record-sets transaction add --zone=${CLUSTER_NAME}-zone \
  --name="api.${DOMAIN}." --type=A --ttl=300 ${CONTROL_IP1} ${CONTROL_IP2} ${CONTROL_IP3}
gcloud dns record-sets transaction add --zone=${CLUSTER_NAME}-zone \
  --name="api-int.${DOMAIN}." --type=A --ttl=300 ${BOOTSTRAP_IP}
gcloud dns record-sets transaction add --zone=${CLUSTER_NAME}-zone \
  --name="*.apps.${DOMAIN}." --type=A --ttl=300 ${WORKER_IP1} ${WORKER_IP2} ${WORKER_IP3}
gcloud dns record-sets transaction execute --zone=${CLUSTER_NAME}-zone

# Capture bastion external IP for later use
export BASTION_IP=$(gcloud compute instances describe ${CLUSTER_NAME}-bastion --zone=${ZONES[0]} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
echo "Bastion IP: ${BASTION_IP}"
echo "Bootstrap IP: ${BOOTSTRAP_IP}"
```

### 5.8 Verify Resources

```bash
# Check instances
gcloud compute instances list --filter="name~${CLUSTER_NAME}-" --format="table(name,status,zone.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP)"

# Check DNS zone and records
gcloud dns managed-zones list --filter="name=${CLUSTER_NAME}-zone"
gcloud dns record-sets list --zone=${CLUSTER_NAME}-zone
```

## Phase 6: Bootstrap and Control Plane Setup

### 6.1 Copy Configuration to Bastion

```bash
# Copy kubeconfig and SSH keys to bastion
scp -i keys/id_rsa clusterconfig/auth/kubeconfig ubuntu@$BASTION_IP:~/
scp -i keys/id_rsa keys/id_rsa ubuntu@$BASTION_IP:~/.ssh/

# Download kubectl on bastion
ssh -i keys/id_rsa ubuntu@$BASTION_IP "
    curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    echo 'export KUBECONFIG=~/kubeconfig' >> ~/.bashrc
"
```

### 6.2 Monitor Bootstrap Process

```bash
# Monitor bootstrap logs
echo "Monitoring bootstrap node startup..."
gcloud compute instances get-serial-port-output ocp-bootstrap --zone=us-central1-a | tail -20

# Wait for bootstrap to be ready (check every 2 minutes)
echo "Waiting for bootstrap to complete... (this takes 15-20 minutes)"
while true; do
    # Check if Machine Config Server is responding
    if ssh -i keys/id_rsa ubuntu@$BASTION_IP "curl -k -s --connect-timeout 5 https://$BOOTSTRAP_IP:22623/healthz" | grep -q "ok"; then
        echo "Bootstrap Machine Config Server is ready!"
        break
    fi
    echo "Bootstrap not ready yet, waiting 2 more minutes..."
    sleep 120
done
```

### 6.3 Monitor Control Plane Startup

```bash
# Check control plane nodes are getting their configs
echo "Monitoring control plane startup..."
for i in 1 2 3; do
    echo "=== Control Plane $i ==="
    gcloud compute instances get-serial-port-output ocp-control-$i --zone=us-central1-a | grep -E "(ignition|success|Failed)" | tail -5
done

# Wait for control planes to be ready
echo "Waiting for control planes to join cluster..."
ssh -i keys/id_rsa ubuntu@$BASTION_IP "
    export KUBECONFIG=~/kubeconfig
    while [ \$(kubectl get nodes --no-headers 2>/dev/null | grep -c master) -lt 3 ]; do
        echo 'Waiting for control planes to join... (\$(kubectl get nodes --no-headers 2>/dev/null | grep -c master || echo 0)/3 ready)'
        sleep 60
    done
    echo 'All control planes have joined!'
    kubectl get nodes
"
```

## Phase 7: DNS Transition

### 7.1 Update API DNS Records

Once control planes are ready, update DNS to point API endpoints to control planes instead of bootstrap:

```bash
# Get control plane IPs
CONTROL_IP1=$(gcloud compute instances describe ${CLUSTER_NAME}-control-1 --zone=${ZONES[0]} --format='get(networkInterfaces[0].networkIP)')
CONTROL_IP2=$(gcloud compute instances describe ${CLUSTER_NAME}-control-2 --zone=${ZONES[1]} --format='get(networkInterfaces[0].networkIP)')
CONTROL_IP3=$(gcloud compute instances describe ${CLUSTER_NAME}-control-3 --zone=${ZONES[2]} --format='get(networkInterfaces[0].networkIP)')

echo "Control plane IPs: $CONTROL_IP1, $CONTROL_IP2, $CONTROL_IP3"

# Update api-int DNS record to point to control planes
echo "Updating api-int DNS record..."
gcloud dns record-sets transaction start --zone=${CLUSTER_NAME}-zone
gcloud dns record-sets transaction remove --zone=${CLUSTER_NAME}-zone \
    --name=api-int.${DOMAIN}. \
    --type=A --ttl=300 $BOOTSTRAP_IP
gcloud dns record-sets transaction add --zone=${CLUSTER_NAME}-zone \
    --name=api-int.${DOMAIN}. \
    --type=A --ttl=300 $CONTROL_IP1 $CONTROL_IP2 $CONTROL_IP3
gcloud dns record-sets transaction execute --zone=${CLUSTER_NAME}-zone

echo "DNS transition completed!"

# Verify DNS update
gcloud dns record-sets list --zone=${CLUSTER_NAME}-zone | grep api-int
```

## Phase 8: Worker Node Setup

### 8.1 Monitor Worker Startup

```bash
# Check worker nodes are starting
echo "Monitoring worker node startup..."
for i in 1 2 3; do
    echo "=== Worker $i ==="
    gcloud compute instances get-serial-port-output ocp-worker-$i --zone=us-central1-a | grep -E "(ignition|success|Failed)" | tail -3
done
```

### 8.2 Approve Certificate Signing Requests

```bash
# Check for pending CSRs and approve them
echo "Checking for pending Certificate Signing Requests..."
ssh -i keys/id_rsa ubuntu@$BASTION_IP "
    export KUBECONFIG=~/kubeconfig
    
    # Function to approve CSRs
    approve_csrs() {
        pending_csrs=\$(kubectl get csr --no-headers | grep Pending | awk '{print \$1}')
        if [ -n \"\$pending_csrs\" ]; then
            echo \"Approving CSRs: \$pending_csrs\"
            echo \"\$pending_csrs\" | xargs kubectl certificate approve
            return 0
        else
            echo \"No pending CSRs found\"
            return 1
        fi
    }
    
    # Approve initial worker CSRs
    echo 'Waiting for and approving worker CSRs...'
    for i in {1..10}; do
        if approve_csrs; then
            echo \"Approved CSRs in round \$i\"
            sleep 30
        else
            echo \"No CSRs in round \$i, waiting...\"
            sleep 60
        fi
    done
    
    # Check final node status
    echo 'Final node status:'
    kubectl get nodes
"
```

### 8.3 Wait for Workers to Join

```bash
# Wait for all workers to join
ssh -i keys/id_rsa ubuntu@$BASTION_IP "
    export KUBECONFIG=~/kubeconfig
    echo 'Waiting for all workers to join cluster...'
    while [ \$(kubectl get nodes --no-headers | grep -c worker) -lt 3 ]; do
        current_workers=\$(kubectl get nodes --no-headers | grep -c worker || echo 0)
        echo \"Workers joined: \$current_workers/3\"
        
        # Check for more CSRs
        pending=\$(kubectl get csr --no-headers | grep Pending | wc -l)
        if [ \$pending -gt 0 ]; then
            echo \"Found \$pending pending CSRs, approving...\"
            kubectl get csr --no-headers | grep Pending | awk '{print \$1}' | xargs kubectl certificate approve
        fi
        
        sleep 60
    done
    
    echo 'All workers have joined!'
    kubectl get nodes
"
```

## Phase 9: Cluster Validation

### 9.1 Check Cluster Status

```bash
# Comprehensive cluster status check
ssh -i keys/id_rsa ubuntu@$BASTION_IP "
    export KUBECONFIG=~/kubeconfig
    
    echo '=== CLUSTER NODES ==='
    kubectl get nodes -o wide
    
    echo -e '\n=== CLUSTER OPERATORS ==='
    kubectl get clusteroperators
    
    echo -e '\n=== CLUSTER VERSION ==='
    kubectl get clusterversion
    
    echo -e '\n=== PENDING CSRS ==='
    kubectl get csr | grep Pending || echo 'No pending CSRs'
    
    echo -e '\n=== CLUSTER PODS STATUS ==='
    kubectl get pods --all-namespaces | grep -v Running | grep -v Completed || echo 'All pods running or completed'
"
```

### 9.2 Test Application Access

```bash
# Get worker IPs and update apps DNS
WORKER_IP1=$(gcloud compute instances describe ${CLUSTER_NAME}-worker-1 --zone=${ZONES[0]} --format='get(networkInterfaces[0].networkIP)')
WORKER_IP2=$(gcloud compute instances describe ${CLUSTER_NAME}-worker-2 --zone=${ZONES[1]} --format='get(networkInterfaces[0].networkIP)')
WORKER_IP3=$(gcloud compute instances describe ${CLUSTER_NAME}-worker-3 --zone=${ZONES[2]} --format='get(networkInterfaces[0].networkIP)')

echo "Worker IPs: $WORKER_IP1, $WORKER_IP2, $WORKER_IP3"

# Update apps DNS to point to workers
echo "Updating *.apps DNS record..."
gcloud dns record-sets transaction start --zone=${CLUSTER_NAME}-zone
# Remove any existing apps record (this might fail if it doesn't exist)
gcloud dns record-sets transaction remove --zone=${CLUSTER_NAME}-zone \
    --name=*.apps.${DOMAIN}. \
    --type=A --ttl=300 10.0.1.10 2>/dev/null || true
gcloud dns record-sets transaction add --zone=${CLUSTER_NAME}-zone \
    --name=*.apps.${DOMAIN}. \
    --type=A --ttl=300 $WORKER_IP1 $WORKER_IP2 $WORKER_IP3
gcloud dns record-sets transaction execute --zone=${CLUSTER_NAME}-zone

# Test console access
echo "Testing console access..."
ssh -i keys/id_rsa ubuntu@$BASTION_IP "
    export KUBECONFIG=~/kubeconfig
    
    # Get console route
    console_host=\$(kubectl get route console -n openshift-console -o jsonpath='{.spec.host}')
    echo \"Console URL: https://\$console_host\"
    
    # Test console access from a worker node
    worker_ip=\"$WORKER_IP1\"
    if ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no core@\$worker_ip \"curl -H 'Host: \$console_host' https://localhost -k -s\" | grep -q 'Red Hat OpenShift'; then
        echo 'Console is accessible!'
    else
        echo 'Console access test failed'
    fi
"
```

### 9.3 Get Cluster Access Information

```bash
# Get kubeadmin password and console URL
ssh -i keys/id_rsa ubuntu@$BASTION_IP "
    export KUBECONFIG=~/kubeconfig
    
    echo '=== CLUSTER ACCESS INFORMATION ==='
    echo 'Kubeadmin password:'
    cat clusterconfig/auth/kubeadmin-password || echo 'Password file not found on bastion'
    
    echo -e '\nConsole URL:'
    kubectl get route console -n openshift-console -o jsonpath='{.spec.host}' && echo
    
    echo -e '\nAPI URL:'
    kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' && echo
    
    echo -e '\nTo access from your local machine:'
    echo '1. Copy the kubeconfig file from the bastion'
    echo '2. Set KUBECONFIG environment variable'
    echo '3. Use kubectl or oc commands'
"

# Copy kubeconfig back to local machine
echo "Copying kubeconfig to local machine..."
scp -i keys/id_rsa ubuntu@$BASTION_IP:~/kubeconfig ./kubeconfig
echo "Kubeconfig copied to ./kubeconfig"
echo "To use: export KUBECONFIG=$(pwd)/kubeconfig"
```

## Phase 10: Post-Deployment Cleanup

### 10.1 Remove Bootstrap Node (Optional)

```bash
# Once cluster is stable, you can remove the bootstrap node and cleanup GCS
echo "Bootstrap node can be safely removed now"
gcloud compute instances delete ${CLUSTER_NAME}-bootstrap --zone=${ZONES[0]} --quiet

# Remove bootstrap ignition object and bucket (if no longer needed)
gsutil rm gs://${BOOTSTRAP_BUCKET}/bootstrap.ign || true
gsutil rb gs://${BOOTSTRAP_BUCKET} || true
```

### 10.2 Tighten Access and Permissions

```bash
# Optionally remove public read from the bootstrap bucket (if you kept it)
if [ -n "${BOOTSTRAP_BUCKET}" ]; then
  echo "Removing public read access from gs://${BOOTSTRAP_BUCKET} (if present)"
  gsutil iam ch -d allUsers:objectViewer gs://${BOOTSTRAP_BUCKET} || true
fi

echo "OpenShift node service account retains minimal required permissions (viewer, logging, monitoring). Review and tighten as needed."
```

## Troubleshooting Common Issues

### Bootstrap Issues
- **Bootstrap not starting**: Check RHCOS image exists and ignition file is valid
- **Bootstrap stuck**: Check internet connectivity and DNS resolution
- **MCS not responding**: Wait longer, check bootstrap node serial console logs

### Control Plane Issues
- **Control planes not joining**: Verify api-int DNS points to bootstrap initially
- **Control planes stuck in ignition**: Check MCS on bootstrap is accessible
- **DNS resolution failures**: Verify private DNS zone configuration

### Worker Issues
- **Workers not joining**: Check for pending CSRs that need approval
- **CSR approval fails**: Verify kubeconfig is valid and API is accessible
- **Workers stuck in ignition**: Verify api-int DNS points to control planes

### Console Access Issues
- **Console not accessible**: Check *.apps DNS points to worker nodes
- **DNS not resolving**: Wait for DNS propagation (up to 15 minutes)
- **Connection refused**: Verify router pods are running on workers

### General Debugging
```bash
# Check all cluster component status
kubectl get pods --all-namespaces | grep -v Running

# Check cluster operators
kubectl get clusteroperators | grep -v "True.*False.*False"

# Check node logs
ssh -i keys/id_rsa ubuntu@$BASTION_IP "ssh -i ~/.ssh/id_rsa core@NODE_IP 'journalctl -u kubelet -f'"

# Check DNS resolution
ssh -i keys/id_rsa ubuntu@$BASTION_IP "nslookup api.ocp.example.com"
```

## Next Steps

1. **Install additional operators** from OperatorHub
2. **Configure persistent storage** for applications
3. **Set up monitoring** and logging
4. **Configure authentication** providers
5. **Deploy applications** to your new cluster

## Complete Deployment Verification

Your manual deployment is complete when:
- All nodes show "Ready" status
- All cluster operators show "Available=True, Progressing=False, Degraded=False"
- Console is accessible via the apps domain
- You can successfully run `kubectl` commands

**Congratulations!** You have successfully deployed OpenShift 4.19 UPI on GCP manually.

## Time Investment Summary

**Total time for manual deployment**: 45-90 minutes
- Prerequisites and setup: 10-15 minutes
- Service accounts and IAM: 5-10 minutes
- OpenShift configuration: 10-15 minutes
- RHCOS image preparation: 10-20 minutes (if creating new)
- Infrastructure deployment: 10-15 minutes
- Bootstrap and control plane: 15-20 minutes
- Worker setup and validation: 10-15 minutes

**Benefits of manual approach**:
- Complete understanding of each step
- Ability to customize each phase
- Better troubleshooting knowledge
- Learning the underlying OpenShift architecture

**When to use manual vs automated**:
- Use manual for learning, customization, or troubleshooting
- Use automated (`./deploy.sh`) for regular deployments and CI/CD
