#!/bin/bash

# OpenShift UPI GCP Deployment
# Complete automation using Ansible playbook
#
# Usage: ./deploy.sh [basic|full]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_TYPE="${1:-basic}"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Change to script directory
cd "$SCRIPT_DIR"

case "${DEPLOYMENT_TYPE}" in
    basic)
        PLAYBOOK="ansible/openshift-upi-basic.yml"
        ;;
    full)
        PLAYBOOK="ansible/openshift-upi-automation.yml"
        ;;
    *)
        echo "Usage: $0 [basic|full]"
        echo "  basic - Complete deployment with Terraform + OpenShift automation"
        echo "  full  - Advanced deployment with RHCOS management"
        exit 1
        ;;
esac

log "Starting OpenShift UPI deployment with Ansible..."
log "Playbook: $PLAYBOOK"

# Set Ansible environment
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=yaml

# Run the playbook
if ansible-playbook "$PLAYBOOK"; then
    success "OpenShift UPI deployment completed successfully!"
    echo ""
    log "🎉 Your OpenShift cluster is ready!"
    echo "   Export kubeconfig: export KUBECONFIG=clusterconfig/auth/kubeconfig"
    echo "   Check cluster: kubectl get nodes"
else
    echo "Deployment failed! Check the output above for details."
    exit 1
fi
