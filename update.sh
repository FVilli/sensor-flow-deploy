#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_MANIFEST_URL="https://raw.githubusercontent.com/FVilli/sensor-flow-deploy/main/stable.json"
readonly install_root="${SENSOR_FLOW_ROOT:-$PWD}"
readonly manifest_url="${SENSOR_FLOW_MANIFEST_URL:-$DEFAULT_MANIFEST_URL}"
readonly state_root="${install_root}/.sensor-flow"
readonly applied_manifest="${state_root}/applied.json"
readonly override_file="${install_root}/compose.release.yaml"
readonly lock_file="${state_root}/update.lock"
readonly expected_services=(
  rabbitmq
  config-manager
  queue-manager
  mqtt-ingress-relay
  raw-writer
  db-writer
)

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command in curl docker flock install jq sha256sum; do
  require_command "$command"
done

[[ "$manifest_url" == https://* ]] || {
  echo "SENSOR_FLOW_MANIFEST_URL must use HTTPS" >&2
  exit 1
}
[[ -f "${install_root}/compose.yaml" ]] || {
  echo "Missing ${install_root}/compose.yaml" >&2
  exit 1
}
[[ -f "${install_root}/volumes/config/env.json" ]] || {
  echo "Missing ${install_root}/volumes/config/env.json" >&2
  exit 1
}
jq empty "${install_root}/volumes/config/env.json"

mkdir -p "$state_root"
exec 9>"$lock_file"
if ! flock --nonblock 9; then
  echo "Another Sensor Flow update is already running"
  exit 0
fi

work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
desired_manifest="${work_root}/stable.json"
candidate_override="${work_root}/compose.release.yaml"
candidate_compose="${work_root}/compose.yaml"
candidate_updater="${work_root}/update.sh"

curl \
  --fail \
  --location \
  --silent \
  --show-error \
  --proto '=https' \
  --tlsv1.2 \
  --output "$desired_manifest" \
  "$manifest_url"

jq -e '
  .schemaVersion == 1
  and .channel == "stable"
  and (.revision | type == "number" and . >= 1)
  and (.gitCommit | test("^[0-9a-f]{40}$"))
  and (.deployment.compose.url | startswith("https://"))
  and (.deployment.compose.sha256 | test("^[0-9a-f]{64}$"))
  and (.deployment.updater.url | startswith("https://"))
  and (.deployment.updater.sha256 | test("^[0-9a-f]{64}$"))
  and (.services | type == "object")
' "$desired_manifest" >/dev/null

for service in "${expected_services[@]}"; do
  jq -e \
    --arg service "$service" \
    '.services[$service]
      and (.services[$service].image | type == "string")
      and (.services[$service].digest | test("^sha256:[0-9a-f]{64}$"))' \
    "$desired_manifest" >/dev/null || {
      echo "Invalid or missing service in manifest: ${service}" >&2
      exit 1
    }
done

download_and_verify() {
  local key="$1"
  local destination="$2"
  local url
  local expected_sha
  local actual_sha
  url="$(jq -er --arg key "$key" '.deployment[$key].url' "$desired_manifest")"
  expected_sha="$(jq -er --arg key "$key" '.deployment[$key].sha256' "$desired_manifest")"
  curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --proto '=https' \
    --tlsv1.2 \
    --output "$destination" \
    "$url"
  actual_sha="$(sha256sum "$destination" | cut -d ' ' -f 1)"
  [[ "$actual_sha" == "$expected_sha" ]] || {
    echo "Checksum mismatch for deployment asset ${key}" >&2
    exit 1
  }
}

download_and_verify compose "$candidate_compose"
download_and_verify updater "$candidate_updater"

desired_revision="$(jq -r '.revision' "$desired_manifest")"
if [[ -f "$applied_manifest" ]]; then
  applied_revision="$(jq -er '.revision' "$applied_manifest")"
  if (( desired_revision == applied_revision )); then
    echo "Sensor Flow revision ${desired_revision} already applied"
    exit 0
  fi
  if (( desired_revision < applied_revision )); then
    echo "Ignoring stale stable revision ${desired_revision}; applied revision is ${applied_revision}" >&2
    exit 0
  fi
fi

{
  echo "services:"
  for service in "${expected_services[@]}"; do
    image="$(jq -r --arg service "$service" '.services[$service].image' "$desired_manifest")"
    digest="$(jq -r --arg service "$service" '.services[$service].digest' "$desired_manifest")"
    printf '  %s:\n    image: %s@%s\n' "$service" "$image" "$digest"
  done
} > "$candidate_override"

changed=()
compose_changed=false
updater_changed=false
desired_compose_sha="$(jq -r '.deployment.compose.sha256' "$desired_manifest")"
desired_updater_sha="$(jq -r '.deployment.updater.sha256' "$desired_manifest")"
current_compose_sha="$(sha256sum "${install_root}/compose.yaml" | cut -d ' ' -f 1)"
current_updater_sha="$(sha256sum "${BASH_SOURCE[0]}" | cut -d ' ' -f 1)"
[[ "$desired_compose_sha" != "$current_compose_sha" ]] && compose_changed=true
[[ "$desired_updater_sha" != "$current_updater_sha" ]] && updater_changed=true

for service in "${expected_services[@]}"; do
  desired_ref="$(
    jq -r --arg service "$service" \
      '.services[$service] | "\(.image)@\(.digest)"' \
      "$desired_manifest"
  )"
  applied_ref=""
  if [[ -f "$applied_manifest" ]]; then
    applied_ref="$(
      jq -r --arg service "$service" \
        '.services[$service] // empty | "\(.image)@\(.digest)"' \
        "$applied_manifest"
    )"
  fi
  [[ "$desired_ref" != "$applied_ref" ]] && changed+=("$service")
done

if [[ "$compose_changed" == true ]]; then
  changed=("${expected_services[@]}")
fi

install_state() {
  if [[ "$updater_changed" == true ]]; then
    install -m 755 "$candidate_updater" "${install_root}/scripts/.update.sh.new"
    mv "${install_root}/scripts/.update.sh.new" "${install_root}/scripts/update.sh"
  fi
  cp "$desired_manifest" "${state_root}/.applied.json.new"
  mv "${state_root}/.applied.json.new" "$applied_manifest"
}

if [[ ${#changed[@]} -eq 0 ]]; then
  install_state
  echo "Recorded Sensor Flow revision ${desired_revision}; image set unchanged"
  exit 0
fi

compose_candidate=(
  docker compose
  -f "$candidate_compose"
  -f "$candidate_override"
)

echo "Pulling changed services: ${changed[*]}"
"${compose_candidate[@]}" pull "${changed[@]}"

rollback_override="${work_root}/previous-compose.release.yaml"
rollback_manifest="${work_root}/previous-applied.json"
rollback_compose="${work_root}/previous-compose.yaml"
had_previous=false
if [[ -f "$override_file" && -f "$applied_manifest" ]]; then
  had_previous=true
  cp "$override_file" "$rollback_override"
  cp "$applied_manifest" "$rollback_manifest"
  cp "${install_root}/compose.yaml" "$rollback_compose"
fi

cp "$candidate_compose" "${install_root}/.compose.yaml.new"
mv "${install_root}/.compose.yaml.new" "${install_root}/compose.yaml"
cp "$candidate_override" "${install_root}/.compose.release.yaml.new"
mv "${install_root}/.compose.release.yaml.new" "$override_file"
compose=(
  docker compose
  -f "${install_root}/compose.yaml"
  -f "$override_file"
)

echo "Applying Sensor Flow revision ${desired_revision}: ${changed[*]}"
if [[ "$had_previous" == false ]]; then
  apply_command=("${compose[@]}" up -d --no-build --remove-orphans --wait --wait-timeout 120)
else
  apply_command=("${compose[@]}" up -d --no-build --no-deps --wait --wait-timeout 120 "${changed[@]}")
fi

if "${apply_command[@]}"; then
  install_state
  echo "Sensor Flow revision ${desired_revision} applied successfully"
  exit 0
fi

echo "Update failed" >&2
if [[ "$had_previous" == false ]]; then
  echo "No previous deployment is available for rollback" >&2
  exit 1
fi

cp "$rollback_override" "$override_file"
cp "$rollback_manifest" "$applied_manifest"
cp "$rollback_compose" "${install_root}/compose.yaml"
docker compose \
  -f "${install_root}/compose.yaml" \
  -f "$override_file" \
  up -d --no-build --no-deps --wait --wait-timeout 120 \
  "${changed[@]}"
echo "Previous service digests restored" >&2
exit 1
