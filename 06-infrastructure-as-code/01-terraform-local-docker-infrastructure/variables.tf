# ==============================================================================
# Variables Configuration
# ==============================================================================

variable "container_name" {
  description = "Name assigned to the Nginx Docker container"
  type        = string
  default     = "terraform-nginx-app"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_.-]+$", var.container_name))
    error_message = "The container_name must start with an alphanumeric character and contain only letters, numbers, underscores, dots, or dashes."
  }
}

variable "external_port" {
  description = "Host port mapped to the Nginx container HTTP port"
  type        = number
  default     = 8086

  validation {
    condition     = var.external_port >= 1024 && var.external_port <= 65535
    error_message = "The external_port must be a valid non-privileged port number between 1024 and 65535."
  }
}

variable "internal_port" {
  description = "Internal container port that Nginx listens on"
  type        = number
  default     = 80
}

variable "network_name" {
  description = "Name of the custom Docker bridge network"
  type        = string
  default     = "terraform-docker-net"
}

variable "volume_name" {
  description = "Name of the Docker persistent volume for web assets"
  type        = string
  default     = "terraform-nginx-data"
}

variable "nginx_image_name" {
  description = "Docker image tag for Nginx"
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "environment" {
  description = "Deployment environment tag (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "enable_custom_page" {
  description = "Whether to mount custom HTML landing page from local html/ directory"
  type        = bool
  default     = true
}
