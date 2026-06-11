# Use the official Python image from the Docker Hub as the base image.
FROM registry.access.redhat.com/ubi9/python-314

USER root

LABEL name="agent-sandbox/agent-sandbox-router"
LABEL com.redhat.component="agent-sandbox-router-container"
LABEL io.k8s.display-name="Agent Sandbox router"
LABEL io.k8s.description="Request router for agent sandbox workloads"
LABEL description="Request router for agent sandbox workloads"
LABEL summary="Request router for agent sandbox workloads"
LABEL maintainer="Red Hat"
LABEL version="0.9.0"
LABEL release="1"
LABEL vendor="Red Hat, Inc."
LABEL url="https://access.redhat.com/"
LABEL distribution-scope=public
LABEL io.openshift.tags=""
LABEL cpe="cpe:/a:redhat:confidential_compute_attestation:1.130::el9"

WORKDIR /app

# Installation of dependencies for sandbox router.
COPY requirements.txt .

RUN pip install --no-cache-dir --require-hashes -r requirements.txt

COPY sandbox_router.py .

# Change ownership of the /app directory to the non-root user 1000.
RUN chown -R 1000:1000 /app
USER 1000

# Expose the port that the Uvicorn server will run on.
# This must match the port in the CMD instruction below.
EXPOSE 8080

# Use Uvicorn as a production-ready web server to run the Starlette app
CMD ["uvicorn", "sandbox_router:app", "--host", "0.0.0.0", "--port", "8080"]
