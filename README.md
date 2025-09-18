# OpenShift 4.19 UPI on GCP

Complete automation for deploying OpenShift 4.19 User Provisioned Infrastructure (UPI) on Google Cloud Platform.

## Quick Start

```bash
# 1. Configure your deployment
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your values

# 2. Generate SSH keys
ssh-keygen -t rsa -b 4096 -f keys/id_rsa -N ''

# 3. Deploy everything (infrastructure + OpenShift)
./deploy.sh
```

That's it! The script handles:
- Terraform infrastructure deployment
- Bootstrap phase completion
- Control plane setup
- Worker node joining with automatic CSR approval
- Complete cluster validation

## Repository Structure

```
├── deploy.sh                 # Main deployment script (Ansible-based)
├── terraform/                # Infrastructure as Code
│   ├── main.tf              # Core infrastructure definition
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Output values
│   ├── providers.tf         # Provider configuration
│   └── terraform.tfvars.example
├── ansible/                  # OpenShift automation
│   ├── openshift-upi-basic.yml     # Basic deployment automation
│   ├── openshift-upi-automation.yml # Full automation with RHCOS management
│   ├── ansible-vars.yml     # Ansible variables
│   └── inventory            # Ansible inventory
├── scripts/                  # Utility scripts
│   ├── run-basic-automation.sh     # Basic OpenShift automation
│   ├── run-automation.sh    # Full automation
│   └── start.sh             # Legacy start script
├── docs/                     # Documentation
│   ├── README.md            # Detailed technical documentation
│   ├── DEBUG_COMMANDS.md    # Troubleshooting guide
│   └── GCP_PERMISSIONS.md   # GCP IAM requirements
├── config/                   # OpenShift configuration
│   └── install-config.yaml
├── clusterconfig/           # Generated cluster files (created by openshift-install)
├── keys/                    # SSH keys (generate with ssh-keygen)
└── artifacts/               # Downloaded files (RHCOS images, etc.)
```

## Prerequisites

### Required Tools
- **gcloud CLI** - [Install Guide](https://cloud.google.com/sdk/docs/install)
- **terraform** - [Install Guide](https://www.terraform.io/downloads.html)
- **ansible** - `pip install ansible`
- **kubectl** - [Install Guide](https://kubernetes.io/docs/tasks/tools/)

### GCP Setup
1. **Authenticate with GCP:**
   ```bash
   gcloud auth login
   gcloud config set project YOUR_PROJECT_ID
   ```

2. **Enable Required APIs:**
   ```bash
   gcloud services enable compute.googleapis.com
   gcloud services enable dns.googleapis.com
   gcloud services enable storage.googleapis.com
   gcloud services enable iam.googleapis.com
   ```

3. **Configure Permissions:** 
   See **[GCP_PERMISSIONS.md](docs/GCP_PERMISSIONS.md)** for detailed IAM setup including:
   - Required user account permissions
   - Service account creation and roles
   - API enablement
   - Security best practices

## Configuration

### 1. Configure Terraform Variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:
```hcl
# Required: Your GCP project
project_id = "your-gcp-project-id"

# Required: Your domain (will create DNS zone)
domain_name = "ocp.example.com"

# Required: Your SSH public key
ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2E..."

# Optional: Customize cluster name, machine types, etc.
cluster_name = "ocp"
region = "us-central1"
```

### 2. Generate SSH Keys

```bash
ssh-keygen -t rsa -b 4096 -f keys/id_rsa -N ''
```

### 3. Configure OpenShift (Optional)

The default configuration works for most deployments. To customize:

```bash
# Edit OpenShift installer config
vi config/install-config.yaml

# Edit Ansible variables
vi ansible/ansible-vars.yml
```

## Deployment Options

### Automated Deployment (Recommended)
Complete end-to-end deployment with essential automation:

```bash
./deploy.sh basic
# OR simply:
./deploy.sh
```

**What it does:**
1. **Prerequisites**: Validates tools and configuration
2. **Ignition**: Generates OpenShift ignition configs
3. **RHCOS**: Manages RHCOS image (downloads if needed)
4. **Infrastructure**: Deploys VMs, networks, DNS with Terraform
5. **Bootstrap**: Waits for bootstrap and control planes
6. **DNS Transition**: Switches api-int from bootstrap to control planes
7. **Workers**: Automatically approves CSRs and joins workers
8. **Validation**: Verifies cluster health

### Full Deployment (Advanced Automation)
Includes additional automation features:

```bash
./deploy.sh full
```

**Additional features:**
- Extended RHCOS image management
- Advanced cluster operator monitoring
- Comprehensive status reporting

### Manual Deployment (Educational)
Step-by-step manual deployment for learning and customization:

**See**: **[MANUAL_WALKTHROUGH.md](docs/MANUAL_WALKTHROUGH.md)** - Complete manual deployment guide

**When to use manual approach:**
- Learning OpenShift UPI internals
- Customizing specific deployment steps
- Troubleshooting deployment issues
- Understanding the underlying architecture

**Time**: 45-90 minutes vs 20-30 minutes for automated

## Monitoring & Troubleshooting

### Check Deployment Status
```bash
# Export kubeconfig
export KUBECONFIG=clusterconfig/auth/kubeconfig

# Check cluster nodes
kubectl get nodes

# Check cluster operators
kubectl get clusteroperators

# Check for pending CSRs
kubectl get csr
```

### Access OpenShift Console
```bash
# Get console URL
kubectl get route console -n openshift-console

# Get admin password
cat clusterconfig/auth/kubeadmin-password
```

### SSH to Cluster Nodes
```bash
# Get bastion IP
BASTION_IP=$(terraform -chdir=terraform output -raw bastion_external_ip)

# SSH to bastion
ssh -i keys/id_rsa ubuntu@$BASTION_IP

# From bastion, SSH to any node
ssh core@ocp-control-1
```

### Common Issues
For detailed troubleshooting, see:
- **[DEBUG_COMMANDS.md](docs/DEBUG_COMMANDS.md)** - Complete troubleshooting guide with commands and solutions
- **[GCP_PERMISSIONS.md](docs/GCP_PERMISSIONS.md)** - Required GCP IAM roles and permissions setup

## Cleanup

```bash
# Destroy the entire cluster and infrastructure
cd terraform
terraform destroy
```

## Documentation

### Getting Started  
- **[README.md](README.md)** - This file (quick start and overview)
- **[docs/INDEX.md](docs/INDEX.md)** - Complete documentation navigation

### Technical Documentation
- **[DEBUG_COMMANDS.md](docs/DEBUG_COMMANDS.md)** - Complete troubleshooting guide
  - Common issues and solutions
  - Debug commands for each component
  - Step-by-step problem resolution
  - Network and DNS troubleshooting

- **[GCP_PERMISSIONS.md](docs/GCP_PERMISSIONS.md)** - GCP IAM setup guide
  - Required permissions and roles
  - Service account configuration
  - Security best practices
  - Permission validation scripts

- **[MANUAL_WALKTHROUGH.md](docs/MANUAL_WALKTHROUGH.md)** - Step-by-step manual deployment
  - Complete manual deployment process
  - Understanding each deployment phase
  - Educational approach to UPI
  - Troubleshooting along the way

- **[docs/README.md](docs/README.md)** - Detailed technical documentation
  - Architecture deep dive
  - Component explanations
  - Advanced configuration options

### Documentation Roadmap

**New to OpenShift UPI?**
1. Start here: [README.md](README.md) (this file)
2. Setup GCP: [GCP_PERMISSIONS.md](docs/GCP_PERMISSIONS.md)
3. For learning: [MANUAL_WALKTHROUGH.md](docs/MANUAL_WALKTHROUGH.md)
4. If issues arise: [DEBUG_COMMANDS.md](docs/DEBUG_COMMANDS.md)

**Troubleshooting Issues?**
1. Go directly to: [DEBUG_COMMANDS.md](docs/DEBUG_COMMANDS.md)
2. Find your issue category and follow the workflow

**Want Full Documentation?**
1. Browse: [docs/INDEX.md](docs/INDEX.md) for complete navigation
2. Deep dive: [docs/README.md](docs/README.md) for technical details

## Architecture

The deployment creates:

### Infrastructure (Terraform)
- **VPC & Subnets**: Multi-zone networking across 3 availability zones
- **Compute Instances**: 1 bootstrap, 3 control planes, 3 workers, 1 bastion
- **DNS**: Private managed zone with required A records
- **Storage**: GCS bucket for bootstrap ignition files
- **IAM**: Service accounts with minimal required permissions

### OpenShift Cluster
- **Version**: OpenShift 4.19
- **Networking**: OVN-Kubernetes (default)
- **Storage**: GCP Persistent Disk CSI
- **High Availability**: 3 control planes across zones
- **Workers**: 3 worker nodes for application workloads

## Contributing

This repository is designed for production OpenShift UPI deployments. Contributions welcome:

1. Fork the repository
2. Create a feature branch  
3. Test your changes thoroughly
4. Update relevant documentation in `docs/`
5. Submit a pull request

### Documentation Updates
When contributing, please update:
- **[DEBUG_COMMANDS.md](docs/DEBUG_COMMANDS.md)** - If adding troubleshooting steps
- **[GCP_PERMISSIONS.md](docs/GCP_PERMISSIONS.md)** - If changing IAM requirements
- **[MANUAL_WALKTHROUGH.md](docs/MANUAL_WALKTHROUGH.md)** - If changing manual deployment steps
- **[README.md](README.md)** - If changing deployment process
- **[docs/README.md](docs/README.md)** - If changing architecture

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## References

- [OpenShift 4.19 Documentation](https://docs.openshift.com/container-platform/4.19/)
- [OpenShift UPI on GCP Guide](https://docs.openshift.com/container-platform/4.19/installing/installing_gcp/installing-gcp-user-infra.html)
- [Terraform Google Provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)