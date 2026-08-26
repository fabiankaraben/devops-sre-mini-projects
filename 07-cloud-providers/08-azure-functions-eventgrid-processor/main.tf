# ==============================================================================
# Azure Functions Event Grid Blob Processor - Infrastructure Manifest
# ==============================================================================

provider "azurerm" {
  features {}
}

# ------------------------------------------------------------------------------
# 1. Random Suffix for Global Resource Uniqueness
# ------------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  storage_account_name  = "${var.storage_account_name_prefix}${random_string.suffix.result}"
  cosmosdb_account_name = "${var.cosmosdb_account_name_prefix}-${random_string.suffix.result}"
  function_app_name     = "${var.function_app_name_prefix}-${random_string.suffix.result}"
  system_topic_name     = "evgt-storage-${random_string.suffix.result}"
}

# ------------------------------------------------------------------------------
# 2. Azure Resource Group
# ------------------------------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ------------------------------------------------------------------------------
# 3. Azure Storage Account & Ingestion Blob Container
# ------------------------------------------------------------------------------
resource "azurerm_storage_account" "storage" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false

  tags = var.tags
}

resource "azurerm_storage_container" "images" {
  name                  = var.blob_container_name
  storage_account_id    = azurerm_storage_account.storage.id
  container_access_type = "private"
}

# ------------------------------------------------------------------------------
# 4. Azure Cosmos DB (SQL API in Serverless Mode)
# ------------------------------------------------------------------------------
resource "azurerm_cosmosdb_account" "cosmos" {
  name                = local.cosmosdb_account_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 5
    max_staleness_prefix    = 100
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "db" {
  name                = var.cosmos_database_name
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
}

resource "azurerm_cosmosdb_sql_container" "container" {
  name                = var.cosmos_container_name
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
  database_name       = azurerm_cosmosdb_sql_database.db.name
  partition_key_paths = ["/contentType"]
}

# ------------------------------------------------------------------------------
# 5. Azure Linux Function App (Consumption Plan Y1)
# ------------------------------------------------------------------------------
resource "azurerm_service_plan" "plan" {
  name                = "asp-serverless-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1"

  tags = var.tags
}

resource "azurerm_linux_function_app" "function" {
  name                = local.function_app_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  storage_account_name       = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key
  service_plan_id            = azurerm_service_plan.plan.id

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "COSMOS_DB_ENDPOINT"       = azurerm_cosmosdb_account.cosmos.endpoint
    "COSMOS_DB_PRIMARY_KEY"    = azurerm_cosmosdb_account.cosmos.primary_key
    "COSMOS_DB_DATABASE"       = var.cosmos_database_name
    "COSMOS_DB_CONTAINER"      = var.cosmos_container_name
    "STORAGE_CONTAINER_NAME"   = var.blob_container_name
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# 6. Event Grid System Topic on Storage Account
# ------------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic" "storage_topic" {
  name                = local.system_topic_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  source_resource_id  = azurerm_storage_account.storage.id
  topic_type          = "Microsoft.Storage.StorageAccounts"

  tags = var.tags
}

# ------------------------------------------------------------------------------
# 7. Event Grid Subscription (Filter on BlobCreated in images-upload container)
# ------------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic_event_subscription" "blob_subscription" {
  name                = "sub-blob-created-processor"
  system_topic        = azurerm_eventgrid_system_topic.storage_topic.name
  resource_group_name = azurerm_resource_group.rg.name

  included_event_types = [
    "Microsoft.Storage.BlobCreated"
  ]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${var.blob_container_name}/blobs/"
    case_sensitive      = false
  }

  azure_function_endpoint {
    function_id                       = "${azurerm_linux_function_app.function.id}/functions/ProcessBlobEvent"
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  depends_on = [
    azurerm_linux_function_app.function
  ]
}
