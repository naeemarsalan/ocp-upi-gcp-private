# OpenShift 4.19 UPI Infrastructure on GCP

# Local values for ignition configurations and image selection
locals {
  control_plane_ignition_config = fileexists("./clusterconfig/master.ign") ? file("./clusterconfig/master.ign") : var.control_plane_ignition_config
  worker_ignition_config        = fileexists("./clusterconfig/worker.ign") ? file("./clusterconfig/worker.ign") : var.worker_ignition_config
  
  # Bootstrap pointer ignition (points to GCS for large bootstrap.ign)
  bootstrap_pointer_ignition = jsonencode({
    ignition = {
      version = "3.2.0"
      config = {
        merge = [{
          source = "https://storage.googleapis.com/${google_storage_bucket.bootstrap_bucket.name}/bootstrap.ign"
        }]
      }
    }
  })

  # Use custom RHCOS image for OpenShift cluster
  rhcos_image = data.google_compute_image.rhcos.self_link
}

# GCS Bucket for Bootstrap Ignition (too large for metadata)
resource "google_storage_bucket" "bootstrap_bucket" {
  name     = "${var.cluster_name}-bootstrap-ignition-${random_id.bucket_suffix.hex}"
  location = var.region
  
  # Delete bucket when cluster is destroyed
  force_destroy = true
  
  # Enable uniform bucket-level access for easier management
  uniform_bucket_level_access = true
}

# Random suffix for bucket name uniqueness
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Upload bootstrap.ign to GCS bucket
resource "google_storage_bucket_object" "bootstrap_ignition" {
  name   = "bootstrap.ign"
  bucket = google_storage_bucket.bootstrap_bucket.name
  source = "./clusterconfig/bootstrap.ign"
  
  # Only upload if file exists
  count = fileexists("./clusterconfig/bootstrap.ign") ? 1 : 0
}

# VPC Network
resource "google_compute_network" "openshift_vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  routing_mode           = "REGIONAL"
}

# Cloud Router for NAT
resource "google_compute_router" "openshift_router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.openshift_vpc.id
}

# Cloud NAT for outbound internet access
resource "google_compute_router_nat" "openshift_nat" {
  name   = "${var.cluster_name}-nat"
  router = google_compute_router.openshift_router.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Private Subnets (one per availability zone)
resource "google_compute_subnetwork" "openshift_subnets" {
  count         = length(var.zones)
  name          = "${var.cluster_name}-subnet-${count.index + 1}"
  ip_cidr_range = var.subnet_cidrs[count.index]
  region        = var.region
  network       = google_compute_network.openshift_vpc.id
  
  private_ip_google_access = true
  
  secondary_ip_range {
    range_name    = "pod-cidr-${count.index + 1}"
    ip_cidr_range = var.pod_cidrs[count.index]
  }
}

# Service Account for OpenShift nodes
resource "google_service_account" "openshift_node_sa" {
  account_id   = "${var.cluster_name}-node-sa"
  display_name = "OpenShift Node Service Account"
  description  = "Service account for OpenShift cluster nodes"
}

# Minimal IAM roles for the service account
resource "google_project_iam_member" "node_sa_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.openshift_node_sa.email}"
}

resource "google_project_iam_member" "node_sa_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.openshift_node_sa.email}"
}

# Allow service account to read from bootstrap bucket
resource "google_storage_bucket_iam_member" "bootstrap_bucket_object_reader" {
  bucket = google_storage_bucket.bootstrap_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.openshift_node_sa.email}"
}

# Additional bucket reader permission for bootstrap bucket access
resource "google_storage_bucket_iam_member" "bootstrap_bucket_reader" {
  bucket = google_storage_bucket.bootstrap_bucket.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.openshift_node_sa.email}"
}

# Make bootstrap bucket publicly readable (needed for Ignition early boot)
resource "google_storage_bucket_iam_member" "bootstrap_bucket_public_read" {
  bucket = google_storage_bucket.bootstrap_bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_project_iam_member" "node_sa_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.openshift_node_sa.email}"
}

resource "google_project_iam_member" "node_sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.openshift_node_sa.email}"
}

# Use custom RHCOS image for OpenShift
data "google_compute_image" "rhcos" {
  name    = "rhcos-4-19-10"
  project = var.project_id
}

# Bootstrap Node (temporary - provides Machine Config Server)
resource "google_compute_instance" "bootstrap" {
  name         = "${var.cluster_name}-bootstrap"
  machine_type = var.control_plane_machine_type
  zone         = var.zones[0]

  boot_disk {
    initialize_params {
      image = local.rhcos_image
      size  = var.control_plane_disk_size
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.openshift_subnets[0].self_link
    # No external IP for private cluster
  }

  service_account {
    email  = google_service_account.openshift_node_sa.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  metadata = {
    user-data = local.bootstrap_pointer_ignition
  }

  tags = ["${var.cluster_name}-bootstrap", "${var.cluster_name}-cluster"]

  lifecycle {
    ignore_changes = [
      metadata["user-data"],
    ]
  }
}

# Control Plane Nodes
resource "google_compute_instance" "control_plane" {
  count        = 3
  name         = "${var.cluster_name}-control-${count.index + 1}"
  machine_type = var.control_plane_machine_type
  zone         = var.zones[count.index]

  boot_disk {
    initialize_params {
      image = local.rhcos_image
      size  = var.control_plane_disk_size
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.openshift_subnets[count.index].self_link
    # No external IP for private cluster
  }

  service_account {
    email  = google_service_account.openshift_node_sa.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  metadata = {
    user-data = local.control_plane_ignition_config
  }

  tags = ["${var.cluster_name}-control-plane", "${var.cluster_name}-cluster"]

  lifecycle {
    ignore_changes = [
      metadata["user-data"],
    ]
  }
}

# Worker Nodes
resource "google_compute_instance" "worker" {
  count        = 3
  name         = "${var.cluster_name}-worker-${count.index + 1}"
  machine_type = var.worker_machine_type
  zone         = var.zones[count.index]

  boot_disk {
    initialize_params {
      image = local.rhcos_image
      size  = var.worker_disk_size
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.openshift_subnets[count.index].self_link
    # No external IP for private cluster
  }

  service_account {
    email  = google_service_account.openshift_node_sa.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  metadata = {
    user-data = local.worker_ignition_config
  }

  tags = ["${var.cluster_name}-worker", "${var.cluster_name}-cluster"]

  lifecycle {
    ignore_changes = [
      metadata["user-data"],
    ]
  }
}

# Bastion Host for secure access
resource "google_compute_instance" "bastion" {
  count = var.enable_bastion ? 1 : 0
  name         = "${var.cluster_name}-bastion"
  machine_type = "e2-micro"
  zone         = var.zones[0]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.openshift_vpc.id
    subnetwork = google_compute_subnetwork.openshift_subnets[0].id
    
    # External IP for SSH access
    access_config {
      // Ephemeral external IP
    }
  }

  service_account {
    email  = google_service_account.openshift_node_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    ssh-keys = "ubuntu:${file("keys/id_rsa.pub")}"
  }

  tags = ["${var.cluster_name}-bastion"]

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
    ]
  }
}

# VIP removed - using direct DNS to worker nodes instead

# DNS Zone for the cluster domain
resource "google_dns_managed_zone" "cluster_zone" {
  name        = "${var.cluster_name}-zone"
  dns_name    = "${var.domain_name}."
  description = "DNS zone for OpenShift cluster ${var.cluster_name}"

  visibility = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.openshift_vpc.id
    }
  }
}

# DNS A record for API server (pointing to control plane nodes)
resource "google_dns_record_set" "api" {
  name = "api.${google_dns_managed_zone.cluster_zone.dns_name}"
  type = "A"
  ttl  = 300

  managed_zone = google_dns_managed_zone.cluster_zone.name

  rrdatas = [
    google_compute_instance.control_plane[0].network_interface[0].network_ip,
    google_compute_instance.control_plane[1].network_interface[0].network_ip,
    google_compute_instance.control_plane[2].network_interface[0].network_ip
  ]
}

# DNS A record for internal API server (initially points to bootstrap for control plane boot)
resource "google_dns_record_set" "api_int" {
  name = "api-int.${google_dns_managed_zone.cluster_zone.dns_name}"
  type = "A"
  ttl  = 300

  managed_zone = google_dns_managed_zone.cluster_zone.name

  # Initially points to bootstrap - automation will flip to control planes after bootstrap
  rrdatas = [google_compute_instance.bootstrap.network_interface[0].network_ip]
}

# DNS A record for wildcard apps (pointing to worker nodes)
resource "google_dns_record_set" "apps_wildcard" {
  name = "*.apps.${google_dns_managed_zone.cluster_zone.dns_name}"
  type = "A"
  ttl  = 300

  managed_zone = google_dns_managed_zone.cluster_zone.name

  rrdatas = [
    google_compute_instance.worker[0].network_interface[0].network_ip,
    google_compute_instance.worker[1].network_interface[0].network_ip,
    google_compute_instance.worker[2].network_interface[0].network_ip
  ]
}

# Firewall Rules for OpenShift

# Allow internal cluster communication
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.cluster_name}-allow-internal"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = concat(var.subnet_cidrs, var.pod_cidrs, [var.service_cidr])
  target_tags   = ["${var.cluster_name}-cluster"]
}

# Allow SSH from specific source ranges (for debugging/maintenance)
resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.cluster_name}-allow-ssh"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = ["${var.cluster_name}-cluster"]
}

# Allow API server access
resource "google_compute_firewall" "allow_api_server" {
  name    = "${var.cluster_name}-allow-api-server"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  source_ranges = var.api_source_ranges
  target_tags   = ["${var.cluster_name}-control-plane"]
}

# Allow Machine Config Server access (bootstrap and control planes)
resource "google_compute_firewall" "allow_mcs" {
  name    = "${var.cluster_name}-allow-mcs"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22623"]
  }

  source_ranges = var.subnet_cidrs
  target_tags   = ["${var.cluster_name}-control-plane", "${var.cluster_name}-bootstrap"]
}

# Allow Ingress traffic (HTTP/HTTPS)
resource "google_compute_firewall" "allow_ingress" {
  name    = "${var.cluster_name}-allow-ingress"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = var.ingress_source_ranges
  target_tags   = ["${var.cluster_name}-worker"]
}

# Allow etcd communication between control plane nodes
resource "google_compute_firewall" "allow_etcd" {
  name    = "${var.cluster_name}-allow-etcd"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["2379", "2380"]
  }

  source_tags = ["${var.cluster_name}-control-plane"]
  target_tags = ["${var.cluster_name}-control-plane"]
}

# Allow kubelet communication
resource "google_compute_firewall" "allow_kubelet" {
  name    = "${var.cluster_name}-allow-kubelet"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["10250"]
  }

  source_tags = ["${var.cluster_name}-control-plane"]
  target_tags = ["${var.cluster_name}-cluster"]
}

# Allow NodePort services
resource "google_compute_firewall" "allow_nodeport" {
  name    = "${var.cluster_name}-allow-nodeport"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }

  source_ranges = var.nodeport_source_ranges
  target_tags   = ["${var.cluster_name}-cluster"]
}

# Allow SSH access to bastion host from anywhere
resource "google_compute_firewall" "allow_bastion_ssh" {
  count = var.enable_bastion ? 1 : 0
  name    = "${var.cluster_name}-allow-bastion-ssh"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-bastion"]
}

# Allow bastion to access internal cluster resources
resource "google_compute_firewall" "bastion_to_internal" {
  count = var.enable_bastion ? 1 : 0
  name    = "${var.cluster_name}-bastion-to-internal"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22", "443", "6443", "80", "22623"]
  }

  source_tags = ["${var.cluster_name}-bastion"]
  target_tags = ["${var.cluster_name}-cluster"]
}
