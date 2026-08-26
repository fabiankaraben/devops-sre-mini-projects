# ==============================================================================
# Output Values for Azure Functions Event Grid Blob Processor
# ==============================================================================

output "resource_group_name" {
  description = "Name of the Azure Resource Group containing all services"
  value       = azurerm_resource_group.rg.name
}

output "storage_account_name" {
  description = "Azure Storage Account name where blob media is uploaded"
  value       = azurerm_storage_account.storage.name
}

output "blob_container_name" {
  description = "Blob container name targeted by Event Grid triggers"
  value       = azurerm_storage_container.images.name
}

output "cosmosdb_endpoint" {
  description = "Azure Cosmos DB SQL API endpoint"
  value       = azurerm_cosmosdb_account.cosmos.endpoint
}

output "cosmosdb_database_name" {
  description = "Name of the Cosmos DB SQL Database"
  value       = azurerm_cosmosdb_sql_database.db.name
}

output "cosmosdb_container_name" {
  description = "Name of the Cosmos DB SQL Container partitioned by /contentType"
  value       = azurerm_cosmosdb_sql_container.container.name
}

output "function_app_name" {
  description = "Name of the Azure Linux Function App"
  value       = azurerm_linux_function_app.function.name
}

output "function_default_hostname" {
  description = "Default HTTPS hostname of the Azure Function App"
  value       = "https://${azurerm_linux_function_app.function.default_hostname}"
}

output "eventgrid_system_topic_name" {
  description = "Name of the Event Grid System Topic listening to Storage Account events"
  value       = azurerm_eventgrid_system_topic.storage_topic.name
}

output "architecture_summary" {
  description = "Summary of the serverless event-driven architecture"
  value = {
    source_event_trigger = "Azure Storage Account (Microsoft.Storage.BlobCreated)"
    event_router         = "Azure Event Grid System Topic & Event Subscription"
    compute_processor    = "Azure Functions Linux (Python 3.11 on Consumption Plan Y1)"
    metadata_persistence = "Azure Cosmos DB (Serverless SQL API with /contentType partition)"
    security_model       = "Managed Identity + RBAC"
  }
}
