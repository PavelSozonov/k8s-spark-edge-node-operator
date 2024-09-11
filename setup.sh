#!/bin/bash

set -e

# Variables
PROJECT_HOME="mlops-spark-operator-project"
OPERATOR_DIR="${PROJECT_HOME}/operator"
WEBHOOK_DIR="${PROJECT_HOME}/webhook"
MANIFESTS_DIR="${PROJECT_HOME}/manifests"
CERT_DIR="${WEBHOOK_DIR}/certs"
OPERATOR_NAMESPACE="mlops-spark-operator"
WEBHOOK_SERVICE="sparknotebook-webhook"
WEBHOOK_SECRET_NAME="webhook-tls-secret"
TLS_CRT="${CERT_DIR}/tls.crt"
TLS_KEY="${CERT_DIR}/tls.key"

# Step 1: Create project structure
echo "Creating project structure..."
mkdir -p ${OPERATOR_DIR} ${WEBHOOK_DIR} ${CERT_DIR} ${MANIFESTS_DIR}

# Step 2: Generate self-signed certificates and place them in the webhook certs directory
echo "Generating self-signed certificates..."
openssl req -x509 -newkey rsa:4096 -keyout ${TLS_KEY} -out ${TLS_CRT} -days 365 -nodes -subj "/CN=${WEBHOOK_SERVICE}.${OPERATOR_NAMESPACE}.svc"

# Step 3: Base64 encode the certificates based on the OS (macOS vs Linux)
echo "Encoding certificates to base64..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS does not support the -w option for base64
    TLS_CRT_BASE64=$(base64 < ${TLS_CRT})
    TLS_KEY_BASE64=$(base64 < ${TLS_KEY})
else
    # Linux supports the -w0 option for base64 (no line wrapping)
    TLS_CRT_BASE64=$(base64 -w0 < ${TLS_CRT})
    TLS_KEY_BASE64=$(base64 -w0 < ${TLS_KEY})
fi

# Step 4: Create Kubernetes Secret for the TLS certificates
echo "Creating Kubernetes secret for TLS certificates..."
cat <<EOF > ${MANIFESTS_DIR}/webhook-tls-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ${WEBHOOK_SECRET_NAME}
  namespace: ${OPERATOR_NAMESPACE}
type: kubernetes.io/tls
data:
  tls.crt: ${TLS_CRT_BASE64}
  tls.key: ${TLS_KEY_BASE64}
EOF

# Step 5: Create Dockerfile for the operator
echo "Creating Dockerfile for the operator..."
cat <<EOF > ${OPERATOR_DIR}/Dockerfile
# Dockerfile for MLOps Spark Operator

FROM python:3.12-slim

# Install necessary packages with fixed versions
RUN pip install --no-cache-dir kopf==1.37.2 kubernetes==30.1.0

# Add the operator script
ADD operator.py /operator.py

# Run the operator
CMD ["kopf", "run", "/operator.py"]
EOF

# Step 6: Create Dockerfile for the webhook
echo "Creating Dockerfile for the webhook..."
cat <<EOF > ${WEBHOOK_DIR}/Dockerfile
# Dockerfile for MLOps Admission Webhook

FROM python:3.12-slim

# Install necessary packages with fixed versions
RUN pip install --no-cache-dir fastapi==0.114.0 uvicorn==0.30.6 kubernetes==30.1.0

# Copy certificates
COPY certs/tls.crt /etc/tls/tls.crt
COPY certs/tls.key /etc/tls/tls.key

# Add the webhook script
ADD admission_webhook.py /admission_webhook.py

# Run the webhook server with FastAPI and Uvicorn
CMD ["uvicorn", "admission_webhook:app", "--host", "0.0.0.0", "--port", "443", "--ssl-keyfile", "/etc/tls/tls.key", "--ssl-certfile", "/etc/tls/tls.crt"]
EOF

# Step 7: Create operator.py script
echo "Creating operator.py script..."
cat <<EOF > ${OPERATOR_DIR}/operator.py
import kopf
import kubernetes
from kubernetes.client import CustomObjectsApi, CoreV1Api

# Namespace where the operator is deployed
OPERATOR_NAMESPACE = "mlops-spark-operator"

# CRD Details
CRD_GROUP = "mlops.example.com"
CRD_VERSION = "v1"
CRD_PLURAL = "sparknotebooks"

@kopf.on.create(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def create_fn(spec, name, namespace, **kwargs):
    # Implement the operator logic for creation
    pass

@kopf.on.update(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def update_fn(old, new, name, namespace, **kwargs):
    # Implement the operator logic for update
    pass

@kopf.on.delete(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def delete_fn(name, namespace, **kwargs):
    # Implement the operator logic for deletion
    pass
EOF

# Step 8: Create admission_webhook.py script
echo "Creating admission_webhook.py script..."
cat <<EOF > ${WEBHOOK_DIR}/admission_webhook.py
from fastapi import FastAPI, Request
import kubernetes.client
from kubernetes import config
import uvicorn

app = FastAPI()

# Load Kubernetes config
config.load_incluster_config()

# Namespace where the webhook is deployed
WEBHOOK_NAMESPACE = "mlops-spark-operator"

def get_max_id():
    v1 = kubernetes.client.CoreV1Api()
    config_map = v1.read_namespaced_config_map("mlops-spark-operator-config", WEBHOOK_NAMESPACE)
    return int(config_map.data.get("max-id", "20"))

@app.post("/validate")
async def validate(request: Request):
    request_info = await request.json()
    operation = request_info["request"]["operation"]
    resource_name = request_info["request"]["name"]

    if operation in ["CREATE", "UPDATE"]:
        spec = request_info["request"]["object"]["spec"]
        new_id = spec.get("id")
        if new_id is not None:
            max_id = get_max_id()
            if new_id > max_id:
                return {
                    "response": {
                        "allowed": False,
                        "status": {
                            "message": f"ID {new_id} exceeds max-id {max_id}.",
                        }
                    }
                }

    return {"response": {"allowed": True}}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=443, ssl_keyfile="/etc/tls/tls.key", ssl_certfile="/etc/tls/tls.crt")
EOF

# Step 9: Create Kubernetes manifests

# Namespace
cat <<EOF > ${MANIFESTS_DIR}/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${OPERATOR_NAMESPACE}
EOF

# SparkNotebook CRD
cat <<EOF > ${MANIFESTS_DIR}/sparknotebook-crd.yaml
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
    shortNames:
      - sparknb
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
      additionalPrinterColumns:
        - name: ID
          type: integer
          jsonPath: .spec.id
          description: "ID of the SparkNotebook"
        - name: AGE
          type: date
          jsonPath: .metadata.creationTimestamp
          description: "Age of the SparkNotebook resource"
EOF

# Operator deployment
cat <<EOF > ${MANIFESTS_DIR}/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlops-spark-operator
  namespace: ${OPERATOR_NAMESPACE}
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
      containers:
        - name: operator
          image: mlops-spark-operator
          ports:
            - containerPort: 8080
EOF

# Webhook deployment
cat <<EOF > ${MANIFESTS_DIR}/webhook-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${WEBHOOK_SERVICE}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${WEBHOOK_SERVICE}
  template:
    metadata:
      labels:
        app: ${WEBHOOK_SERVICE}
    spec:
      containers:
        - name: webhook
          image: mlops-spark-webhook
          ports:
            - containerPort: 443
          volumeMounts:
            - name: webhook-tls
              mountPath: /etc/tls
              readOnly: true
      volumes:
        - name: webhook-tls
          secret:
            secretName: ${WEBHOOK_SECRET_NAME}
EOF

# RBAC configuration
cat <<EOF > ${MANIFESTS_DIR}/rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: mlops-spark-operator
rules:
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch", "update", "get", "list", "watch"]
- apiGroups: ["mlops.example.com"]
  resources: ["sparknotebooks"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["mlops.example.com"]
  resources: ["sparknotebooks/status"]
  verbs: ["update"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch"]
EOF

# ConfigMap
cat <<EOF > ${MANIFESTS_DIR}/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mlops-spark-operator-config
  namespace: ${OPERATOR_NAMESPACE}
data:
  max-id: "20"
EOF

# Step 10: Create Skaffold configuration
echo "Creating Skaffold configuration..."

cat <<EOF > ${PROJECT_HOME}/skaffold.yaml
apiVersion: skaffold/v4beta11
kind: Config
metadata:
  name: mlops-spark-operator
build:
  artifacts:
  - image: mlops-spark-operator
    context: operator
    docker:
      dockerfile: Dockerfile
  - image: mlops-spark-webhook
    context: webhook
    docker:
      dockerfile: Dockerfile
manifests:
  rawYaml:
    - manifests/namespace.yaml
    - manifests/sparknotebook-crd.yaml
    - manifests/rbac.yaml
    - manifests/configmap.yaml
    - manifests/deployment.yaml
    - manifests/webhook-deployment.yaml
    - manifests/webhook-tls-secret.yaml
EOF

echo "Project setup complete."
echo "The project has been created in the ${PROJECT_HOME} folder."
