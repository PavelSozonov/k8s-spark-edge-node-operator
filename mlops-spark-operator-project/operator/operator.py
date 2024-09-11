import kopf
from kubernetes.client import CustomObjectsApi
from utils import (
    get_next_free_id,
    assign_ports,
    get_config_params,
    get_existing_ids,
    get_template_configmap,
    create_config_map,
    delete_config_map,
)

# CRD Details
CRD_GROUP = "mlops.example.com"
CRD_VERSION = "v1"
CRD_PLURAL = "sparknotebooks"

def patch_sparknotebook_status(api, name, namespace, patch_body):
    """Patch the status of the SparkNotebook CRD."""
    try:
        api.patch_namespaced_custom_object(
            CRD_GROUP, CRD_VERSION, namespace, CRD_PLURAL, name, patch_body
        )
    except ApiException as e:
        if e.status == 404:
            kopf.info(f"SparkNotebook {name} not found in namespace {namespace}, skipping patch.", reason="NotFound")
        else:
            raise e

@kopf.on.create(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def create_fn(spec, name, namespace, **kwargs):
    """Handle the creation of a new SparkNotebook."""
    max_id, initial_port = get_config_params()  # Fetch config parameters
    existing_ids = get_existing_ids()
    next_id = get_next_free_id(existing_ids, max_id)

    if next_id is None:
        raise kopf.PermanentError(f"No free ID found below or equal to max-id ({max_id}). Creation of SparkNotebook {name} aborted.")

    # Assign three consecutive ports based on the id and initial port
    assigned_ports = assign_ports(next_id, initial_port)

    # Patch the newly created CRD with the next free ID and assigned ports
    patch_body = {
        'spec': {**spec, 'id': next_id},
        'status': {
            'initialized': True,  # Add a status field to mark creation as complete
            'ports': assigned_ports  # Assign the three consecutive ports
        }
    }
    patch_sparknotebook_status(CustomObjectsApi(), name, namespace, patch_body)

    # Fetch the template for ConfigMap
    template_configmap = get_template_configmap()

    # Create the new ConfigMap based on the template
    create_config_map(name, namespace, template_configmap)

    kopf.info(f"Assigned ID {next_id} and ports {assigned_ports} to SparkNotebook {name} in namespace {namespace}", reason="Created")

@kopf.on.delete(CRD_GROUP, CRD_VERSION, CRD_PLURAL)
def delete_fn(spec, name, namespace, **kwargs):
    """Handle the deletion of a SparkNotebook and delete associated ConfigMap."""
    
    deleted_id = spec.get('id')
    
    # Log the deletion
    kopf.info(f"SparkNotebook {name} in namespace {namespace} deleted with ID {deleted_id}.", reason="Deleted")

    # Delete the associated ConfigMap
    delete_config_map(name, namespace)
