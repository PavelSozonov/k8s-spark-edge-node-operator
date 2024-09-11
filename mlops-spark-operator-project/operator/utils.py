import kubernetes
from kubernetes.client import CoreV1Api, CustomObjectsApi
from kubernetes.client.rest import ApiException
import copy

# Namespace where the operator is deployed
OPERATOR_NAMESPACE = "mlops-spark-operator"

def get_next_free_id(existing_ids, max_id):
    """
    Find the next available free ID below or equal to max-id.
    
    Parameters:
    - existing_ids: Set of currently used IDs.
    - max_id: Maximum allowable ID.

    Returns:
    - The next available free ID if found, or None if no ID is available.
    """
    for i in range(max_id + 1):
        if i not in existing_ids:
            return i
    return None  # No available ID

def assign_ports(id, initial_port):
    """
    Assign three consecutive ports based on the given ID and the initial port.
    
    Parameters:
    - id: The unique ID of the SparkNotebook.
    - initial_port: The starting port number.

    Returns:
    - A list of three consecutive ports.
    """
    base_port = initial_port + (id * 3)
    return [base_port, base_port + 1, base_port + 2]

def get_config_params():
    """
    Fetch max-id and initial-port from the ConfigMap in the operator namespace.
    
    Returns:
    - max_id: Maximum allowable ID.
    - initial_port: Initial port number.
    """
    core_v1_api = CoreV1Api()
    config_map = core_v1_api.read_namespaced_config_map(
        name="mlops-spark-operator-config", namespace=OPERATOR_NAMESPACE
    )
    max_id = int(config_map.data.get("max-id", "1000"))  # Default max-id is 1000 if not set
    initial_port = int(config_map.data.get("initial-port", "8100"))  # Default initial port is 8100
    return max_id, initial_port

def get_existing_ids():
    """
    Get all existing IDs from SparkNotebook CRDs.
    
    Returns:
    - A set of IDs currently in use.
    """
    api = CustomObjectsApi()
    spark_notebooks = api.list_cluster_custom_object("mlops.example.com", "v1", "sparknotebooks")
    existing_ids = set()
    for item in spark_notebooks.get('items', []):
        spec = item.get('spec', {})
        id_value = spec.get('id')
        if id_value is not None:
            existing_ids.add(id_value)
    return existing_ids

def get_template_configmap():
    """
    Fetch the ConfigMap template from the operator's namespace.
    
    Returns:
    - The template ConfigMap object.
    """
    api = CoreV1Api()
    try:
        return api.read_namespaced_config_map("template-configmap", OPERATOR_NAMESPACE)
    except ApiException as e:
        if e.status == 404:
            raise kopf.PermanentError(f"Template ConfigMap not found in {OPERATOR_NAMESPACE}")
        else:
            raise e

def create_config_map(name, namespace, template_configmap):
    """
    Create a ConfigMap for Nexus config based on a template.
    
    Parameters:
    - name: The name of the SparkNotebook.
    - namespace: The namespace where the SparkNotebook is created.
    - template_configmap: The ConfigMap template object.
    """
    api = CoreV1Api()

    # Copy the template and modify it
    new_configmap = copy.deepcopy(template_configmap)
    new_configmap.metadata.namespace = namespace
    new_configmap.metadata.name = f"{name}-nexus-config"
    
    try:
        api.create_namespaced_config_map(namespace=namespace, body=new_configmap)
    except ApiException as e:
        if e.status == 404:
            raise kopf.PermanentError(f"ConfigMap {name}-nexus-config not found in namespace {namespace}.")
        else:
            raise e

def delete_config_map(name, namespace):
    """
    Delete the ConfigMap associated with a SparkNotebook.
    
    Parameters:
    - name: The name of the SparkNotebook.
    - namespace: The namespace where the SparkNotebook is located.
    """
    api = CoreV1Api()
    try:
        api.delete_namespaced_config_map(name=f"{name}-nexus-config", namespace=namespace)
    except ApiException as e:
        if e.status == 404:
            kopf.info(f"ConfigMap {name}-nexus-config not found, skipping deletion.")
        else:
            raise e
