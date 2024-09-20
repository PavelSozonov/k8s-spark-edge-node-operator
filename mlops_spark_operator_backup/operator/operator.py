import kopf
import kubernetes
from kubernetes.client import CustomObjectsApi, CoreV1Api, Configuration
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

# Prevent event sourcing on kopf.info messages
@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    settings.posting.enabled = False
    #clusterwide = True

# Fetch max-id from the ConfigMap
def get_max_id():
    core_v1_api = CoreV1Api()
    config_map = core_v1_api.read_namespaced_config_map(
        name="mlops-spark-operator-config", namespace=OPERATOR_NAMESPACE
    )
    return int(config_map.data.get("max-id", "20"))  # TODO: Default max-id is 1000 if not set

# Get all existing IDs from SparkNotebook CRDs
def get_existing_ids():
    api = CustomObjectsApi()
    spark_notebooks = api.list_cluster_custom_object(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
    existing_ids = set()
    for item in spark_notebooks.get('items', []):
        spec = item.get('spec', {})
        id_value = spec.get('id')
        if id_value is not None:
            existing_ids.add(id_value)
    return existing_ids

# Find the next available free ID below or equal to max-id
def get_next_free_id(existing_ids, max_id):
    for i in range(max_id + 1):
        if i not in existing_ids:
            return i
    return None  # No available ID

@kopf.on.create(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def create_fn(spec, name, namespace, **kwargs):
    """Handle the creation of a new SparkNotebook."""
    max_id = get_max_id()
    existing_ids = get_existing_ids()
    next_id = get_next_free_id(existing_ids, max_id)

    if next_id is None:
        raise kopf.PermanentError(f"No free ID found below or equal to max-id ({max_id}). Creation of SparkNotebook {name} aborted.")

    # Patch the newly created CRD with the next free ID
    patch_body = {
        'spec': {**spec, 'id': next_id},
        'status': {'initialized': True}  # Add a status field to mark creation as complete
    }
    api = CustomObjectsApi()
    api.patch_namespaced_custom_object(
        CRD_GROUP, CRD_VERSION, namespace, CRD_PLURAL, name, patch_body
    )

    kopf.info(f"Assigned ID {next_id} to SparkNotebook {name} in namespace {namespace}", reason="Created")


@kopf.on.update(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def update_fn(old, new, status, name, namespace, **kwargs):
    """Handle the update of a SparkNotebook."""

    kopf.info("000", reason="Fake")

    # Check if the resource has been fully initialized; if not, skip this update
    if not status.get('initialized', False):
        kopf.info(f"Skipping update for {name} in namespace {namespace}, resource not fully initialized.", reason="NotInitialized")
        kopf.info("111", reason="Fake")
        return

    old_id = old.get('spec', {}).get('id')
    new_id = new.get('spec', {}).get('id')
    kopf.info("New ID {new_id}", reason="Fake")
    kopf.info("Max ID {max_id}", reason="Fake")

    # If the ID is the same, it's a valid update, no need to raise an error
    if old_id == new_id:
        kopf.info(f"Update for {name} in namespace {namespace} is valid, 'id' has not changed.", reason="NoChange")
        kopf.info("222", reason="Fake")
        return

    max_id = get_max_id()
    existing_ids = get_existing_ids()

    # If the new id is already taken by another CRD or exceeds max-id, raise an error
    if new_id in existing_ids and new_id != old_id:
        raise kopf.PermanentError(f"ID {new_id} is already taken by another SparkNotebook. Cannot update {name}.")
    if new_id > max_id:
        raise kopf.PermanentError(f"ID {new_id} exceeds max-id ({max_id}). Cannot update {name}.")

    kopf.info(f"Updated SparkNotebook {name} in namespace {namespace} with ID {new_id}", reason="Updated")


@kopf.on.delete(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def delete_fn(spec, name, namespace, **kwargs):
    """Handle the deletion of a SparkNotebook and reassign IDs to all CRDs without an ID."""
    
    deleted_id = spec.get('id')
    
    # Log the deletion
    kopf.info(f"SparkNotebook {name} in namespace {namespace} deleted with ID {deleted_id}.", reason="Deleted")
    
    # If the deleted CRD had an ID, we proceed to check for any CRDs without an ID
    if deleted_id is not None:
        api = CustomObjectsApi()
        spark_notebooks = api.list_cluster_custom_object(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
        
        # Get the max id and list of existing ids
        max_id = get_max_id()
        existing_ids = get_existing_ids()
        
        # Add the deleted ID to the pool of available IDs
        existing_ids.discard(deleted_id)
        
        # Find all CRDs without an ID
        notebooks_without_id = [nb for nb in spark_notebooks.get('items', []) if nb.get('spec', {}).get('id') is None]
        
        # Assign IDs to all CRDs without an ID
        for notebook in notebooks_without_id:
            next_free_id = get_next_free_id(existing_ids, max_id)
            if next_free_id is None:
                kopf.info(f"No more available IDs to assign to SparkNotebook {notebook['metadata']['name']}", reason="NoIDAvailable")
                continue  # No available ID to assign
            
            # Assign the next available ID to this CRD
            notebook_name = notebook['metadata']['name']
            notebook_namespace = notebook['metadata']['namespace']
            
            # Patch the CRD with the next free ID
            patch_body = {
                'spec': {'id': next_free_id}
            }
            
            api.patch_namespaced_custom_object(
                CRD_GROUP, CRD_VERSION, notebook_namespace, CRD_PLURAL, notebook_name, patch_body
            )
            
            kopf.info(f"Assigned ID {next_free_id} to SparkNotebook {notebook_name} in namespace {notebook_namespace}", reason="IDAssigned")
            
            # Mark the ID as taken
            existing_ids.add(next_free_id)
