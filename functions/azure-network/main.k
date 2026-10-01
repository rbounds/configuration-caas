# observed composite resource
oxr = option("params").oxr
params = oxr.spec.parameters
# observed composed resources
_ocds = option("params").ocds
# desired composite resource
_dxr = option("params").dxr
# desired composed resources
dcds = option("params").dcds

_metadata = lambda name: str -> any {
    {
        name = name
        annotations = {"krm.kcl.dev/composition-resource-name" = name}
        labels = {"azure.platform.upbound.io/network-id" = params.id}
    }
}

# Helper function to add common spec fields
_add_common_spec_fields = lambda spec: any -> any {
    spec | {
        managementPolicies = params.managementPolicies
        providerConfigRef = {kind = "ProviderConfig", name = params.providerConfigName}
    }
}

# Base network resources
_base_resources = [
    # Resource Group
    {
        apiVersion = "azure.m.upbound.io/v1beta1"
        kind = "ResourceGroup"
        metadata = _metadata("${params.id}-rg")
        spec = _add_common_spec_fields({
            forProvider = {
                location = params.region
            }
        })
    }

    # Virtual Network
    {
        apiVersion = "network.azure.m.upbound.io/v1beta1"
        kind = "VirtualNetwork"
        metadata = _metadata("${params.id}-vnet")
        spec = _add_common_spec_fields({
            forProvider = {
                location = params.region
                addressSpace = [params.addressRange]
                resourceGroupNameSelector = {
                    matchControllerRef = True
                }
            }
        })
    }

    # Subnet for general use
    {
        apiVersion = "network.azure.m.upbound.io/v1beta1"
        kind = "Subnet"
        metadata = _metadata("${params.id}-sn") | {
            labels: {
                "azure.platform.upbound.io/subnet-service-type" = "general"
            }
        }
        spec = _add_common_spec_fields({
            forProvider = {
                addressPrefixes = [params.generalSubnetRange]
                resourceGroupNameSelector = {
                    matchControllerRef = True
                }
                serviceEndpoints = ["Microsoft.Sql"]
                virtualNetworkNameSelector = {
                    matchControllerRef = True
                }
            }
        })
    }
]

# Database subnets (optional)
_subnets_from_spec = params.databaseSubnets or []
_database_subnets = [
    {
        apiVersion = "network.azure.m.upbound.io/v1beta1"
        kind = "Subnet"
        metadata = _metadata("${params.id}-db-sn-${index}") | {
            labels: {
                "azure.platform.upbound.io/subnet-service-type" = subnet.serviceType
            }
        }
        spec = _add_common_spec_fields({
            forProvider = {
                addressPrefixes = [subnet.addressRange]
                delegation = [{
                    name = "fs"
                    serviceDelegation = {
                        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
                        name = "Microsoft.DBforPostgreSQL/flexibleServers" if subnet.serviceType == "postgres" else "Microsoft.DBforMySQL/flexibleServers"
                    }
                }]
                resourceGroupNameSelector = {
                    matchControllerRef = True
                }
                serviceEndpoints = ["Microsoft.Storage"]
                virtualNetworkNameSelector = {
                    matchControllerRef = True
                }
            }
        })
    } for index, subnet in _subnets_from_spec
]

_raw_items = _base_resources + _database_subnets

# All resources are local to the XR. Status patches preserve the XR's identity.
items = [
    item | {metadata.namespace = oxr.metadata.namespace}
    for item in _raw_items
]
