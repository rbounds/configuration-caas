"""Exercise the installed OSS function pipeline with the Crossplane v2 CLI.

Requires Docker and PyYAML; no control plane or cloud credentials are used.
"""
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CLI = os.environ.get("CROSSPLANE", "crossplane")
CLUSTERS = {"aws": "XEKS", "azure": "XAKS", "gcp": "XGKE"}
NETWORKS = {"aws": "XNetworkAWS", "azure": "XNetworkAZURE", "gcp": "XNetworkGCP"}


def example(cloud, operator):
    return yaml.safe_load((ROOT / f"examples/{operator}/{cloud}-cluster.yaml").read_text())


def observed(name, ready=True, **fields):
    kind = "Secret" if name == "connection-secret" else name
    group = "v1" if kind == "Secret" else "aws.platform.upbound.io/v1alpha1"
    if name == "XAKS":
        group = "azure.platform.upbound.io/v1alpha1"
    elif name == "XGKE":
        group = "gcp.platform.upbound.io/v1alpha1"
    return {
        "apiVersion": group,
        "kind": kind,
        "metadata": {"name": name.lower(), "namespace": "team-a", "annotations": {
            "crossplane.io/composition-resource-name": name,
        }},
        "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]},
        **fields,
    }


def source_resources(xr, value="first-kubeconfig", namespace=None):
    namespace = namespace or xr["metadata"]["namespace"]
    return [
        {"apiVersion": "helm.m.crossplane.io/v1beta1", "kind": "ProviderConfig",
         "metadata": {"name": xr["spec"]["parameters"]["id"], "namespace": namespace},
         "spec": {"credentials": {"source": "Secret", "secretRef": {
             "name": "provider-generated-kubeconfig", "namespace": namespace, "key": "kubeconfig",
         }}}},
        {"apiVersion": "v1", "kind": "Secret",
         "metadata": {"name": "provider-generated-kubeconfig", "namespace": namespace},
         "data": {"kubeconfig": base64.b64encode(value.encode()).decode()}},
    ]


def render(xr, resources=(), required=(), component="xcluster"):
    api_dir = ROOT / ("apis" if component == "xcluster" else f"apis/{component}")
    with tempfile.TemporaryDirectory(prefix="caas-render-") as directory:
        tmp = Path(directory)
        for filename, data in [("xr.yaml", [xr]), ("observed.yaml", resources), ("required.yaml", required)]:
            (tmp / filename).write_text(yaml.safe_dump_all(data))
        command = [CLI, "composition", "render", str(tmp / "xr.yaml"), str(api_dir / "composition.yaml"),
                   str(ROOT / "examples/functions.yaml"), f"--xrd={api_dir / 'definition.yaml'}"]
        if resources:
            command.append(f"--observed-resources={tmp / 'observed.yaml'}")
        if required:
            command.append(f"--required-resources={tmp / 'required.yaml'}")
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
        documents = list(yaml.safe_load_all(result.stdout))
        return {doc["metadata"]["annotations"]["crossplane.io/composition-resource-name"]: doc
                for doc in documents if "crossplane.io/composition-resource-name" in doc.get("metadata", {}).get("annotations", {})}


class CompositionTests(unittest.TestCase):
    def test_namespace_isolation_with_identical_cluster_ids(self):
        xr = example("azure", "flux")
        other = copy.deepcopy(xr)
        other["metadata"]["namespace"] = "team-b"
        required = source_resources(xr, value="team-a-access") + source_resources(other, value="team-b-access")
        for request, expected in ((xr, "team-a-access"), (other, "team-b-access")):
            with self.subTest(namespace=request["metadata"]["namespace"]):
                items = render(request, required=required)
                self.assertTrue(all(item["metadata"]["namespace"] == request["metadata"]["namespace"] for item in items.values()))
                self.assertEqual(expected, base64.b64decode(items["connection-secret"]["data"]["kubeconfig"]).decode())

    def test_cross_namespace_kubeconfig_reference_is_rejected(self):
        xr = example("aws", "flux")
        required = source_resources(xr)
        required[0]["spec"]["credentials"]["secretRef"]["namespace"] = "team-b"
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            render(xr, required=required)
        self.assertIn("kubeconfig must remain in the XCluster namespace", caught.exception.stderr)

    def test_bundled_apis_emit_only_namespaced_resources(self):
        components = json.loads((ROOT / "third_party/sources.json").read_text())
        pairs = {(item["apiVersion"], item["kind"]) for item in components}
        for component in components:
            name = component["component"]
            with self.subTest(component=name):
                definition = yaml.safe_load((ROOT / f"apis/{name}/definition.yaml").read_text())
                self.assertEqual("Namespaced", definition["spec"]["scope"])
                xr = yaml.safe_load((ROOT / f"tests/fixtures/{name}.yaml").read_text())
                items = render(xr, component=name)
                self.assertTrue(items)
                for item in items.values():
                    self.assertEqual("team-a", item["metadata"]["namespace"])
                    self.assertTrue(".m." in item["apiVersion"] or item["apiVersion"] == "v1" or
                                    item["apiVersion"] == "protection.crossplane.io/v1beta1" or
                                    (item["apiVersion"], item["kind"]) in pairs, item["apiVersion"])
                    self.assertNotEqual("ClusterUsage", item["kind"])
                    reference = item.get("spec", {}).get("providerConfigRef")
                    if reference:
                        self.assertEqual("ProviderConfig", reference["kind"])
                    secret_ref = item.get("spec", {}).get("writeConnectionSecretToRef")
                    if secret_ref:
                        self.assertNotIn("namespace", secret_ref)

    def test_gke_readiness_and_transient_service_account_failure(self):
        xr = yaml.safe_load((ROOT / "tests/fixtures/gcp-gke.yaml").read_text())
        service_account = observed("serviceaccount", status={"conditions": [{"type": "Ready", "status": "True"}],
            "atProvider": {"id": "projects/test-project/serviceAccounts/gke@test-project.iam.gserviceaccount.com",
                           "email": "gke@test-project.iam.gserviceaccount.com"}})
        items = render(xr, [service_account], component="gcp-gke")
        for name in ("gkecluster", "node-pool", "providerConfigHelm", "providerConfigKubernetes", "connection-secret"):
            self.assertIn(name, items)
            self.assertEqual("team-a", items[name]["metadata"]["namespace"])
        self.assertEqual("caas-gcp-flux-gkecluster", items["gkecluster"]["spec"]["writeConnectionSecretToRef"]["name"])
        cluster = items["gkecluster"]
        service_account["status"]["conditions"][0]["status"] = "False"
        items = render(xr, [service_account, cluster], component="gcp-gke")
        self.assertIn("gkecluster", items)
        self.assertIn("node-pool", items)

    def test_eks_auth_and_node_pool_stages(self):
        xr = yaml.safe_load((ROOT / "tests/fixtures/aws-eks.yaml").read_text())
        state = [observed(name, status={"conditions": [{"type": "Ready", "status": "True"}], "atProvider": {}})
                 for name in ("kubernetesCluster", "kubernetesClusterAuth", "vpc-cni-addon", "nodeGroupPublic",
                              "ebsCSIDriverPodIdentityAssociation")]
        items = render(xr, state, component="aws-eks")
        for name in ("kubernetesClusterAuth", "nodeGroupPublic", "vpc-cni-addon", "aws-ebs-csi-driver-addon",
                     "eks-pod-identity-agent-addon"):
            self.assertIn(name, items)
            self.assertEqual("team-a", items[name]["metadata"]["namespace"])
        self.assertEqual({"name": "caas-aws-flux-ekscluster"}, items["kubernetesClusterAuth"]["spec"]["writeConnectionSecretToRef"])

    def test_initial_cluster_for_each_cloud_and_operator(self):
        for cloud in CLUSTERS:
            for operator in ("flux", "argocd"):
                with self.subTest(cloud=cloud, operator=operator):
                    xr = example(cloud, operator)
                    items = render(xr)
                    self.assertIn(NETWORKS[cloud], items)
                    cluster = items[CLUSTERS[cloud]]
                    for key in ("id", "region", "version", "nodes", "providerConfigName"):
                        self.assertEqual(xr["spec"]["parameters"][key], cluster["spec"]["parameters"][key])
                    self.assertEqual("team-a", cluster["metadata"]["namespace"])
                    self.assertEqual(["*"], cluster["spec"]["parameters"]["managementPolicies"])
                    for name in ("XAWSLBController", "XOss", "XFlux", "XArgo"):
                        self.assertNotIn(name, items)
                    secret = items["connection-secret"]
                    self.assertEqual("Secret", secret["kind"])
                    self.assertEqual({}, secret["data"])

    def test_aws_waits_for_load_balancer_before_addons(self):
        items = render(example("aws", "flux"), [observed("XEKS")])
        self.assertIn("XAWSLBController", items)
        self.assertNotIn("XOss", items)
        self.assertNotIn("XFlux", items)

    def test_ready_cluster_addons_and_native_secret_for_each_cloud_and_operator(self):
        for cloud in CLUSTERS:
            for operator in ("flux", "argocd"):
                with self.subTest(cloud=cloud, operator=operator):
                    xr = example(cloud, operator)
                    resources = [observed(CLUSTERS[cloud], status={"conditions": [{"type":"Ready", "status":"True"}], "eks":{"clusterName":"eks-test"}})]
                    if cloud == "aws":
                        resources += [observed("XAWSLBController"), observed("XNetworkAWS", status={"vpcId": "vpc-test"})]
                    source_namespace = xr["metadata"]["namespace"]
                    required = source_resources(xr, namespace=source_namespace)
                    items = render(xr, resources, required)
                    gitops = "XFlux" if operator == "flux" else "XArgo"
                    self.assertIn("XOss", items)
                    self.assertIn(gitops, items)
                    self.assertNotIn("XArgo" if operator == "flux" else "XFlux", items)
                    self.assertEqual(xr["spec"]["parameters"]["id"], items[gitops]["spec"]["parameters"]["providerConfigName"])
                    secret = items["connection-secret"]
                    self.assertEqual(required[1]["data"], secret["data"])
                    self.assertEqual(xr["spec"]["writeConnectionSecretToRef"], {
                        "name": secret["metadata"]["name"],
                    })
                    usages = [item for item in items.values() if item["kind"] == "Usage"]
                    self.assertTrue(any(item["spec"]["by"]["kind"] == items[gitops]["kind"] for item in usages))
                    self.assertTrue(all(item["apiVersion"] == "protection.crossplane.io/v1beta1" for item in usages))
                    if cloud == "aws":
                        self.assertEqual("vpc-test", items["XAWSLBController"]["spec"]["parameters"]["vpcId"])

    def test_existing_addons_survive_transient_not_ready(self):
        for operator, name in (("flux", "XFlux"), ("argocd", "XArgo")):
            with self.subTest(operator=operator):
                items = render(example("aws", operator), [observed("XEKS", False),
                    observed("XAWSLBController", False), observed("XOss", False), observed(name, False)])
                for resource_name in ("XAWSLBController", "XOss", name):
                    self.assertIn(resource_name, items)

    def test_secret_rotation_and_transient_missing_source(self):
        xr = example("azure", "flux")
        xr["spec"]["writeConnectionSecretToRef"] = {"name": "custom-access"}
        previous = observed("connection-secret", data={"kubeconfig": "b2xk"})
        previous["metadata"].update(name="custom-access", namespace="team-a")
        items = render(xr, [previous], source_resources(xr, value="rotated-kubeconfig"))
        secret = items["connection-secret"]
        self.assertEqual("rotated-kubeconfig", base64.b64decode(secret["data"]["kubeconfig"]).decode())
        self.assertEqual("team-a", secret["metadata"]["namespace"])
        self.assertEqual("team-a", items["XAKS"]["metadata"]["namespace"])
        self.assertEqual("custom-access", secret["metadata"]["name"])
        items = render(xr, [previous])
        self.assertEqual(previous["data"], items["connection-secret"]["data"])

    def test_schema_defaults_and_aws_iam_user(self):
        xr = copy.deepcopy(example("aws", "flux"))
        parameters = xr["spec"]["parameters"]
        for key in ("deletionPolicy", "providerConfigName", "operators"):
            parameters.pop(key)
        parameters["iam"] = {"userArn": "arn:aws:iam::123456789012:user/platform-admin"}
        xr["spec"].pop("writeConnectionSecretToRef")
        items = render(xr)
        self.assertEqual(["*"], items["XEKS"]["spec"]["parameters"]["managementPolicies"])
        self.assertEqual("default", items["XEKS"]["spec"]["parameters"]["providerConfigName"])
        self.assertEqual(parameters["iam"]["userArn"], items["XEKS"]["spec"]["parameters"]["iam"]["principalArn"])
        self.assertEqual(parameters["id"] + "-kubeconfig", items["connection-secret"]["metadata"]["name"])


if __name__ == "__main__":
    unittest.main()
