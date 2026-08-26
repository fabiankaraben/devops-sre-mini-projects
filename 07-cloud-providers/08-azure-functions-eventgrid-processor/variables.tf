# ==============================================================================
# Input Variables for Azure Functions Event Grid Blob Processor
# ==============================================================================

variable "location" {
  type        = string
  description = "Azure Region where all resources will be deployed."
  default     = "eastus"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the Azure Resource Group."
  default     = "rg-blob-eventgrid-processor"
}

variable "storage_account_name_prefix" {
  type        = string
  description = "Prefix for the Azure Storage Account (must be globally unique lowercase alphanumeric)."
  default     = "stgmedia"

  validation {
    condition     = can(regex("^[a-z0-9]{3,18}$", var.storage_account_name_prefix))
    error_message = "storage_account_name_prefix must be lowercase alphanumeric between 3 and 18 characters."
  }
}

variable "cosmosdb_account_name_prefix" {
  type        = string
  description = "Prefix for the Cosmos DB Account name."
  default     = "cosmos-media"
}

variable "function_app_name_prefix" {
  type        = string
  description = "Prefix for the Azure Linux Function App."
  default     = "func-blob-proc"
}

variable "blob_container_name" {
  type        = string
  description = "Name of the Azure Blob Storage container where media files are uploaded."
  default     = "images-upload"
}

variable "cosmos_database_name" {
  type        = string
  description = "Name of the Cosmos DB SQL Database."
  default     = "media-metadata"
}

variable "cosmos_container_name" {
  type        = string
  description = "Name of the Cosmos DB Container for storing extracted metadata documents."
  default     = "blobs"
}

variable "tags" {
  type        = map(string)
  description = "Resource tags applied across all Azure infrastructure."
  default = {
    Project      = "08-azure-functions-eventgrid-processor"
    Environment  = "demo"
    ManagedBy    = "terraform"
    Architecture = "serverless-event-driven"
  }
}
