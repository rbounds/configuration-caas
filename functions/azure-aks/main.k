oxr = option("params").oxr
dxr = option("params").dxr
ocds = option("params").ocds

_metadata = lambda name: str -> any {
    {
        annotations = {"krm.kcl.dev/composition-resource-name" = name}
    }
}

_defaultSpec = {
    managementPolicies = oxr.spec.parameters.managementPolicies or ["*"]
    providerConfigRef = {
        kind = "ProviderConfig"
        name = oxr.spec.parameters.providerConfigName or "default"
    }
    forProvider = {}
}

_items = [
    {
        apiVersion = "azure.platform.upbound.io/v1alpha1"
        kind = "AKS"
        **dxr
        spec.parameters = {
            id = oxr.spec.parameters.id
            nodes = oxr.spec.parameters.nodes
            region = oxr.spec.parameters.region
        }
        status = {
            aks = {
                oidcUrl = ocds?.kubernetesCluster?.Resource?.status?.atProvider?.oidcIssuerUrl
                clusterName = ocds?.kubernetesCluster?.Resource?.metadata?.name
                # SystemAssigned managed-identity principalId (single object on the MR, absent until reconciled)
                identityPrincipalId = ocds?.kubernetesCluster?.Resource?.status?.atProvider?.identity?.principalId
                nodes = {
                    vmSize = ocds?.kubernetesCluster?.Resource?.status?.atProvider?.defaultNodePool?.vmSize
                }
            }
        }
    }
    {
        apiVersion = "containerservice.azure.m.upbound.io/v1beta1"
        kind = "KubernetesCluster"
        metadata = {
            **_metadata("kubernetesCluster")
            name = "{}-aks".format(oxr.spec.parameters.id)
        }
        spec = {
            **_defaultSpec
            forProvider = {
                defaultNodePool = {
                    name = "default"
                    nodeCount = oxr.spec.parameters.nodes.count
                    vmSize = oxr.spec.parameters.nodes.instanceType
                    if oxr.spec.parameters.nodes?.availabilityZones:
                        zones = oxr.spec.parameters.nodes.availabilityZones
                    vnetSubnetIdSelector.matchLabels = {
                        "azure.platform.upbound.io/network-id" = oxr.spec.parameters.id
                        "azure.platform.upbound.io/subnet-service-type" = "general"
                    }
                }
                dnsPrefix = oxr.spec.parameters.id
                identity.type = "SystemAssigned"
                kubernetesVersion = oxr.spec.parameters.version
                location = oxr.spec.parameters.region
                oidcIssuerEnabled = True
                workloadIdentityEnabled = True
                resourceGroupNameSelector.matchLabels = {
                    "azure.platform.upbound.io/network-id" = oxr.spec.parameters.id
                }
            }
            writeConnectionSecretToRef = {
                name = "{}-akscluster".format(oxr.metadata.name)
            }
        }
    }
    {
        apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
        kind = "Object"
        metadata = _metadata("workloadIdentitySettings")
        spec = {
            managementPolicies = ["Create", "Observe", "Update", "LateInitialize"]
            forProvider = {
                manifest = {
                    apiVersion = "v1"
                    kind = "ConfigMap"
                    metadata = {
                        name = "{}-workloadidentity-settings".format(oxr.spec.parameters.id)
                        namespace = "default"
                    }
                    data = {
                        oidc_url = dxr?.status?.aks?.oidcUrl
                    }
                }
            }
            providerConfigRef = {
                kind = "ProviderConfig"
                name = oxr.spec.parameters.id
            }
        }
    }
    {
        apiVersion = "helm.m.crossplane.io/v1beta1"
        kind = "ProviderConfig"
        metadata = {
            **_metadata("providerConfigHelm")
            annotations: {
                "krm.kcl.dev/ready" = "True"
            }
            name = oxr.spec.parameters.id
        }
        spec = {
            credentials = {
                secretRef = {
                    key = "kubeconfig"
                    name = "{}-akscluster".format(oxr.metadata.name)
                    namespace = oxr.metadata.namespace
                }
                source = "Secret"
            }
        }
    }
    {
        apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
        kind = "ProviderConfig"
        metadata = {
            **_metadata("providerConfigKubernetes")
            annotations: {
                "krm.kcl.dev/ready" = "True"
            }
            name = oxr.spec.parameters.id
        }
        spec = {
            credentials = {
                secretRef = {
                    key = "kubeconfig"
                    name = "{}-akscluster".format(oxr.metadata.name)
                    namespace = oxr.metadata.namespace
                }
                source = "Secret"
            }
        }
    }
]

_raw_items = _items

# All resources are local to the XR. Status patches preserve the XR's identity.
items = [
    item | {metadata.namespace = oxr.metadata.namespace}
    for item in _raw_items
]
