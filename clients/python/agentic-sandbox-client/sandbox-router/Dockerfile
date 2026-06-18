# Use the official Python image from the Docker Hub as the base image.
FROM python:3.14-slim

WORKDIR /app

# Installation of dependencies for sandbox router.
COPY requirements.txt .

RUN pip install --no-cache-dir --require-hashes -r requirements.txt

COPY sandbox_router.py .

# OpenShift runs containers as an arbitrary UID from the namespace range with GID 0.
RUN chown -R 1001:0 /app && \
    chmod -R g+rwX /app
USER 1001

# Expose the port that the Uvicorn server will run on.
# This must match the port in the CMD instruction below.
EXPOSE 8080

# Use Uvicorn as a production-ready web server to run the Flask app
CMD ["uvicorn", "sandbox_router:app", "--host", "0.0.0.0", "--port", "8080"]
