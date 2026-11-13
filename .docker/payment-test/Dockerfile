# Base images come from Docker Hub by default. Passing
# --build-arg REGISTRY=<host>/base redirects the FROM below to a mirror.
ARG REGISTRY=docker.io/library

FROM ${REGISTRY}/python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --system --no-create-home app

COPY app/ app/

USER app

EXPOSE 8000

# HOST/PORT come from outside. On a private container network the service
# listens on 0.0.0.0; it is never published to the outside world.
# SERVICE_KEY is required: the service refuses to start without it.
# NOTIFY_URL is the base address notifications are posted to.
ENV HOST=0.0.0.0 PORT=8000

CMD ["sh", "-c", "exec uvicorn app.main:app --host \"$HOST\" --port \"$PORT\""]
