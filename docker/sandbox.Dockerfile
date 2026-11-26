# Image for the build stage's sandbox (see Invoke-Sandbox in scripts/lib.ps1).
# Python 3.12, Node.js/npm and gcc/g++/make, running as the unprivileged user 1000.
# Built automatically on first use; rebuild after editing: docker build -t autobuilder-sandbox:1 -f docker/sandbox.Dockerfile docker
FROM python:3.12-slim-bookworm
RUN apt-get update \
    && apt-get install -y --no-install-recommends nodejs npm build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 1000 --create-home builder
USER 1000:1000
WORKDIR /work
