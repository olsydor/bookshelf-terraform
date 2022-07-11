#at first you must run "gcloud auth application-default login" command, 
#\ if you not install gcloud CLI install from link instructions https://cloud.google.com/sdk/docs/install
provider "google" {
  project = var.project-id
  region  = var.region
  zone    = var.zone
}
#External HTTP(S) load balancer with MIG backend and custom headers template \
#https://cloud.google.com/load-balancing/docs/https/ext-http-lb-tf-module-examples#with_mig_backend_and_custom_headers

# VPC
resource "google_compute_network" "vpc" {
  name                    = "${var.app-name}-vpc"
  auto_create_subnetworks = false
}

# backend subnet
resource "google_compute_subnetwork" "vpc_subnet" {
  name          = "${var.app-name}-vpc-subnet"
  ip_cidr_range = var.ip-cidr-range
  #CIDR is the short for Classless Inter-Domain Routing, an IP addressing scheme that replaces the older system 
  #based on classes A, B, and C. A single IP address can be used to designate many unique IP addresses with CIDR. 
  #A CIDR IP address looks like a normal IP address except that it ends with a slash followed by a number, called 
  #the IP network prefix. CIDR addresses reduce the size of routing tables and make more IP addresses available 
  #within organizations.
  region  = var.region
  network = google_compute_network.vpc.id
}

# reserved IP address
resource "google_compute_global_address" "app_lb-static_ip_addr" {
  name = "${var.app-name}-static-ip-reserve"

}

#(Start-Random-id)

resource "random_id" "db" {
  byte_length = 4
}
#(END-Random-id)

# (Start-SQL-Instance)
resource "google_sql_database_instance" "app_sql_instance" {
  name                = "${var.app-name}-${random_id.db.hex}"
  database_version    = var.db_version
  deletion_protection = false

  settings {
    tier = var.db_instance_tier
  }
}
resource "google_sql_user" "users" {
  name     = "${var.app-name}-db-sql-user"
  instance = google_sql_database_instance.app_sql_instance.name
}
#(Start-SQL-db)
resource "google_sql_database" "app_sql_db" {
  instance = google_sql_database_instance.app_sql_instance.name
  name     = "${var.app-name}-db"
}
#(END-SQL-db)

#(Start-Storage-bucket)
resource "google_storage_bucket" "app_bucket" {
  name     = "${var.app-name}-storage-bucket-name"
  location = var.region
}
#(END-Storage-bucket)

#(Start-service-account)
resource "google_service_account" "app_sa" {
  account_id   = "${var.app-name}-sa"
  display_name = "${var.app-name}-sa"
}

resource "google_project_iam_custom_role" "my_custome_role" {
  role_id = "my_custom_role"
  project = var.app-name
  permissions = [ "value" ]
  #role    = "roles/editor"
  #member  = "serviceAccount:${google_service_account.app_sa.email}"
}
#(END-service-account)

#(Start-CLoud-NAT)

resource "google_compute_router" "router" {
  name    = "${var.app-name}-nat-router"
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.app-name}-nat-router"
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

#(END-CLoud-NAT)

# forwarding rule 
resource "google_compute_global_forwarding_rule" "app_forward_rule" {
  name                  = "${var.app-name}-lb-forw-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_proxy.id
  ip_address            = google_compute_global_address.app_lb-static_ip_addr.id
}

# http proxy  Target proxies are referenced by one or more forwarding rules. 
#In the case of external HTTP(S) load balancers and internal HTTP(S) load balancers, 
#proxies route incoming requests to a URL map. In the case of SSL proxy load balancers
#and TCP proxy load balancers, target proxies route incoming requests directly to backend services.
resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "${var.app-name}-lb-target-http-proxy"
  url_map = google_compute_url_map.app_lb_url_map.id
}

# url map
#A URL map is a set of rules for routing incoming HTTP(S) requests to specific backend services 
#or backend buckets. A minimal URL map matches all incoming request paths (/*).
resource "google_compute_url_map" "app_lb_url_map" {
  name            = "${var.app-name}-lb-url-map"
  default_service = google_compute_backend_service.app_backend_service.id
}

# backend service with custom request and response headers
# A Backend Service defines a group of virtual machines that will serve traffic for load balancing. 
# This resource is a global backend service, appropriate for external load balancing 
resource "google_compute_backend_service" "app_backend_service" {
  name                  = "${var.app-name}-lb-backend-service"
  protocol              = "HTTP"
  port_name             = "my-port" #Name of backend port. The same name should appear in the instance groups referenced by this service. Required when the load balancing scheme is EXTERNAL.
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 10 #How many seconds to wait for the backend before considering it a failed request. Default is 30 seconds
  health_checks         = [google_compute_health_check.app_health_check.id]
  backend {
    group           = google_compute_instance_group_manager.app_mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}


# MIG
resource "google_compute_instance_group_manager" "app_mig" {
  name = "${var.app-name}-lb-mig"
  zone = var.zone
  named_port {
    name = "http"
    port = 8080
  }
  version {
    instance_template = google_compute_instance_template.ins_template.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# instance template
resource "google_compute_instance_template" "ins_template" {
  name         = "${var.app-name}-lb-mig-template"
  machine_type = var.machine-type
  tags         = ["allow-health-check"]

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.vpc_subnet.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-9"
    auto_delete  = true
    boot         = true
  }

  # install nginx and serve a simple web page
  metadata = {
    startup-script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")
      METADATA=$(curl -f -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/?recursive=True" | jq 'del(.["startup-script"])')

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      Metadata: $METADATA
      </pre>
      EOF
    EOF1
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_health_check" "app_health_check" {
  name = "${var.app-name}-lb-hc"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}


# allow access from health check ranges
resource "google_compute_firewall" "app_firewall" {
  name          = "${var.app-name}-lb-fw-allow-hc"
  direction     = "INGRESS"
  network       = google_compute_network.vpc.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
  }
  target_tags = ["allow-health-check"]
}
#autoscaler-definition
resource "google_compute_autoscaler" "app_autoscaller" {
  name   = "${var.app-name}-autoscaller"
  zone   = var.zone
  target = google_compute_instance_group_manager.app_mig.id

  autoscaling_policy {
    max_replicas    = 2
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.2
    }
  }
}