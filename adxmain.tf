#####################
# Data section 			#
#####################

data "azurerm_subscription" "current" {
}

#####################
# Resources section #
#####################

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kusto_cluster
resource "azurerm_kusto_cluster" "adx" {
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  public_network_access_enabled = var.public_network_access_enabled
  streaming_ingestion_enabled   = var.streaming_ingestion_enabled

  sku {
    name     = var.sku
    capacity = var.capacity
  }

  identity {
    type = "SystemAssigned, UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.adx.id
    ]
  }

  tags = var.tags
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kusto_database
resource "azurerm_kusto_database" "database" {
  for_each = var.eventhubs

  name                = "${var.database_name}-${each.value["eventhub_abbreviation"]}"
  location            = var.location
  resource_group_name = var.resource_group_name
  cluster_name        = azurerm_kusto_cluster.adx.name

  hot_cache_period   = var.database_hot_cache_period
  soft_delete_period = var.database_soft_delete_period
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group
resource "azurerm_network_security_group" "adx" {
  lifecycle {
    ignore_changes = [
      security_rule
    ]
  }

  name                = var.nsg_name
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "adx-default"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = var.tags
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association
resource "azurerm_subnet_network_security_group_association" "adx" {
  subnet_id                 = var.subnet_id
  network_security_group_id = azurerm_network_security_group.adx.id
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint
resource "azurerm_private_endpoint" "endpoint" {
  name                          = var.private_endpoint_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  subnet_id                     = var.subnet_id
  custom_network_interface_name = "${var.private_endpoint_name}-nic"

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = var.private_dns_zone_ids
  }

  private_service_connection {
    name                           = "${var.private_endpoint_name}psc"
    private_connection_resource_id = azurerm_kusto_cluster.adx.id
    is_manual_connection           = false
    subresource_names              = ["cluster"]
  }

  tags = var.tags
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity
resource "azurerm_user_assigned_identity" "adx" {
  name                = "id-dflbus-iot-dev-gwc-001"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment
resource "azurerm_role_assignment" "adx-to-eventhub" {
  for_each = var.eventhubs

  scope                = each.value["eventhub_id"]
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_user_assigned_identity.adx.principal_id
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kusto_eventhub_data_connection
resource "azurerm_kusto_eventhub_data_connection" "eventhub_connection" {
  for_each = var.eventhubs

  name                = each.value["kusto_eventhub_data_connection_name"]
  resource_group_name = var.resource_group_name
  location            = var.location
  cluster_name        = azurerm_kusto_cluster.adx.name
  database_name       = "${var.database_name}-${each.value["eventhub_abbreviation"]}"

  eventhub_id    = each.value["eventhub_id"]
  consumer_group = each.value["eventhub_consumer_group"]
  identity_id    = "${data.azurerm_subscription.current.id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${azurerm_user_assigned_identity.adx.name}"

  table_name        = "MetricsData"
  mapping_rule_name = "MetricsDataMapping"
  data_format       = "MULTIJSON"

  depends_on = [azurerm_kusto_database.database, azurerm_kusto_script.create_table_flat, azurerm_kusto_script.create_ingestion_mapping_flat]
}

# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kusto_script
resource "azurerm_kusto_script" "create_table_flat" {
  for_each = azurerm_kusto_database.database

  name                               = "create-table-flat-${each.value.name}"
  database_id                        = each.value.id
  continue_on_errors_enabled         = true
  force_an_update_when_value_changed = "1.0.0"

  script_content = <<-EOT
		.create-merge table ['MetricsData']  (
			['value_name']:string, 
			['raw_name']:string, 
			['standardized_value']:string, 
			['name']:string, 
			['plant']:string, 
			['building']:string, 
			['work_station']:string, 
			['raw_unit']:string, 
			['standardized_unit']:string, 
			['id']:string, 
			['value_category']:string, 
			['machine_name']:string, 
			['machine_id']:string, 
			['timestamp']:datetime
		)
  EOT
}

resource "azurerm_kusto_script" "create_ingestion_mapping_flat" {
  for_each = azurerm_kusto_database.database

  name                               = "create-ingestion-mapping-flat-${each.value.name}"
  database_id                        = each.value.id
  continue_on_errors_enabled         = true
  force_an_update_when_value_changed = "1.0.0"

  script_content = <<-EOT
		.create-or-alter table ['MetricsData'] ingestion json mapping 'MetricsDataMapping' 
			'['
			'	{"column":"value_name", "Properties":{"Path":"$.fields.value_name"}},'
			'	{"column":"raw_name", "Properties":{"Path":"$.fields.raw_name"}},'
			'	{"column":"standardized_value", "Properties":{"Path":"$.fields.standardized_value"}},'
			'	{"column":"name", "Properties":{"Path":"$.name"}},'
			'	{"column":"plant", "Properties":{"Path":"$.tags.plant"}},'
			'	{"column":"building", "Properties":{"Path":"$.tags.building"}},'
			'	{"column":"work_station", "Properties":{"Path":"$.tags.work_station"}},'
			'	{"column":"raw_unit", "Properties":{"Path":"$.tags.raw_unit"}},'
			'	{"column":"standardized_unit", "Properties":{"Path":"$.tags.standardized_unit"}},'
			'	{"column":"id", "Properties":{"Path":"$.tags.id"}},'
			'	{"column":"value_category", "Properties":{"Path":"$.tags.value_category"}},'
			'	{"column":"machine_name", "Properties":{"Path":"$.tags.machine_name"}},'
			'	{"column":"machine_id", "Properties":{"Path":"$.tags.machine_id"}},'
			'	{"column":"timestamp", "Properties":{"Path":"$.timestamp"}}'
			']'
  EOT

  depends_on = [azurerm_kusto_script.create_table_flat]
}

resource "azurerm_kusto_script" "enable_streaming_ingestion_flat" {
  for_each = azurerm_kusto_database.database

  name                               = "enable-streaming-ingestion-flat-${each.value.name}"
  database_id                        = each.value.id
  continue_on_errors_enabled         = true
  force_an_update_when_value_changed = "1.0.0"

  script_content = <<-EOT
		.alter table MetricsData policy streamingingestion enable
  EOT

  depends_on = [azurerm_kusto_script.create_ingestion_mapping_flat]
}
