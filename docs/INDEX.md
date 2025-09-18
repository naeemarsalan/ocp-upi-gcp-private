# OpenShift UPI GCP Documentation Index

This directory contains comprehensive documentation for deploying OpenShift 4.19 UPI on Google Cloud Platform.

## Documentation Overview

### Getting Started
- **[../README.md](../README.md)** - Quick start guide and main documentation
  - One-command deployment
  - Prerequisites and setup
  - Configuration guide
  - Basic troubleshooting

### Troubleshooting & Debug
- **[DEBUG_COMMANDS.md](DEBUG_COMMANDS.md)** - Complete troubleshooting guide
  - Common deployment issues and solutions
  - Debug commands for each component (bootstrap, control planes, workers)
  - Network and DNS troubleshooting
  - CSR approval issues
  - Step-by-step problem resolution workflows

### Manual Deployment
- **[MANUAL_WALKTHROUGH.md](MANUAL_WALKTHROUGH.md)** - Step-by-step manual deployment guide
  - Complete manual deployment process (45-90 minutes)
  - Understanding each deployment phase in detail
  - Educational approach to learning UPI
  - Manual troubleshooting at each step
  - Alternative to automated deployment scripts

### Security & Permissions  
- **[GCP_PERMISSIONS.md](GCP_PERMISSIONS.md)** - GCP IAM configuration guide
  - Required user account permissions
  - Service account creation and roles
  - API enablement requirements
  - Security best practices
  - Permission validation scripts
  - Custom IAM roles (advanced)

### Technical Deep Dive
- **[README.md](README.md)** - Detailed technical documentation
  - Architecture overview
  - Component explanations
  - Advanced configuration options
  - Integration details

## Quick Navigation

### By Use Case

**First Time Deployment:**
1. Start with [../README.md](../README.md) - Quick Start section
2. Follow [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md) for GCP setup
3. For learning: [MANUAL_WALKTHROUGH.md](MANUAL_WALKTHROUGH.md) for step-by-step
4. Use [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md) if issues arise

**Troubleshooting Existing Deployment:**
1. Go to [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md)
2. Find your specific issue category
3. Follow the debug workflow

**Security & Compliance:**
1. Review [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md)
2. Implement least-privilege IAM
3. Follow security best practices

**Understanding the Architecture:**
1. Read [README.md](README.md) for technical details
2. Walk through [MANUAL_WALKTHROUGH.md](MANUAL_WALKTHROUGH.md) for hands-on learning
3. Review [../terraform/](../terraform/) for infrastructure code
4. Check [../ansible/](../ansible/) for automation logic

## Common Scenarios

| Issue | Documentation |
|-------|---------------|
| Want to learn UPI step-by-step | [MANUAL_WALKTHROUGH.md](MANUAL_WALKTHROUGH.md) |
| Deployment fails during bootstrap | [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md#bootstrap-issues) |
| Workers not joining cluster | [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md#worker-csr-issues) |
| Permission denied errors | [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md#troubleshooting-permission-issues) |
| DNS resolution problems | [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md#dns-troubleshooting) |
| RHCOS image issues | [DEBUG_COMMANDS.md](DEBUG_COMMANDS.md#rhcos-image-issues) |
| Terraform apply failures | [GCP_PERMISSIONS.md](GCP_PERMISSIONS.md#terraform-service-account-permissions) |

## Documentation Maintenance

This documentation is maintained alongside the codebase. When making changes:

1. **Update relevant docs** when changing functionality
2. **Test all commands** in documentation before committing
3. **Keep examples current** with actual configuration
4. **Update links** when moving or renaming files

## Getting Help

1. **Check existing docs** - Most issues are covered in our guides
2. **Search the repo** - Use GitHub search for specific error messages
3. **Open an issue** - If documentation is unclear or missing
4. **Contribute back** - Help improve docs for others

---

*Last updated: September 2025*
