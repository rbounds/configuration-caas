import base64

oxr = option("params").oxr # observed composite resource
_ocds = option("params")?.ocds or {}
_dxr = option("params").dxr # desired composite resource
params = oxr.spec.parameters
providerConfigRefName = params.providerConfigName or "default"
_workloadIdentityEnabled = params?.workloadIdentity?.enabled if params?.workloadIdentity?.enabled != Undefined else True

# Get status information from observed composed resources using correct access pattern
_service_account_id = _ocds?.serviceaccount?.Resource?.status?.atProvider?.id or ""
_service_account_email = _ocds?.serviceaccount?.Resource?.status?.atProvider?.email or _ocds?.gkecluster?.Resource?.spec?.forProvider?.nodeConfig?.serviceAccount or ""
_cluster_project_id = _ocds?.gkecluster?.Resource?.status?.atProvider?.project or ""

# Check if ServiceAccount is ready before using it in cluster configuration
_serviceAccountReadyCondition = [condition for condition in (_ocds?.serviceaccount?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isServiceAccountReady = len(_serviceAccountReadyCondition) > 0

# Extract project ID from service account status (used as a fallback)
_derived_project_id = ""
if _service_account_id:
    # Format: "projects/test-project-123/serviceAccounts/email"
    # Split by "/" and take the element at index 1
    parts = _service_account_id.split("/")
    if len(parts) >= 2 and parts[0] == "projects":
        _derived_project_id = parts[1]

# Get project ID from GKE cluster status (fallback)
if not _derived_project_id and _cluster_project_id:
    _derived_project_id = _cluster_project_id

# Prefer the explicit params.project; fall back to the runtime-derived project id.
_project_id = params.project or _derived_project_id

_metadata = lambda name: str -> any {
    {
        annotations = {"krm.kcl.dev/composition-resource-name" = name}
    }
}

_defaults = {
    managementPolicies = params.managementPolicies or ["*"]
    if providerConfigRefName:
        providerConfigRef = {
            kind = "ProviderConfig"
            name = providerConfigRefName
        }
}

_connection_secret_name = lambda suffix: str -> str {
    "{}-{}".format(params.id, suffix)
}

# Create service account and IAM resources first
_base_items = [
    {
        apiVersion = "cloudplatform.gcp.m.upbound.io/v1beta1"
        kind = "ServiceAccount"
        metadata = _metadata("serviceaccount") | {
            annotations = {
                "crossplane.io/external-name" = params.id
                "krm.kcl.dev/composition-resource-name" = "serviceaccount"
            }
        }
        spec = _defaults | {
            forProvider = {
                displayName = params.id
            }
        }
    }
    {
        apiVersion = "cloudplatform.gcp.m.upbound.io/v1beta1"
        kind = "ServiceAccountKey"
        metadata = _metadata("serviceaccountkey")
        spec = _defaults | {
            forProvider = {
                serviceAccountIdSelector = {
                    matchControllerRef = True
                }
            }
            writeConnectionSecretToRef = {
                name = _connection_secret_name("sakey")
            }
        }
    }
]

# Create GKE cluster and dependent resources only when service account is ready
_gke_items = [] if not (_service_account_email and (_isServiceAccountReady or "gkecluster" in _ocds)) else [
    {
        apiVersion = "cloudplatform.gcp.m.upbound.io/v1beta1"
        kind = "ProjectIAMMember"
        metadata = _metadata("projectiammember") | {
            annotations = {
                "crossplane.io/external-name" = params.id
                "krm.kcl.dev/composition-resource-name" = "projectiammember"
            }
        }
        spec = _defaults | {
            forProvider = {
                role = "roles/container.admin"
                member = "serviceAccount:{}".format(_service_account_email)
                project = _project_id
            }
        }
    }
    {
        apiVersion = "container.gcp.m.upbound.io/v1beta1"
        kind = "Cluster"
        metadata = _metadata("gkecluster")
        spec = _defaults | {
            forProvider = {
                location = params.region
                deletionProtection = False
                enableIntranodeVisibility = True
                initialNodeCount = 1
                ipAllocationPolicy = {
                    clusterSecondaryRangeName = "pods"
                    servicesSecondaryRangeName = "services"
                }
                loggingService = "logging.googleapis.com/kubernetes"
                monitoringService = "monitoring.googleapis.com/kubernetes"
                networkSelector = {
                    matchLabels = {
                        "networks.gcp.platform.upbound.io/network-id" = params.id
                    }
                }
                subnetworkSelector = {
                    matchLabels = {
                        "networks.gcp.platform.upbound.io/network-id" = params.id
                    }
                }
                **({nodeVersion = params.version} if params.version != "latest" else {})
                **({minMasterVersion = params.version} if params.version != "latest" else {})
                nodeConfig = {
                    serviceAccount = _service_account_email
                }
                **({workloadIdentityConfig = {
                    workloadPool = "{}.svc.id.goog".format(_project_id)
                }} if _workloadIdentityEnabled else {})
            }
            writeConnectionSecretToRef = {
                name = _connection_secret_name("gkecluster")
            }
        }
    }
    {
        apiVersion = "container.gcp.m.upbound.io/v1beta1"
        kind = "NodePool"
        metadata = _metadata("node-pool")
        spec = _defaults | {
            forProvider = {
                location = params.region
                autoscaling = {
                    maxNodeCount = params.nodes.count
                    minNodeCount = params.nodes.count
                }
                clusterSelector = {
                    matchControllerRef = True
                }
                initialNodeCount = params.nodes.count
                management = {
                    autoRepair = True
                    autoUpgrade = True
                }
                maxPodsPerNode = 55
                nodeConfig = {
                    diskSizeGb = params.nodes?.diskSizeGb or 20
                    imageType = "COS_CONTAINERD"
                    machineType = params.nodes.instanceType
                    metadata = {
                        "disable-legacy-endpoints" = "true"
                    }
                    oauthScopes = [
                        "https://www.googleapis.com/auth/cloud-platform"
                    ]
                    preemptible = True
                    shieldedInstanceConfig = {
                        enableIntegrityMonitoring = True
                        enableSecureBoot = True
                    }
                    serviceAccount = _service_account_email
                    **({workloadMetadataConfig = {
                        mode = "GKE_METADATA"
                    }} if _workloadIdentityEnabled else {})
                }
            }
        }
    }
    {
        apiVersion = "helm.m.crossplane.io/v1beta1"
        kind = "ProviderConfig"
        metadata = _metadata("providerConfigHelm") | {
            name = params.id
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = "providerConfigHelm"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            credentials = {
                secretRef = {
                    key = "kubeconfig"
                    name = _connection_secret_name("gkecluster")
                    namespace = oxr.metadata.namespace
                }
                source = "Secret"
            }
            identity = {
                secretRef = {
                    key = "private_key"
                    name = _connection_secret_name("sakey")
                    namespace = oxr.metadata.namespace
                }
                source = "Secret"
                type = "GoogleApplicationCredentials"
            }
        }
    }
    {
        apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
        kind = "ProviderConfig"
        metadata = _metadata("providerConfigKubernetes") | {
            name = params.id
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = "providerConfigKubernetes"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            credentials = {
                secretRef = {
                    key = "kubeconfig"
                    name = _connection_secret_name("gkecluster")
                    namespace = oxr.metadata.namespace
                }
                source = "Secret"
            }
            identity = {
                secretRef = {
                    key = "private_key"
                    name = _connection_secret_name("sakey")
                    namespace = oxr.metadata.namespace
                }
                source = "Secret"
                type = "GoogleApplicationCredentials"
            }
        }
    }
    {
        apiVersion = "kubernetes.m.crossplane.io/v1alpha1"
        kind = "Object"
        metadata = _metadata("workloadIdentitySettings") | {
            name = "{}-workload-identity-settings".format(params.id)
            namespace = oxr.metadata.namespace
        }
        spec = {
            managementPolicies = ["Create", "Observe", "Update", "LateInitialize"]
            providerConfigRef = {
                kind = "ProviderConfig"
                name = params.id
            }
            forProvider = {
                manifest = {
                    apiVersion = "v1"
                    kind = "ConfigMap"
                    metadata = {
                        name = "{}-workload-identity-settings".format(params.id)
                        namespace = "default"
                    }
                    data = {
                        **({gkeProject = _project_id} if _project_id else {})
                    }
                }
            }
        }
    }
    {
        apiVersion = "v1"
        kind = "Secret"
        metadata = {
            name = "{}-connection".format(oxr.metadata.name)
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = "connection-secret"
            }
            labels = {
                "crossplane.io/composite" = oxr.metadata.name
            }
        }
        type = "connection.crossplane.io/v1alpha1"
        if "gkecluster" in _ocds:
            data = {
                # Password comes pre-encoded from managed resource's connection secret
                kubeconfig = _ocds["gkecluster"].ConnectionDetails?.kubeconfig or _ocds?["connection-secret"]?.Resource?.data?.kubeconfig or ""
            }
        else:
            data = {}
    }
]

# Read the observed NodePool nodeConfig. upjet serializes nodeConfig as either a
# single object or a single-element list depending on the provider version, so
# handle both shapes; fall back to the desired machineType when unset.
_nodepool_node_config = _ocds?["node-pool"]?.Resource?.status?.atProvider?.nodeConfig
_nodepool_node_config_obj = (_nodepool_node_config[0] if len(_nodepool_node_config) > 0 else {}) if typeof(_nodepool_node_config) == "list" else (_nodepool_node_config or {})
_nodepool_machine_type = _nodepool_node_config_obj?.machineType or params.nodes.instanceType

# Observed cluster metadata name, falling back to the params.id external name.
_observed_cluster_name = _ocds?.gkecluster?.Resource?.metadata?.name or params.id

# Surface typed status into the freeform status.gke so higher-level
# configurations (e.g. configuration-gcp-ctp) can compose a GKE XR and read the
# resolved project, workload pool, kubeconfig secret and running machine type
# instead of composing their own observe-only managed resources. Emit a minimal
# status patch on the composite (apiVersion/kind/metadata carry identity; the
# rest of the spec is left untouched so function-auto-ready still aggregates
# composed-resource readiness).
_status_patch = {
    apiVersion: _dxr.apiVersion
    kind: _dxr.kind
    metadata: {
        name: oxr.metadata.name
        namespace: oxr.metadata.namespace
    }
    status: {
        gke: {
            clusterName: _observed_cluster_name
            project: _project_id
            workloadPool: "{}.svc.id.goog".format(_project_id)
            kubeconfigSecretRef: {
                name: "{}-connection".format(oxr.metadata.name)
                namespace: oxr.metadata.namespace
                key: "kubeconfig"
            }
            nodePool: {
                instanceType: _nodepool_machine_type
            }
        }
    }
}

_raw_items = _base_items + _gke_items + [_status_patch]

# All resources are local to the XR. Status patches preserve the XR's identity.
items = [
    item | {metadata.namespace = oxr.metadata.namespace}
    for item in _raw_items
]
