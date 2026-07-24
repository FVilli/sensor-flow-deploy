#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_INSTALL_ROOT="${HOME}/sensor-flow"
readonly DEFAULT_DEPLOYMENT_BASE_URL="https://raw.githubusercontent.com/FVilli/sensor-flow-deploy/main"
readonly script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly log_file="${script_root}/sensor-flow-bootstrap.log"

touch "$log_file"
chmod 600 "$log_file"
exec > >(tee -a "$log_file") 2>&1

echo
echo "[$(date --iso-8601=seconds)] Sensor Flow bootstrap started"

usage() {
  cat <<'EOF'
Usage: sensor-flow-bootstrap.sh [installation-root]

Environment:
  SENSOR_FLOW_ENV_FILE            Path to the instance env.json
  SENSOR_FLOW_DEPLOYMENT_BASE_URL Public deployment base URL
  SENSOR_FLOW_MANIFEST_URL        Optional stable manifest override

No GitHub token or release version is required.
EOF
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

readonly install_root="${1:-$DEFAULT_INSTALL_ROOT}"
readonly environment_file="${SENSOR_FLOW_ENV_FILE:?Missing SENSOR_FLOW_ENV_FILE}"
readonly deployment_base_url="${SENSOR_FLOW_DEPLOYMENT_BASE_URL:-$DEFAULT_DEPLOYMENT_BASE_URL}"

[[ "$install_root" != *[$'\n\r\t ']* ]] || {
  echo "Installation root cannot contain whitespace" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for command in awk cmp curl docker jq sha256sum systemctl tee; do
  require_command "$command"
done

[[ "$deployment_base_url" == https://* ]] || {
  echo "SENSOR_FLOW_DEPLOYMENT_BASE_URL must use HTTPS" >&2
  exit 1
}
[[ -f "$environment_file" ]] || {
  echo "Configuration file not found: ${environment_file}" >&2
  exit 1
}
jq empty "$environment_file"
docker compose version >/dev/null

mkdir -p "$install_root"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT

download() {
  local name="$1"
  curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --proto '=https' \
    --tlsv1.2 \
    --output "${work_root}/${name}" \
    "${deployment_base_url}/${name}"
}

download SHA256SUMS
download compose.yaml
download update.sh

for asset in compose.yaml update.sh; do
  expected_sha="$(awk -v asset="$asset" '$2 == asset { print $1 }' "${work_root}/SHA256SUMS")"
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || {
    echo "SHA256SUMS does not contain ${asset}" >&2
    exit 1
  }
  actual_sha="$(sha256sum "${work_root}/${asset}" | cut -d ' ' -f 1)"
  [[ "$actual_sha" == "$expected_sha" ]] || {
    echo "${asset} checksum mismatch" >&2
    exit 1
  }
done

mkdir -p \
  "${install_root}/scripts" \
  "${install_root}/volumes/config" \
  "${install_root}/volumes/raw"

installed_environment="${install_root}/volumes/config/env.json"
if [[ ! -f "$installed_environment" ]] || ! cmp --silent "$environment_file" "$installed_environment"; then
  environment_staging="${install_root}/volumes/config/.env.json.bootstrap"
  cp "$environment_file" "$environment_staging"
  chmod 600 "$environment_staging"
  mv "$environment_staging" "$installed_environment"
  echo "Installed configuration ${installed_environment}"
else
  echo "Configuration already up to date"
fi

if [[ "$(id -u)" -ne 1000 ]]; then
  require_command setfacl
  setfacl -m u:1000:rwx "${install_root}/volumes/config" "${install_root}/volumes/raw"
  setfacl -m u:1000:r "$installed_environment"
fi

install -m 644 "${work_root}/compose.yaml" "${install_root}/compose.yaml"
install -m 755 "${work_root}/update.sh" "${install_root}/scripts/update.sh"

echo "Installing current stable revision in ${install_root}"
SENSOR_FLOW_ROOT="$install_root" \
  "${install_root}/scripts/update.sh"

user_systemd_root="${HOME}/.config/systemd/user"
mkdir -p "$user_systemd_root"
escaped_root="$(printf '%q' "$install_root")"
cat > "${user_systemd_root}/sensor-flow-update.service" <<EOF
[Unit]
Description=Reconcile Sensor Flow stable deployment
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=SENSOR_FLOW_ROOT=${escaped_root}
ExecStart=${install_root}/scripts/update.sh
EOF

cat > "${user_systemd_root}/sensor-flow-update.timer" <<'EOF'
[Unit]
Description=Check Sensor Flow stable deployment

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
RandomizedDelaySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now sensor-flow-update.timer

echo "[$(date --iso-8601=seconds)] Sensor Flow bootstrap completed"
echo "Automatic updates require user lingering after logout:"
echo "  sudo loginctl enable-linger ${USER}"
