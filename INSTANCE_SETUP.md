# Setup di una nuova istanza Sensor Flow

Questa guida installa Sensor Flow senza clonare il repository e senza credenziali
GitHub persistenti. Le immagini e il manifest del canale `stable` sono pubblici.

L'esempio assume Ubuntu Server 24.04 LTS, utente `federico` e installazione in:

```text
/home/federico/sensor-flow
```

## 1. Prerequisiti

L'istanza deve raggiungere in uscita:

| Destinazione | Porta | Utilizzo |
|---|---:|---|
| `raw.githubusercontent.com` | 443/TCP | manifest e script pubblici |
| `ghcr.io` | 443/TCP | immagini pubbliche |
| broker MQTT sorgenti | normalmente 8883/TCP | acquisizione |
| DNS e NTP | secondo infrastruttura | risoluzione e clock |

Installare Docker Engine con Compose e:

```bash
sudo apt update
sudo apt install curl jq acl ca-certificates
sudo usermod -aG docker "$USER"
```

Dopo una nuova sessione verificare:

```bash
docker version
docker compose version
docker run --rm hello-world
timedatectl status
```

Il clock deve essere sincronizzato. L'utente nel gruppo `docker` possiede
privilegi sostanzialmente amministrativi sulla macchina.

## 2. Copiare il bootstrap

Da una macchina che contiene il progetto:

```bash
scp scripts/sensor-flow-bootstrap.sh \
  federico@INSTANCE:/home/federico/sensor-flow-bootstrap.sh
```

Sul server:

```bash
chmod 700 /home/federico/sensor-flow-bootstrap.sh
```

Non servono Git, GitHub CLI, token o `docker login`. Il bootstrap scrive il proprio
log append-only in `/home/federico/sensor-flow-bootstrap.log` con permessi `600`.

## 3. Preparare la configurazione

Copiare la configurazione reale senza mostrarne il contenuto:

```bash
scp volumes/config/env.json \
  federico@INSTANCE:/home/federico/sensor-flow-env.json
```

Sul server:

```bash
chmod 600 /home/federico/sensor-flow-env.json
jq empty /home/federico/sensor-flow-env.json
```

La struttura è:

```json
{
  "topic": "sensor-flow/config/desired/mqtt-ingress-relay",
  "payload": {
    "schemaVersion": 1,
    "brokers": [
      {
        "name": "fvsg",
        "url": "mqtts://mqtt.example.it:8883",
        "login": "mqtt-user",
        "pass": "mqtt-password",
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
```

## 4. Installare

```bash
export SENSOR_FLOW_ENV_FILE=/home/federico/sensor-flow-env.json
/home/federico/sensor-flow-bootstrap.sh
unset SENSOR_FLOW_ENV_FILE
```

Non si passa una versione: viene applicata la revisione corrente di `stable`.
Il bootstrap è idempotente e:

- verifica i checksum degli asset pubblici;
- installa Compose e updater;
- installa `env.json` senza sovrascriverlo se identico;
- scarica le immagini indicate per digest;
- avvia lo stack;
- abilita `sensor-flow-update.timer`.

Per mantenere il timer utente attivo anche dopo il logout:

```bash
sudo loginctl enable-linger federico
```

## 5. Verificare

```bash
cd /home/federico/sensor-flow
docker compose -f compose.yaml -f compose.release.yaml ps
systemctl --user status sensor-flow-update.timer
systemctl --user list-timers sensor-flow-update.timer
jq '{revision, gitCommit}' .sensor-flow/applied.json
```

RabbitMQ, PostgreSQL, Grafana e `node-api` devono risultare `healthy`; gli altri
servizi `running`.

Il primo avvio genera `volumes/config/node-api.token` con permessi `600`. È un
segreto bootstrap da includere nel backup protetto e da non stampare nei log.

Log e code:

```bash
docker compose -f compose.yaml -f compose.release.yaml logs \
  config-manager queue-manager mqtt-ingress-relay raw-writer db-writer

docker compose -f compose.yaml -f compose.release.yaml exec rabbitmq \
  rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
```

Con i writer attivi, le code devono normalmente tornare a zero.

Grafana è esposto soltanto su localhost. Da una workstation aprire un tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 federico@server
```

Aprire quindi `http://localhost:3000` e usare le credenziali iniziali M2A
`admin` / `sensor_flow_admin_dev`. Autenticazione e utenze cliente verranno
introdotte nella milestone successiva.

## 6. Verificare i dati

```bash
find volumes/raw -type f | sort | tail

docker compose -f compose.yaml -f compose.release.yaml exec postgres \
  psql -U sensor_flow -d sensor_flow \
  -c "SELECT source, sid, s_type, processed_through, observed_minute FROM sensors;"
```

Per il broker `fvsg`, la root RAW è `volumes/raw/fvsg/...` e la sorgente database è
`mqtt:fvsg`.

## 7. Aggiornamenti automatici

Ogni minuto il timer confronta `stable.json` con `.sensor-flow/applied.json`. Se è
cambiato soltanto `db-writer`, scarica e riconcilia soltanto `db-writer`.

Controllo manuale:

```bash
SENSOR_FLOW_ROOT=/home/federico/sensor-flow \
  /home/federico/sensor-flow/scripts/update.sh

journalctl --user -u sensor-flow-update.service
```

Non occorrono token, tag o interventi manuali.

## 8. Dati da proteggere

Eseguire backup coerenti di:

```text
volumes/config/
volumes/raw/
volume Docker PostgreSQL
volume Docker RabbitMQ
volume Docker Grafana
```

Un aggiornamento ordinario non deve eliminare queste risorse.

## 9. Checklist

- [ ] Docker Engine e Compose disponibili.
- [ ] Clock sincronizzato.
- [ ] Nessun clone e nessuna credenziale GitHub sull'istanza.
- [ ] Bootstrap protetto con permessi `700`.
- [ ] `env.json` valido e protetto con permessi `600`.
- [ ] `node-api.token` presente e protetto con permessi `600`.
- [ ] `stable.json` raggiungibile senza autenticazione.
- [ ] Immagini GHCR scaricabili senza login.
- [ ] Stack sano e primo dato acquisito.
- [ ] Timer abilitato e lingering attivo.
- [ ] Aggiornamento selettivo verificato.
