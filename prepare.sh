#!/usr/bin/env bash

set -Eeuo pipefail

readonly DEFAULT_INSTALL_ROOT="${HOME}/sensor-flow"

usage() {
  cat <<'EOF'
Usage: prepare.sh [installation-root]

Prepara il filesystem locale per una nuova istanza Sensor Flow: crea le
directory richieste e, se assente, un env.json di esempio da modificare prima
di eseguire l'installer. Non richiede il repository sorgente in locale.
EOF
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

readonly install_root="${1:-$DEFAULT_INSTALL_ROOT}"

[[ "$install_root" != *[$'\n\r\t ']* ]] || {
  echo "Installation root cannot contain whitespace" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "Missing required command: jq" >&2
  exit 1
}

mkdir -p \
  "${install_root}/scripts" \
  "${install_root}/volumes/config" \
  "${install_root}/volumes/raw"

environment_file="${install_root}/volumes/config/env.json"

if [[ -f "$environment_file" ]]; then
  jq empty "$environment_file"
  echo "Configurazione già presente: ${environment_file}"
else
  cat > "$environment_file" <<'EOF'
{
  "topic": "sensor-flow/config/desired/mqtt-ingress-relay",
  "payload": {
    "schemaVersion": 1,
    "brokers": [
      {
        "name": "CHANGE_ME",
        "url": "mqtts://CHANGE_ME:8883",
        "login": "CHANGE_ME",
        "pass": "CHANGE_ME",
        "subscriptions": [
          {
            "topic": "shelly/+/events/rpc",
            "dataType": "json"
          }
        ]
      }
    ]
  }
}
EOF
  chmod 600 "$environment_file"
  echo "Creato modello di configurazione: ${environment_file}"
fi

echo
echo "Prima di installare, modifica ${environment_file} sostituendo i valori"
echo "CHANGE_ME con le credenziali reali del broker MQTT (name, url, login,"
echo "pass, subscriptions)."
