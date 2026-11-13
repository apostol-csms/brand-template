"""Print the OpenAPI document of the service: SERVICE_KEY=x python -m app.openapi > openapi.json"""
import json

from app.main import api

print(json.dumps(api.openapi(), indent=2, sort_keys=True, ensure_ascii=False))
