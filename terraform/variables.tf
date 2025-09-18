# OpenShift 4.19 UPI Infrastructure Variables

# Project and Region
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-c"]
}

# Cluster Configuration
variable "cluster_name" {
  description = "Name of the OpenShift cluster"
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be lowercase, start with a letter, and contain only letters, numbers, and hyphens."
  }
}

# Network Configuration
variable "subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "pod_cidrs" {
  description = "CIDR blocks for Kubernetes pods (one per AZ)"
  type        = list(string)
  default     = ["10.128.0.0/16", "10.129.0.0/16", "10.130.0.0/16"]
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "172.30.0.0/16"
}

# DNS Configuration
variable "domain_name" {
  description = "Base domain name for the cluster"
  type        = string
  default     = "ocp.j7ql2.gcp.redhatworkshops.io"
}

# VIP Configuration removed - using direct DNS to worker nodes

# Compute Configuration
variable "control_plane_machine_type" {
  description = "Machine type for control plane nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "worker_machine_type" {
  description = "Machine type for worker nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "control_plane_disk_size" {
  description = "Disk size for control plane nodes in GB"
  type        = number
  default     = 120
}

variable "worker_disk_size" {
  description = "Disk size for worker nodes in GB"
  type        = number
  default     = 120
}

# OpenShift and RHCOS Configuration
variable "ocp_version" {
  description = "OpenShift version"
  type        = string
  default     = "4.19"
}

variable "rhcos_version" {
  description = "RHCOS version for OpenShift"
  type        = string
  default     = "4.19.10"
}

# Ignition Configurations
variable "control_plane_ignition_config" {
  description = "Ignition configuration for control plane nodes"
  type        = string
  default     = ""
}

variable "worker_ignition_config" {
  description = "Ignition configuration for worker nodes"
  type        = string
  default     = ""
}

# Firewall Source Ranges
variable "ssh_source_ranges" {
  description = "Source IP ranges allowed for SSH access"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "api_source_ranges" {
  description = "Source IP ranges allowed for API server access"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "ingress_source_ranges" {
  description = "Source IP ranges allowed for ingress traffic"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "nodeport_source_ranges" {
  description = "Source IP ranges allowed for NodePort services"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "enable_bastion" {
  description = "Enable bastion host for secure access to the cluster"
  type        = bool
  default     = true
}
