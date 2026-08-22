# ==============================================================================
# Outputs Configuration
# ==============================================================================

output "container_id" {
  description = "Unique SHA-256 identifier of the provisioned Docker container"
  value       = docker_container.nginx_service.id
}

output "container_name" {
  description = "Name of the provisioned Docker container"
  value       = docker_container.nginx_service.name
}

output "container_ip_address" {
  description = "Internal IPv4 address of the container on the custom bridge network"
  value       = docker_container.nginx_service.network_data[0].ip_address
}

output "container_gateway" {
  description = "Gateway IPv4 address of the custom bridge network"
  value       = docker_container.nginx_service.network_data[0].gateway
}

output "network_id" {
  description = "Unique identifier of the custom Docker bridge network"
  value       = docker_network.custom_bridge.id
}

output "network_name" {
  description = "Name of the custom Docker bridge network"
  value       = docker_network.custom_bridge.name
}

output "volume_id" {
  description = "Unique identifier of the persistent Docker volume"
  value       = docker_volume.nginx_data.id
}

output "volume_name" {
  description = "Name of the persistent Docker volume"
  value       = docker_volume.nginx_data.name
}

output "service_url" {
  description = "Locally accessible HTTP URL for the provisioned Nginx service"
  value       = "http://127.0.0.1:${var.external_port}"
}
