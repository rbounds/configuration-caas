oxr = option("params").oxr
_ocds = option("params").ocds or {}

_metadata = lambda name: str -> any {
    { annotations = { "krm.kcl.dev/composition-resource-name" = name }}
}

# Helper functions to check if resources are ready
_eksReadyCondition = [condition for condition in (_ocds?["XEKS"]?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isEksReady = len(_eksReadyCondition) > 0

_aksReadyCondition = [condition for condition in (_ocds?["XAKS"]?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isAksReady = len(_aksReadyCondition) > 0

_gkeReadyCondition = [condition for condition in (_ocds?["XGKE"]?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isGkeReady = len(_gkeReadyCondition) > 0

_lbControllerReadyCondition = [condition for condition in (_ocds?["XAWSLBController"]?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isLbControllerReady = len(_lbControllerReadyCondition) > 0

# Extract parameters from XR
cloud = oxr.spec.parameters.cloud
id = oxr.spec.parameters.id
region = oxr.spec.parameters.region
deletionPolicy = oxr.spec.parameters.deletionPolicy
providerConfigName = oxr.spec.parameters.providerConfigName
version = oxr.spec.parameters.version
nodeCount = oxr.spec.parameters.nodes.count
instanceType = oxr.spec.parameters.nodes.instanceType
iamRoleArn = oxr.spec?.parameters?.iam?.roleArn
iamUserArn = oxr.spec?.parameters?.iam?.userArn
iamPrincipalArn = iamRoleArn if iamRoleArn else iamUserArn
gitopsOperator = oxr.spec.parameters.gitops.operator
gitopsGit = oxr.spec.parameters.gitops.git
gitopsIngressUrl = oxr.spec?.parameters?.gitops?.ingressUrl
gitopsOidcConfig = oxr.spec?.parameters?.gitops?.oidcConfig
prometheusVersion = oxr.spec.parameters.operators.prometheus.version
fluxVersion = oxr.spec?.parameters?.operators?.flux?.version
fluxSyncVersion = oxr.spec?.parameters?.operators?.fluxSync?.version
argocdVersion = oxr.spec?.parameters?.operators?.argocd?.version
connectionSecretNamespace = oxr.metadata.namespace
managementPolicies = ["*"] if deletionPolicy == "Delete" else ["Create", "Observe", "Update", "LateInitialize"]

_items = []

# AWS Resources
if cloud == "aws":
    _items += [
        {
            apiVersion: "aws.platform.upbound.io/v1alpha1"
            kind: "Network"
            metadata: _metadata("XNetworkAWS")
            spec: {
                parameters: {
                    id: id
                    region: region
                    managementPolicies: managementPolicies
                    providerConfigName: providerConfigName
                    subnets: oxr.spec?.parameters?.network?.subnets or [
                        {availabilityZone: region + "a", type: "public", cidrBlock: "192.168.0.0/18"}
                        {availabilityZone: region + "b", type: "public", cidrBlock: "192.168.64.0/18"}
                        {availabilityZone: region + "a", type: "private", cidrBlock: "192.168.128.0/18"}
                        {availabilityZone: region + "b", type: "private", cidrBlock: "192.168.192.0/18"}
                    ]
                }
            }
        }
        {
            apiVersion: "aws.platform.upbound.io/v1alpha1"
            kind: "EKS"
            metadata: _metadata("XEKS") | {
                labels: {
                    "xeks.aws.platform.upbound.io/cluster-id": id
                    "platform.upbound.io/deletion-ordering": "enabled"
                }
                annotations: {
                    "crossplane.io/external-name": id
                }
            }
            spec: {
                parameters: {
                    id: id
                    region: region
                    managementPolicies: managementPolicies
                    providerConfigName: providerConfigName
                    version: version
                    accessConfig: {
                        authenticationMode: "API_AND_CONFIG_MAP"
                        bootstrapClusterCreatorAdminPermissions: True
                    }
                    nodes: {
                        count: nodeCount
                        instanceType: instanceType
                    }
                    **({iam: {principalArn: iamPrincipalArn}} if iamPrincipalArn else {})
                }
            }
        }
        {
            apiVersion: "protection.crossplane.io/v1beta1"
            kind: "Usage"
            metadata: _metadata("usageXEksByXOss")
            spec: {
                of: {
                    apiVersion: "aws.platform.upbound.io/v1alpha1"
                    kind: "EKS"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
                by: {
                    apiVersion: "observe.platform.upbound.io/v1alpha1"
                    kind: "Oss"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
            }
        }
    ]

# Azure Resources
if cloud == "azure":
    _items += [
        {
            apiVersion: "azure.platform.upbound.io/v1alpha1"
            kind: "Network"
            metadata: _metadata("XNetworkAZURE")
            spec: {
                parameters: {
                    id: id
                    region: region
                    addressRange: "10.1.0.0/16"
                    generalSubnetRange: "10.1.1.0/24"
                    managementPolicies: managementPolicies
                    providerConfigName: providerConfigName
                }
            }
        }
        {
            apiVersion: "azure.platform.upbound.io/v1alpha1"
            kind: "AKS"
            metadata: _metadata("XAKS") | {
                labels: {
                    "xaks.azure.platform.upbound.io/cluster-id": id
                }
            }
            spec: {
                parameters: {
                    id: id
                    region: region
                    managementPolicies: managementPolicies
                    providerConfigName: providerConfigName
                    version: version
                    nodes: {
                        count: nodeCount
                        instanceType: instanceType
                    }
                }
            }
        }
        {
            apiVersion: "protection.crossplane.io/v1beta1"
            kind: "Usage"
            metadata: _metadata("usageXAksByXOss")
            spec: {
                of: {
                    apiVersion: "azure.platform.upbound.io/v1alpha1"
                    kind: "AKS"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
                by: {
                    apiVersion: "observe.platform.upbound.io/v1alpha1"
                    kind: "Oss"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
            }
        }
    ]

# GCP Resources
if cloud == "gcp":
    _items += [
        {
            apiVersion: "gcp.platform.upbound.io/v1alpha1"
            kind: "Network"
            metadata: _metadata("XNetworkGCP")
            spec: {
                parameters: {
                    id: id
                    region: region
                    managementPolicies: managementPolicies
                    providerConfigName: providerConfigName
                }
            }
        }
        {
            apiVersion: "gcp.platform.upbound.io/v1alpha1"
            kind: "GKE"
            metadata: _metadata("XGKE") | {
                labels: {
                    "xgke.gcp.platform.upbound.io/cluster-id": id
                }
                annotations: {
                    "crossplane.io/external-name": id
                }
            }
            spec: {
                parameters: {
                    id: id
                    region: region
                    managementPolicies: managementPolicies
                    providerConfigName: providerConfigName
                    version: version
                    nodes: {
                        count: nodeCount
                        instanceType: instanceType
                    }
                }
            }
        }
        {
            apiVersion: "protection.crossplane.io/v1beta1"
            kind: "Usage"
            metadata: _metadata("usageXGkeByXOss")
            spec: {
                of: {
                    apiVersion: "gcp.platform.upbound.io/v1alpha1"
                    kind: "GKE"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
                by: {
                    apiVersion: "observe.platform.upbound.io/v1alpha1"
                    kind: "Oss"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
            }
        }
    ]

# Map cloud provider to cluster resource name
_clusterResourceNames = {
    "aws": "XEKS"
    "azure": "XAKS"
    "gcp": "XGKE"
}
_clusterResourceName = _clusterResourceNames[cloud]

# Check if dependent resources already exist (safety checks to prevent uninstalling)
_lbControllerExists = "XAWSLBController" in _ocds
_ossExists = "XOss" in _ocds
_fluxExists = "XFlux" in _ocds
_argoExists = "XArgo" in _ocds

# Get VPC ID from observed XNetwork status (needed for AWS LB Controller)
_observedVpcId = _ocds?["XNetworkAWS"]?.Resource?.status?.vpcId

# For AWS: create XAWSLBController when XEKS is ready (to avoid webhook conflicts with Flux/OSS)
# Also create if it already exists to prevent uninstalling
if cloud == "aws" and (_isEksReady or _lbControllerExists):
    _items += [
        {
            apiVersion: "aws.platform.upbound.io/v1alpha1"
            kind: "AWSLBController"
            metadata: _metadata("XAWSLBController") | {
                labels: {
                    "platform.upbound.io/deletion-ordering": "enabled"
                }
            }
            spec: {
                parameters: {
                    providerConfigName: providerConfigName
                    managementPolicies: managementPolicies
                    helm: {
                        providerConfigName: id
                    }
                    region: region
                    clusterName: _ocds?["XEKS"]?.Resource?.status?.eks?.clusterName or _ocds?["XAWSLBController"]?.Resource?.spec?.parameters?.clusterName
                    eksResourceName: _ocds?["XEKS"]?.Resource?.metadata?.name or _ocds?["XAWSLBController"]?.Resource?.spec?.parameters?.eksResourceName
                    # Pass VPC ID if available to avoid EC2 metadata discovery
                    if _observedVpcId:
                        vpcId = _observedVpcId
                }
            }
        }
    ]

    # Usage resources for XAWSLBController
    _items += [
        {
            apiVersion: "protection.crossplane.io/v1beta1"
            kind: "Usage"
            metadata: _metadata("usageXEksByXAWSLBController")
            spec: {
                of: {
                    apiVersion: "aws.platform.upbound.io/v1alpha1"
                    kind: "EKS"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
                by: {
                    apiVersion: "aws.platform.upbound.io/v1alpha1"
                    kind: "AWSLBController"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
            }
        }
        # Ensure XOss is deleted before XAWSLBController (if XOss exists)
        {
            apiVersion: "protection.crossplane.io/v1beta1"
            kind: "Usage"
            metadata: _metadata("usageXAWSLBControllerByXOss") | {
                annotations: {
                    "krm.kcl.dev/ready": "True"
                }
            }
            spec: {
                replayDeletion: True
                of: {
                    apiVersion: "aws.platform.upbound.io/v1alpha1"
                    kind: "AWSLBController"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
                by: {
                    apiVersion: "observe.platform.upbound.io/v1alpha1"
                    kind: "Oss"
                    resourceSelector: {
                        matchControllerRef: True
                    }
                }
            }
        }
    ]

# Determine readiness check for creating XOss and GitOps resources
# For AWS: wait for LB Controller to be ready (to avoid webhook conflicts)
# For Azure/GCP: wait for cluster to be ready
_readyForHelm = False
if cloud == "aws":
    _readyForHelm = _isLbControllerReady
elif cloud == "azure":
    _readyForHelm = _isAksReady
elif cloud == "gcp":
    _readyForHelm = _isGkeReady

# Observability (created after prerequisites are ready, or if it already exists)
# For AWS: waits for XAWSLBController to avoid webhook conflicts
# For Azure/GCP: waits for cluster to be ready
if _readyForHelm or _ossExists:
    _items += [
        {
            apiVersion: "observe.platform.upbound.io/v1alpha1"
            kind: "Oss"
            metadata: _metadata("XOss")
            spec: {
                parameters: {
                    managementPolicies: managementPolicies
                    id: id
                    operators: {
                        prometheus: {
                            version: prometheusVersion
                        }
                    }
                }
            }
        }
    ]

# Flux GitOps (created after prerequisites are ready, or if it already exists)
# For AWS: waits for XAWSLBController to avoid webhook conflicts
# For Azure/GCP: waits for cluster to be ready
if gitopsOperator == "flux" and (_readyForHelm or _fluxExists):
    _items += [
        {
            apiVersion: "gitops.platform.upbound.io/v1alpha1"
            kind: "Flux"
            metadata: _metadata("XFlux")
            spec: {
                parameters: {
                    managementPolicies: managementPolicies
                    providerConfigName: id
                    operators: {
                        flux: {
                            version: fluxVersion
                        }
                        fluxSync: {
                            version: fluxSyncVersion
                        }
                    }
                    source: {
                        git: gitopsGit
                    }
                }
            }
        }
    ]

    # Usage resources for Flux
    if cloud == "aws":
        _items += [
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXEksByXFlux")
                spec: {
                    of: {
                        apiVersion: "aws.platform.upbound.io/v1alpha1"
                        kind: "EKS"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "Flux"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
            # Ensure XFlux is deleted before XAWSLBController
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXAWSLBControllerByXFlux") | {
                    annotations: {
                        "krm.kcl.dev/ready": "True"
                    }
                }
                spec: {
                    replayDeletion: True
                    of: {
                        apiVersion: "aws.platform.upbound.io/v1alpha1"
                        kind: "AWSLBController"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "Flux"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
        ]
    elif cloud == "azure":
        _items += [
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXAksByXFlux")
                spec: {
                    of: {
                        apiVersion: "azure.platform.upbound.io/v1alpha1"
                        kind: "AKS"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "Flux"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
        ]
    elif cloud == "gcp":
        _items += [
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXGkeByXFlux")
                spec: {
                    of: {
                        apiVersion: "gcp.platform.upbound.io/v1alpha1"
                        kind: "GKE"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "Flux"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
        ]

# ArgoCD GitOps (created after prerequisites are ready, or if it already exists)
# For AWS: waits for XAWSLBController to avoid webhook conflicts
# For Azure/GCP: waits for cluster to be ready
if gitopsOperator == "argocd" and (_readyForHelm or _argoExists):
    _items += [
        {
            apiVersion: "gitops.platform.upbound.io/v1alpha1"
            kind: "XArgo"
            metadata: _metadata("XArgo")
            spec: {
                parameters: {
                    managementPolicies: managementPolicies
                    providerConfigName: id
                    operators: {
                        argocd: {
                            version: argocdVersion
                        }
                    }
                    source: {
                        git: {
                            url: gitopsGit.url
                            **({path: gitopsGit.path} if gitopsGit?.path else {})
                            **({ref: gitopsGit.ref} if gitopsGit?.ref else {})
                        }
                    }
                    **({ingressUrl: gitopsIngressUrl} if gitopsIngressUrl else {})
                    **({oidcConfig: gitopsOidcConfig} if gitopsOidcConfig else {})
                }
            }
        }
    ]

    # Usage resources for ArgoCD
    if cloud == "aws":
        _items += [
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXEksByXArgo")
                spec: {
                    of: {
                        apiVersion: "aws.platform.upbound.io/v1alpha1"
                        kind: "EKS"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "XArgo"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
            # Ensure XArgo is deleted before XAWSLBController
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXAWSLBControllerByXArgo") | {
                    annotations: {
                        "krm.kcl.dev/ready": "True"
                    }
                }
                spec: {
                    replayDeletion: True
                    of: {
                        apiVersion: "aws.platform.upbound.io/v1alpha1"
                        kind: "AWSLBController"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "XArgo"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
        ]
    elif cloud == "azure":
        _items += [
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXAksByXArgo")
                spec: {
                    of: {
                        apiVersion: "azure.platform.upbound.io/v1alpha1"
                        kind: "AKS"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "XArgo"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
        ]
    elif cloud == "gcp":
        _items += [
            {
                apiVersion: "protection.crossplane.io/v1beta1"
                kind: "Usage"
                metadata: _metadata("usageXGkeByXArgo")
                spec: {
                    of: {
                        apiVersion: "gcp.platform.upbound.io/v1alpha1"
                        kind: "GKE"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                    by: {
                        apiVersion: "gitops.platform.upbound.io/v1alpha1"
                        kind: "XArgo"
                        resourceSelector: {
                            matchControllerRef: True
                        }
                    }
                }
            }
        ]

# v2 XRs compose a native Secret. The nested cloud XRs no longer forward
# connection details; retrieve the MR's Secret through the Helm ProviderConfig.
_required = option("params")?.requiredResources or {}
_providerConfigs = _required?.clusterProviderConfig or []
_sourceRef = _providerConfigs[0]?.Resource?.spec?.credentials?.secretRef if _providerConfigs else None
_requirements = {
    clusterProviderConfig: {
        apiVersion: "helm.m.crossplane.io/v1beta1"
        kind: "ProviderConfig"
        name: id
        namespace: oxr.metadata.namespace
    }
}
if _sourceRef:
    assert _sourceRef.namespace == oxr.metadata.namespace, "kubeconfig must remain in the XCluster namespace"
    _requirements.kubeconfig = {
        apiVersion: "v1"
        kind: "Secret"
        name: _sourceRef.name
        namespace: oxr.metadata.namespace
    }
_items += [{
    apiVersion: "meta.krm.kcl.dev/v1alpha1"
    kind: "RequiredResources"
    requirements: _requirements
}]

_sourceSecrets = _required?.kubeconfig or []
_kubeconfig = _sourceSecrets[0]?.Resource?.data?[_sourceRef.key] if _sourceSecrets and _sourceRef else None
# Preserve the last value while the upstream Secret is temporarily unavailable.
_kubeconfig = _kubeconfig or _ocds?["connection-secret"]?.Resource?.data?.kubeconfig
_items += [{
    apiVersion: "v1"
    kind: "Secret"
    metadata: _metadata("connection-secret") | {
        name: oxr.spec?.writeConnectionSecretToRef?.name or "{}-kubeconfig".format(id)
        namespace: connectionSecretNamespace
        annotations: {
            "krm.kcl.dev/ready": "True" if _kubeconfig else "False"
        }
    }
    type: "Opaque"
    data: {kubeconfig: _kubeconfig} if _kubeconfig else {}
}]

items = [item | {metadata.namespace = oxr.metadata.namespace} if item.kind != "RequiredResources" else item for item in _items]
