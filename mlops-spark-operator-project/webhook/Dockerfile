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
