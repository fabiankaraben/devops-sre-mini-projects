# ==============================================================================
# Terraform Local Docker Provider Infrastructure - main.tf
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Provider Configuration
# ------------------------------------------------------------------------------
# The kreuzwerker/docker provider connects directly to the local Docker engine
# daemon via unix socket or standard environment variables.
provider "docker" {}

# ------------------------------------------------------------------------------
# 2. Docker Image Resource
# ------------------------------------------------------------------------------
# Pulls the specified container image from Docker Hub. Setting keep_locally to
# false guarantees the image is purged during `terraform destroy`.
resource "docker_image" "nginx" {
  name         = var.nginx_image_name
  keep_locally = false
}

# ------------------------------------------------------------------------------
# 3. Docker Bridge Network Resource
# ------------------------------------------------------------------------------
# Creates an isolated, user-defined bridge network with deterministic IPAM
# subnet configuration and embedded Docker DNS resolution.
resource "docker_network" "custom_bridge" {
  name   = var.network_name
  driver = "bridge"

  ipam_config {
    subnet  = "172.28.0.0/16"
    gateway = "172.28.0.1"
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  labels {
    label = "environment"
    value = var.environment
  }
}

# ------------------------------------------------------------------------------
# 4. Docker Persistent Volume Resource
# ------------------------------------------------------------------------------
# Provisions a named Docker storage volume for application logs or data
# that lives independently of container lifecycles.
resource "docker_volume" "nginx_data" {
  name = var.volume_name

  labels {
    label = "managed-by"
    value = "terraform"
  }

  labels {
    label = "environment"
    value = var.environment
  }
}

# ------------------------------------------------------------------------------
# 5. Docker Container Resource
# ------------------------------------------------------------------------------
# Provisions the Nginx web server container, joins the custom bridge network,
# mounts the persistent volume and static assets, and configures health checks.
resource "docker_container" "nginx_service" {
  name  = var.container_name
  image = docker_image.nginx.image_id

  restart = "on-failure"

  networks_advanced {
    name = docker_network.custom_bridge.name
  }

  ports {
    internal = var.internal_port
    external = var.external_port
    protocol = "tcp"
  }

  # Persistent volume mount for logs / persistent data
  volumes {
    volume_name    = docker_volume.nginx_data.name
    container_path = "/var/log/nginx"
  }

  # Injects custom HTML landing page directly into the container filesystem
  upload {
    file    = "/usr/share/nginx/html/index.html"
    content = file("${path.module}/html/index.html")
  }

  env = [
    "ENVIRONMENT=${var.environment}",
    "MANAGED_BY=terraform",
    "APP_NAME=${var.container_name}"
  ]

  healthcheck {
    test         = ["CMD-SHELL", "wget -q -O - http://127.0.0.1:${var.internal_port}/ >/dev/null || exit 1"]
    interval     = "5s"
    retries      = 3
    start_period = "3s"
    timeout      = "3s"
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  labels {
    label = "environment"
    value = var.environment
  }

  labels {
    label = "project"
    value = "01-terraform-local-docker-infrastructure"
  }

  lifecycle {
    ignore_changes = [
      network_mode,
      log_opts
    ]
  }
}
