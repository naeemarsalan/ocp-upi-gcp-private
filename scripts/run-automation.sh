#!/bin/bash
#
# OpenShift UPI GCP Automation Runner
# Executes the Ansible playbook with proper configuration
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running in correct directory
    if [[ ! -f "main.tf" ]]; then
        log_error "main.tf not found. Please run from the OpenShift UPI directory."
        exit 1
    fi
    
    # Check if Ansible is installed
    if ! command -v ansible-playbook &> /dev/null; then
        log_error "ansible-playbook not found. Please install Ansible."
        echo "Install with: pip install ansible"
        exit 1
    fi
    
    # Check if gcloud is configured
    if ! gcloud auth list --filter="status:ACTIVE" --format="value(account)" | head -1 &> /dev/null; then
        log_error "gcloud not authenticated. Please run: gcloud auth login"
        exit 1
    fi
    
    # Check if SSH keys exist
    if [[ ! -f "keys/id_rsa" ]]; then
        log_error "SSH private key not found at keys/id_rsa"
        exit 1
    fi
    
    # Check if kubeconfig exists (may not exist yet)
    if [[ ! -f "clusterconfig/auth/kubeconfig" ]]; then
        log_warning "Kubeconfig not found - this is expected for new deployments"
    fi
    
    log_success "Prerequisites check completed"
}

# Get GCP project ID
get_project_id() {
    local project_id=$(gcloud config get-value project 2>/dev/null)
    if [[ -z "$project_id" ]]; then
        log_error "GCP project not set. Please run: gcloud config set project YOUR_PROJECT_ID"
        exit 1
    fi
    export GCP_PROJECT="$project_id"
    log_info "Using GCP project: $project_id"
}

# Main execution
main() {
    echo "======================================="
    echo "OpenShift UPI GCP Automation"
    echo "======================================="
    
    check_prerequisites
    get_project_id
    
    log_info "Starting Ansible automation..."
    
    # Run the playbook
    ansible-playbook \
        -i inventory \
        -e @ansible-vars.yml \
        -e gcp_project_id="$GCP_PROJECT" \
        openshift-upi-automation.yml \
        "$@"
    
    if [[ $? -eq 0 ]]; then
        log_success "Automation completed successfully!"
        echo ""
        echo "Next steps:"
        echo "1. Access the OpenShift console at: https://console-openshift-console.apps.ocp.j7ql2.gcp.redhatworkshops.io"
        echo "2. Get the admin password: cat clusterconfig/auth/kubeadmin-password"
        echo "3. SSH to bastion: ssh -i keys/id_rsa ubuntu@\$(gcloud compute instances describe ocp-bastion --zone=us-central1-a --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
    else
        log_error "Automation failed. Check the output above for details."
        exit 1
    fi
}

# Help function
show_help() {
    cat << EOF
OpenShift UPI GCP Automation Runner

Usage: $0 [OPTIONS]

This script automates the post-deployment configuration of OpenShift UPI on GCP.

Tasks performed:
- Create RHCOS image if missing
- Fix DNS records to point to correct nodes
- Set up SSH keys on bastion
- Approve worker node CSRs
- Verify cluster health

Prerequisites:
- Terraform infrastructure deployed (terraform apply completed)
- gcloud CLI configured and authenticated
- SSH keys generated in keys/ directory
- Ansible installed

Options:
  -h, --help     Show this help message
  -v, --verbose  Enable verbose output
  --dry-run      Show what would be done without making changes
  --tags TAGS    Run only specific tasks (comma-separated)

Examples:
  $0                    # Run full automation
  $0 --verbose          # Run with verbose output
  $0 --tags dns         # Run only DNS-related tasks
  $0 --dry-run          # Show what would be done

For more information, see README.md and DEBUG_COMMANDS.md
EOF
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac


