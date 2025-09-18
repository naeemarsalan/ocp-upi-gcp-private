# OpenShift 4.19 UPI Infrastructure Outputs

# Network Information
output "vpc_name" {
  description = "Name of the VPC"
  value       = google_compute_network.openshift_vpc.name
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = google_compute_network.openshift_vpc.id
}

output "subnet_names" {
  description = "Names of the subnets"
  value       = [for subnet in google_compute_subnetwork.openshift_subnets : subnet.name]
}

output "subnet_ids" {
  description = "IDs of the subnets"
  value       = [for subnet in google_compute_subnetwork.openshift_subnets : subnet.id]
}

output "subnet_cidrs" {
  description = "CIDR blocks of the subnets"
  value       = [for subnet in google_compute_subnetwork.openshift_subnets : subnet.ip_cidr_range]
}

# VIP removed - using direct DNS to worker nodes

# DNS Information
output "dns_zone_name" {
  description = "Name of the DNS zone"
  value       = google_dns_managed_zone.cluster_zone.name
}

output "dns_zone_domain" {
  description = "Domain name of the DNS zone"
  value       = google_dns_managed_zone.cluster_zone.dns_name
}

# RHCOS Image Information
output "rhcos_image_name" {
  description = "Name of the custom RHCOS image"
  value       = data.google_compute_image.rhcos.name
}

output "rhcos_image_self_link" {
  description = "Self link of the custom RHCOS image"
  value       = data.google_compute_image.rhcos.self_link
}

# Control Plane Nodes
output "control_plane_instances" {
  description = "Control plane instance information"
  value = {
    for i, instance in google_compute_instance.control_plane : instance.name => {
      name         = instance.name
      internal_ip  = instance.network_interface[0].network_ip
      zone         = instance.zone
      machine_type = instance.machine_type
    }
  }
}

# Worker Nodes
output "worker_instances" {
  description = "Worker instance information"
  value = {
    for i, instance in google_compute_instance.worker : instance.name => {
      name         = instance.name
      internal_ip  = instance.network_interface[0].network_ip
      zone         = instance.zone
      machine_type = instance.machine_type
    }
  }
}

# Service Account
output "service_account_email" {
  description = "Email of the service account"
  value       = google_service_account.openshift_node_sa.email
}

# DNS Information for OpenShift Installation
output "dns_entries" {
  description = "DNS entries configured for OpenShift installation"
  value = {
    "api.${var.domain_name}" = google_compute_instance.control_plane[0].network_interface[0].network_ip
    "api-int.${var.domain_name}" = google_compute_instance.control_plane[0].network_interface[0].network_ip
    "*.apps.${var.domain_name}" = "Points to worker nodes directly"
  }
}

# Instance IPs for inventory
output "control_plane_ips" {
  description = "Internal IP addresses of control plane nodes"
  value       = [for instance in google_compute_instance.control_plane : instance.network_interface[0].network_ip]
}

output "worker_ips" {
  description = "Internal IP addresses of worker nodes"
  value       = [for instance in google_compute_instance.worker : instance.network_interface[0].network_ip]
}

# Summary for OpenShift installation
output "installation_summary" {
  description = "Summary of key information for OpenShift installation"
  value = {
    cluster_name          = var.cluster_name
    domain_name           = var.domain_name
    region                = var.region
    api_ip                = google_compute_instance.control_plane[0].network_interface[0].network_ip
    worker_ips            = [for instance in google_compute_instance.worker : instance.network_interface[0].network_ip]
    control_plane_count   = length(google_compute_instance.control_plane)
    worker_count          = length(google_compute_instance.worker)
    service_account_email = google_service_account.openshift_node_sa.email
    network_name          = google_compute_network.openshift_vpc.name
    subnet_names          = [for subnet in google_compute_subnetwork.openshift_subnets : subnet.name]
    dns_zone_name         = google_dns_managed_zone.cluster_zone.name
  }
}
