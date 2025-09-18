#!/bin/bash

# OpenShift UPI GCP Basic Deployment Automation
# This script runs the simplified Ansible playbook for basic deployment
#
# Usage: ./run-basic-automation.sh
#
# Prerequisites:
# - gcloud CLI configured and authenticated
# - ansible installed
# - Terraform applied (infrastructure deployed)

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="../ansible/openshift-upi-basic.yml"
VARS_FILE="../ansible/ansible-vars.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Change to script directory
cd "$SCRIPT_DIR"

log "Starting basic OpenShift UPI deployment automation..."

# Check prerequisites
log "Checking prerequisites..."

# Check if gcloud is installed and authenticated
if ! command -v gcloud &> /dev/null; then
    error "gcloud CLI is not installed or not in PATH"
    exit 1
fi

# Check if gcloud is authenticated
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
    error "gcloud is not authenticated. Run 'gcloud auth login'"
    exit 1
fi

# Check if ansible is installed
if ! command -v ansible-playbook &> /dev/null; then
    error "ansible is not installed or not in PATH"
    error "Install with: pip install ansible"
    exit 1
fi

# Check if required files exist
for file in "$PLAYBOOK" "$VARS_FILE"; do
    if [[ ! -f "$file" ]]; then
        error "Required file not found: $file"
        exit 1
    fi
done

# Check if SSH key exists
if [[ ! -f "../keys/id_rsa" ]]; then
    error "SSH private key not found: ../keys/id_rsa"
    error "Generate keys with: ssh-keygen -t rsa -b 4096 -f ../keys/id_rsa -N ''"
    exit 1
fi

# Check if kubeconfig exists
if [[ ! -f "../clusterconfig/auth/kubeconfig" ]]; then
    error "kubeconfig not found: ../clusterconfig/auth/kubeconfig"
    error "Ensure OpenShift installer has run and generated the kubeconfig"
    exit 1
fi

success "All prerequisites met"

# Get current GCP project
GCP_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")
if [[ -z "$GCP_PROJECT" ]]; then
    error "GCP project not set. Run 'gcloud config set project PROJECT_ID'"
    exit 1
fi

log "Using GCP project: $GCP_PROJECT"

# Run the playbook
log "Running basic deployment playbook: $PLAYBOOK"
log "Tasks: Wait for bootstrap → Wait for control planes → Flip api-int DNS"

# Set additional environment variables
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=yaml

ANSIBLE_CMD="ansible-playbook $PLAYBOOK"

log "Executing: $ANSIBLE_CMD"
echo "=========================================="

if eval "$ANSIBLE_CMD"; then
    echo "=========================================="
    success "Basic OpenShift UPI deployment completed successfully!"
    
    log "Next steps:"
    echo "  1. Workers should join automatically now"
    echo "  2. Monitor cluster: ssh to bastion and run 'kubectl get nodes -w'"
    echo "  3. Check cluster operators: 'kubectl get clusteroperators'"
    
else
    echo "=========================================="
    error "Basic deployment failed!"
    error "Check the output above for details"
    exit 1
fi

log "Basic automation complete"


