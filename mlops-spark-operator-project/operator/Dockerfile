# Use a Python 3.12 slim image as base
FROM python:3.12-slim

# Set the working directory inside the container
WORKDIR /app

# Copy the operator code into the container
COPY operator.py /app/
COPY utils.py /app/

# Install necessary Python dependencies
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Run the operator
CMD ["kopf", "run", "operator.py"]
