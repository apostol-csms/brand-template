FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tests

COPY tests/requirements.txt /tests/requirements.txt
RUN pip install --no-cache-dir -r /tests/requirements.txt

# Tests source mounted at /tests via compose volume

ENTRYPOINT ["python", "-m", "pytest"]
CMD ["--tb=line"]
