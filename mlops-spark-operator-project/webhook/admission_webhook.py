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
