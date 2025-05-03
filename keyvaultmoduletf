####################
# Provider section #
####################

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.98.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_deleted_secrets_on_destroy = true
      recover_soft_deleted_secrets          = true
    }
  }
}

#https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config
data "azurerm_client_config" "current" {}

#####################
# Resources section #
#####################

#https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault
resource "azurerm_key_vault" "key-vault" {
  
  name                          = var.name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = var.sku_name
  soft_delete_retention_days    = var.soft_delete_retention_days
  purge_protection_enabled      = true
  public_network_access_enabled = var.public_network_access
  enable_rbac_authorization     = var.enable_rbac_authorization
  depends_on                    = [var.keyvault_depends_on]
    network_acls {
    bypass                     = var.keyvault_network_acls.bypass
    default_action             = var.keyvault_network_acls.default_action
    ip_rules                   = var.keyvault_network_acls.ip_rules
    virtual_network_subnet_ids = var.keyvault_network_acls.virtual_network_subnet_ids
  }
  
}

#https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint
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
    private_connection_resource_id = azurerm_key_vault.key-vault.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }
}
