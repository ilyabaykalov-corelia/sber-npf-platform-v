#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${PROJECT_ROOT}/.." && pwd)"

load_env_file() {
  local env_file="$1"
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
}

load_env_file "${WORKSPACE_ROOT}/sber-npf-bff-nodejs/.env"
load_env_file "${PROJECT_ROOT}/.env"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: scripts/seed-dictionaries.sh [dataspace-graphql-url]

Seeds DataSpace dictionaries through the DataSpace GraphQL dictionaryPacket.

Arguments:
  dataspace-graphql-url  Full DataSpace GraphQL URL ending with /model/graphql.
                         If omitted, PLATFORM_V_DATASPACE_GRAPHQL_URL or
                         DATASPACE_GRAPHQL_URL is used.

Environment:
  PLATFORM_V_ACCESS_TOKEN       Optional ready bearer token for Platform V/DataSpace.
  ACCESS_TOKEN                  Fallback ready bearer token variable.
  PLATFORM_V_USERNAME           Username for automatic Keycloak login.
  PLATFORM_V_PASSWORD           Password for automatic Keycloak login.
  PLATFORM_V_KEYCLOAK_TOKEN_URL Keycloak token endpoint. Can be derived from
                                PLATFORM_V_KEYCLOAK_BASE_URL.
  PLATFORM_V_KEYCLOAK_BASE_URL  Keycloak realm URL.
  PLATFORM_V_KEYCLOAK_CLIENT_ID Keycloak client ID. Defaults to PlatformAuth-Proxy.
  PLATFORM_V_KEYCLOAK_SCOPE     Token scope. Defaults to openid profile email roles.
  DRY_RUN=true                  Print the GraphQL payload without sending it.

Example:
  PLATFORM_V_USERNAME=tester PLATFORM_V_PASSWORD=secret \
    scripts/seed-dictionaries.sh \
    https://element.aplana-it.ru/platformv/api/ds/lcp_uva1/models/<modelId>/model/graphql
USAGE
  exit 0
fi

GRAPHQL_URL="${1:-${PLATFORM_V_DATASPACE_GRAPHQL_URL:-${DATASPACE_GRAPHQL_URL:-}}}"
ACCESS_TOKEN_VALUE="${PLATFORM_V_ACCESS_TOKEN:-${ACCESS_TOKEN:-}}"
KEYCLOAK_CLIENT_ID="${PLATFORM_V_KEYCLOAK_CLIENT_ID:-PlatformAuth-Proxy}"
KEYCLOAK_SCOPE="${PLATFORM_V_KEYCLOAK_SCOPE:-openid profile email roles}"

PLATFORM_V_USERNAME=tester
PLATFORM_V_PASSWORD=PlatformVAdmin123!

if [[ -z "${PLATFORM_V_KEYCLOAK_TOKEN_URL:-}" && -n "${PLATFORM_V_KEYCLOAK_BASE_URL:-}" ]]; then
  PLATFORM_V_KEYCLOAK_TOKEN_URL="${PLATFORM_V_KEYCLOAK_BASE_URL%/}/protocol/openid-connect/token"
fi

if [[ -z "${GRAPHQL_URL}" ]]; then
  echo "Missing DataSpace GraphQL URL. Pass it as an argument or set PLATFORM_V_DATASPACE_GRAPHQL_URL." >&2
  exit 1
fi

if [[ "${GRAPHQL_URL}" != */model/graphql ]]; then
  echo "DataSpace GraphQL URL must end with /model/graphql: ${GRAPHQL_URL}" >&2
  exit 1
fi

PAYLOAD_DIR="$(mktemp -d)"
RESPONSE_FILE="$(mktemp)"
TOKEN_RESPONSE_FILE="$(mktemp)"

cleanup() {
  rm -rf "${PAYLOAD_DIR}"
  rm -f "${RESPONSE_FILE}" "${TOKEN_RESPONSE_FILE}"
}
trap cleanup EXIT

python3 - "${PROJECT_ROOT}" "${PAYLOAD_DIR}" <<'PY'
import json
import sys
from pathlib import Path

project_root = Path(sys.argv[1])
payload_dir = Path(sys.argv[2])
dictionary_dir = project_root / "dictionary"

with (dictionary_dir / "DocumentType.json").open("r", encoding="utf-8") as source:
    document_type = json.load(source)["objects"][0]

with (dictionary_dir / "DocumentProcessSettings.json").open("r", encoding="utf-8") as source:
    process_settings = json.load(source)["objects"][0]

document_type_payload = {
    "operationName": "upsertDocumentType",
    "query": "mutation upsertDocumentType($id: ID!, $name: String) { dictionaryPacket { updateOrCreateDocumentType(input: { id: $id, name: $name }) { created returning { id name } } } }",
    "variables": {
        "id": document_type["id"],
        "name": document_type.get("name"),
    },
}

process_settings_payload = {
    "operationName": "upsertDocumentProcessSettings",
    "query": "mutation upsertDocumentProcessSettings($id: ID!, $documentType: ID!, $processId: String, $enabled: Boolean) { dictionaryPacket { updateOrCreateDocumentProcessSettings(input: { id: $id, documentType: $documentType, processId: $processId, enabled: $enabled }) { created returning { id documentType { id name } processId enabled } } } }",
    "variables": {
        "id": process_settings["id"],
        "documentType": document_type["id"],
        "processId": process_settings.get("processId"),
        "enabled": process_settings.get("enabled", True),
    },
}

with (payload_dir / "01-upsert-document-type.json").open("w", encoding="utf-8") as target:
    json.dump(document_type_payload, target, ensure_ascii=False)

with (payload_dir / "02-upsert-document-process-settings.json").open("w", encoding="utf-8") as target:
    json.dump(process_settings_payload, target, ensure_ascii=False)
PY

if [[ "${DRY_RUN:-}" == "true" ]]; then
  for payload_file in "${PAYLOAD_DIR}"/*.json; do
    cat "${payload_file}"
    echo
  done
  exit 0
fi

if [[ -z "${ACCESS_TOKEN_VALUE}" ]]; then
  if [[ -z "${PLATFORM_V_USERNAME:-}" || -z "${PLATFORM_V_PASSWORD:-}" || -z "${PLATFORM_V_KEYCLOAK_TOKEN_URL:-}" ]]; then
    echo "Missing auth. Set PLATFORM_V_ACCESS_TOKEN or configure PLATFORM_V_USERNAME, PLATFORM_V_PASSWORD and PLATFORM_V_KEYCLOAK_TOKEN_URL/PLATFORM_V_KEYCLOAK_BASE_URL." >&2
    exit 1
  fi

  token_request_args=(
    --request POST
    --header "Accept: application/json"
    --header "Content-Type: application/x-www-form-urlencoded"
    --data-urlencode "client_id=${KEYCLOAK_CLIENT_ID}"
    --data-urlencode "grant_type=password"
    --data-urlencode "username=${PLATFORM_V_USERNAME}"
    --data-urlencode "password=${PLATFORM_V_PASSWORD}"
    --data-urlencode "scope=${KEYCLOAK_SCOPE}"
  )

  if [[ -n "${PLATFORM_V_KEYCLOAK_CLIENT_SECRET:-}" ]]; then
    token_request_args+=(--data-urlencode "client_secret=${PLATFORM_V_KEYCLOAK_CLIENT_SECRET}")
  fi

  curl --fail-with-body --silent --show-error \
    "${token_request_args[@]}" \
    "${PLATFORM_V_KEYCLOAK_TOKEN_URL}" \
    > "${TOKEN_RESPONSE_FILE}"

  ACCESS_TOKEN_VALUE="$(python3 - "${TOKEN_RESPONSE_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    response = json.load(source)

token = response.get("access_token")
if not token:
    raise SystemExit("Keycloak response does not contain access_token")

print(token)
PY
)"
fi

if [[ -z "${ACCESS_TOKEN_VALUE}" ]]; then
  echo "Missing bearer token." >&2
  exit 1
fi

for payload_file in "${PAYLOAD_DIR}"/*.json; do
  curl --fail-with-body --silent --show-error \
    --request POST \
    --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${ACCESS_TOKEN_VALUE}" \
    --data @"${payload_file}" \
    "${GRAPHQL_URL}" \
    > "${RESPONSE_FILE}"

  python3 - "${RESPONSE_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    response = json.load(source)

print(json.dumps(response, ensure_ascii=False, indent=2))

if response.get("errors"):
    raise SystemExit(1)
PY
done
echo
