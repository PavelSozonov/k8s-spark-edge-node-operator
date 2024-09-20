#!/bin/bash

# Create project directories
mkdir -p mlops_spark_operator
cd mlops_spark_operator

# Create subdirectories for different components
mkdir -p deploy docker operator configs

# Dockerfile content (placed in docker/ directory)
cat <<EOF > docker/Dockerfile
FROM python:3.12-slim

# Install necessary dependencies
RUN pip install kopf kubernetes

# Copy the operator code into the container
COPY operator/operator.py /operator.py

# Run the operator
CMD ["kopf", "run", "/operator.py"]
EOF

# operator.py content (placed in operator/ directory)
cat <<EOF > operator/operator.py
import kopf
import kubernetes
from kubernetes.client import CustomObjectsApi, Configuration
from kubernetes.config import load_incluster_config, load_kube_config

# Load Kubernetes configuration
try:
    load_incluster_config()
except kubernetes.config.ConfigException:
    load_kube_config()

# Namespace where the operator is deployed
OPERATOR_NAMESPACE = "mlops-spark-operator"

# CRD Details
CRD_GROUP = "mlops.example.com"
CRD_VERSION = "v1"
CRD_PLURAL = "sparknotebooks"

def get_next_free_id(existing_ids):
    """Find the next available ID in the range 0-1000."""
    for i in range(1001):
        if i not in existing_ids:
            return i
    raise ValueError("No available IDs in the range 0-1000")

def get_existing_ids():
    """Retrieve all existing IDs from SparkNotebook CRDs across all namespaces."""
    api = CustomObjectsApi()
    spark_notebooks = api.list_cluster_custom_object(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
    existing_ids = set()
    for item in spark_notebooks.get('items', []):
        spec = item.get('spec', {})
        id_value = spec.get('id')
        if id_value is not None:
            existing_ids.add(id_value)
    return existing_ids

@kopf.on.create(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def create_fn(spec, name, namespace, **kwargs):
    """Handle the creation of a new SparkNotebook."""
    api = CustomObjectsApi()
    existing_ids = get_existing_ids()
    next_id = get_next_free_id(existing_ids)

    # Patch the newly created CRD with the next free ID
    patch_body = {'spec': spec.copy()}
    patch_body['spec']['id'] = next_id
    api.patch_namespaced_custom_object(
        CRD_GROUP, CRD_VERSION, namespace, CRD_PLURAL, name, patch_body)

    kopf.info(f"Assigned ID {next_id} to SparkNotebook {name} in namespace {namespace}")

@kopf.on.delete(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def delete_fn(spec, name, namespace, **kwargs):
    """Handle the deletion of a SparkNotebook."""
    kopf.info(f"SparkNotebook {name} in namespace {namespace} deleted.")

# Start the operator
if __name__ == '__main__':
    kopf.run()
EOF

# sparknotebook-crd.yaml content (placed in deploy/ directory)
cat <<EOF > deploy/sparknotebook-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: sparknotebooks.mlops.example.com
spec:
  group: mlops.example.com
  names:
    kind: SparkNotebook
    listKind: SparkNotebookList
    plural: sparknotebooks
    singular: sparknotebook
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              id:
                type: integer
                minimum: 0
                maximum: 1000
EOF

# rbac.yaml content (placed in deploy/ directory)
cat <<EOF > deploy/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mlops-spark-operator
  namespace: mlops-spark-operator

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: mlops-spark-operator
rules:
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch", "update"]
- apiGroups: ["mlops.example.com"]
  resources: ["sparknotebooks"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: ["mlops.example.com"]
  resources: ["sparknotebooks/status"]
  verbs: ["update"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: mlops-spark-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: mlops-spark-operator
subjects:
- kind: ServiceAccount
  name: mlops-spark-operator
  namespace: mlops-spark-operator
EOF

# deployment.yaml content (placed in deploy/ directory)
cat <<EOF > deploy/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlops-spark-operator
  namespace: mlops-spark-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mlops-spark-operator
  template:
    metadata:
      labels:
        app: mlops-spark-operator
    spec:
      serviceAccountName: mlops-spark-operator
      containers:
      - name: mlops-spark-operator
        image: mlops-spark-operator:latest
        imagePullPolicy: IfNotPresent
EOF

# Namespace creation (added to deploy/ directory)
cat <<EOF > deploy/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mlops-spark-operator
EOF

# kind-config.yaml content (placed in configs/ directory)
cat <<EOF > configs/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
EOF

# skaffold.yaml content (placed in root directory)
cat <<EOF > skaffold.yaml
apiVersion: skaffold/v4beta11
kind: Config
metadata:
  name: mlops-spark-operator
build:
  artifacts:
  - image: mlops-spark-operator
    context: .
    docker:
      dockerfile: docker/Dockerfile
manifests:
  rawYaml:
    - deploy/namespace.yaml
    - deploy/sparknotebook-crd.yaml
    - deploy/rbac.yaml
    - deploy/deployment.yaml
EOF

# Instructions
echo "Project structure created with subdirectories. Next steps:"
echo "1. Create a kind cluster:"
echo "   kind create cluster --name mlops-cluster --config configs/kind-config.yaml"
echo "2. Run Skaffold to build and deploy the operator, including namespace creation:"
echo "   skaffold dev"
