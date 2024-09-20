FROM python:3.12-slim

# Install necessary dependencies
RUN pip install kopf==1.37.2 kubernetes==30.1.0

# Copy the operator code into the container
COPY operator/operator.py /operator.py

# Run the operator
CMD ["kopf", "run", "/operator.py"]
