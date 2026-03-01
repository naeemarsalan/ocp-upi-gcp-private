# OpenShift 4.19 UPI Infrastructure on GCP

# Local values for ignition configurations and image selection
locals {
  control_plane_ignition_config = fileexists("../clusterconfig/master.ign") ? file("../clusterconfig/master.ign") : var.control_plane_ignition_config
  worker_ignition_config        = fileexists("../clusterconfig/worker.ign") ? file("../clusterconfig/worker.ign") : var.worker_ignition_config
  
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
  source = "../clusterconfig/bootstrap.ign"

  # Only upload if file exists
  count = fileexists("../clusterconfig/bootstrap.ign") ? 1 : 0
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
  count        = 2
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
    ssh-keys = "ubuntu:${file("../keys/id_rsa.pub")}"
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

  # Includes bootstrap IP initially - kubeconfig uses api.${domain} which needs bootstrap during boot
  # Automation removes bootstrap IP after control plane kube-apiservers are running
  rrdatas = [
    google_compute_instance.bootstrap.network_interface[0].network_ip,
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

  rrdatas = [for instance in google_compute_instance.worker : instance.network_interface[0].network_ip]
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

# ========================================
# OpenShift Operator Service Account
# Used by cluster operators (CSI, CCM, Ingress, Machine API, Image Registry)
# with credentialsMode: Manual
# ========================================

resource "google_service_account" "openshift_operator_sa" {
  account_id   = "${var.cluster_name}-operator-sa"
  display_name = "OpenShift Operator Service Account"
  description  = "Service account for OpenShift cluster operators (CSI, CCM, Ingress, Registry, Machine API)"
}

# Custom IAM role with granular permissions for all OpenShift operators
resource "google_project_iam_custom_role" "openshift_operator_role" {
  role_id     = "${replace(var.cluster_name, "-", "_")}_operator_role"
  title       = "OpenShift Operator Role for ${var.cluster_name}"
  description = "Granular permissions for OpenShift cluster operators"

  permissions = [
    # --- GCP PD CSI Driver (persistent disk management) ---
    "compute.disks.create",
    "compute.disks.delete",
    "compute.disks.get",
    "compute.disks.list",
    "compute.disks.update",
    "compute.disks.resize",
    "compute.disks.setLabels",
    "compute.instances.attachDisk",
    "compute.instances.detachDisk",
    "compute.instances.get",
    "compute.instances.list",
    "compute.snapshots.create",
    "compute.snapshots.delete",
    "compute.snapshots.get",
    "compute.snapshots.list",
    "compute.zones.get",
    "compute.zones.list",

    # --- Cloud Controller Manager (node & LB management) ---
    "compute.instances.setLabels",
    "compute.instances.setTags",
    "compute.addresses.get",
    "compute.addresses.list",
    "compute.forwardingRules.get",
    "compute.forwardingRules.list",
    "compute.regionBackendServices.get",
    "compute.regionBackendServices.list",
    "compute.instanceGroups.get",
    "compute.instanceGroups.list",
    "compute.targetPools.get",
    "compute.targetPools.list",

    # --- Cloud Network Config Controller ---
    "compute.networks.get",
    "compute.networks.list",
    "compute.subnetworks.get",
    "compute.subnetworks.list",

    # --- Image Registry (GCS bucket management) ---
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.get",
    "storage.buckets.list",
    "storage.objects.create",
    "storage.objects.delete",
    "storage.objects.get",
    "storage.objects.list",

    # --- Ingress Operator (DNS record management) ---
    "dns.changes.create",
    "dns.changes.get",
    "dns.changes.list",
    "dns.managedZones.get",
    "dns.managedZones.list",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",

    # --- Machine API (instance lifecycle for scaling) ---
    "compute.instances.create",
    "compute.instances.delete",
    "compute.instances.use",
    "compute.machineTypes.get",
    "compute.machineTypes.list",
    "compute.images.get",
    "compute.images.getFromFamily",
    "compute.images.useReadOnly",

    # --- Load Balancer (CCM creates LBs for ingress services) ---
    "compute.addresses.create",
    "compute.addresses.delete",
    "compute.addresses.use",
    "compute.forwardingRules.create",
    "compute.forwardingRules.delete",
    "compute.forwardingRules.setTarget",
    "compute.targetPools.create",
    "compute.targetPools.delete",
    "compute.targetPools.addInstance",
    "compute.targetPools.removeInstance",
    "compute.targetPools.use",
    "compute.regionBackendServices.create",
    "compute.regionBackendServices.delete",
    "compute.regionBackendServices.update",
    "compute.regionBackendServices.use",
    "compute.healthChecks.create",
    "compute.healthChecks.delete",
    "compute.healthChecks.get",
    "compute.healthChecks.use",
    "compute.healthChecks.useReadOnly",
    "compute.httpHealthChecks.create",
    "compute.httpHealthChecks.delete",
    "compute.httpHealthChecks.get",
    "compute.httpHealthChecks.use",
    "compute.httpHealthChecks.useReadOnly",
    "compute.instanceGroups.create",
    "compute.instanceGroups.delete",
    "compute.instanceGroups.update",
    "compute.instanceGroups.use",
    "compute.regionOperations.get",
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.get",
    "compute.firewalls.update",
    "compute.networks.updatePolicy",
    "compute.projects.get",

    # --- GCP Filestore CSI Driver ---
    "file.instances.create",
    "file.instances.delete",
    "file.instances.get",
    "file.instances.list",
    "file.instances.update",
    "file.operations.get",
    "file.operations.list",

    # --- Cloud Credential Operator (read-only verification) ---
    "resourcemanager.projects.get",
  ]
}

# Bind the custom role to the operator service account
resource "google_project_iam_member" "openshift_operator_role_binding" {
  project = var.project_id
  role    = google_project_iam_custom_role.openshift_operator_role.id
  member  = "serviceAccount:${google_service_account.openshift_operator_sa.email}"
}

# Bind the custom role to the node service account as well
# The GCE CCM uses instance metadata credentials (node SA) for LB operations
resource "google_project_iam_member" "openshift_node_operator_role_binding" {
  project = var.project_id
  role    = google_project_iam_custom_role.openshift_operator_role.id
  member  = "serviceAccount:${google_service_account.openshift_node_sa.email}"
}

# Generate a service account key for the operator SA
resource "google_service_account_key" "openshift_operator_key" {
  service_account_id = google_service_account.openshift_operator_sa.name
}

# Write the key to a local file for Ansible to inject into the cluster
resource "local_file" "openshift_operator_sa_key" {
  content         = base64decode(google_service_account_key.openshift_operator_key.private_key)
  filename        = "${path.module}/../creds/operator-sa-key.json"
  file_permission = "0600"
}

# Allow GCP health check probes (required for LoadBalancer services)
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.cluster_name}-allow-health-checks"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
  }

  # GCP health check source ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22", "209.85.152.0/22", "209.85.204.0/22"]
  target_tags   = ["${var.cluster_name}-cluster"]
}

# Allow NFS traffic for GCP Filestore
resource "google_compute_firewall" "allow_filestore_nfs" {
  name    = "${var.cluster_name}-allow-filestore-nfs"
  network = google_compute_network.openshift_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["2049"]
  }

  allow {
    protocol = "udp"
    ports    = ["2049"]
  }

  source_ranges = var.subnet_cidrs
  target_tags   = ["${var.cluster_name}-cluster"]
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
