# Setup di una nuova istanza Sensor Flow

## TL;DR

- `prepare.sh` prepara l'istanza: crea le directory sotto
  `$HOME/sensor-flow` e, se manca, scrive un modello di `env.json` da compilare.
- Si compila `env.json` con i dati reali del broker MQTT.
- `bootstrap.sh` installa e avvia davvero lo stack, leggendo quel
  `env.json`.
- Risultato: un'istanza funzionante interamente contenuta in
  `$HOME/sensor-flow/` (configurazione, RAW, log di bootstrap, doc operative) —
  nessun file di sensor-flow sparso altrove sul server, a parte l'unità
  systemd utente (`~/.config/systemd/user/`), obbligata dalla sua posizione
  standard.

Questa guida installa Sensor Flow senza clonare il repository e senza credenziali
GitHub persistenti. Le immagini e il manifest del canale `stable` sono pubblici.

Gli esempi usano `$USER` e `$HOME` dell'utente che esegue l'installazione;
l'installazione finisce in `$HOME/sensor-flow`.

## 1. Prerequisiti

- l'istanza deve raggiungere in uscita `raw.githubusercontent.com:443`,
  `ghcr.io:443` e il broker MQTT sorgente (normalmente `8883/TCP`);
- Docker Engine e il plugin Compose installati, utente nel gruppo `docker`;
- clock sincronizzato (NTP).

Se Docker non è già installato, vedere l'appendice
[Docker](#appendice-installare-docker). Avahi è opzionale e utile soltanto per
istanze raggiungibili direttamente sulla rete locale.

## 2. Preparazione

Non serve avere il repository sorgente in locale. Sull'istanza:

```bash
curl -fsSL https://raw.githubusercontent.com/FVilli/sensor-flow-deploy/main/prepare.sh \
  | bash -s -- "$HOME/sensor-flow"
```

Lo script è idempotente e:

- crea le directory richieste sotto `$HOME/sensor-flow`;
- se `volumes/config/env.json` non esiste, scrive un modello con i campi da
  compilare (`CHANGE_ME`) e stampa il percorso esatto da modificare;
- se `volumes/config/env.json` esiste già, lo lascia invariato e ne verifica
  solo la validità JSON.

Modificare quindi `$HOME/sensor-flow/volumes/config/env.json` con le credenziali
reali del broker MQTT. La struttura è:

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

Verificare il JSON e i permessi dopo la modifica:

```bash
chmod 600 "$HOME/sensor-flow/volumes/config/env.json"
jq empty "$HOME/sensor-flow/volumes/config/env.json"
```

## 3. Installare

```bash
curl -fsSL https://raw.githubusercontent.com/FVilli/sensor-flow-deploy/main/bootstrap.sh \
  | SENSOR_FLOW_ENV_FILE="$HOME/sensor-flow/volumes/config/env.json" bash -s -- "$HOME/sensor-flow"
```

Il secondo argomento posizionale dopo `--` è la directory di installazione; se
omesso viene usato `~/sensor-flow`. Non servono Git, GitHub CLI, token o
`docker login`, né salvare lo script su disco: viene eseguito direttamente dallo
stream `curl`. Usare `bash`, non `sh`: lo script richiede sintassi Bash. Il
bootstrap scrive il proprio log append-only in
`$HOME/sensor-flow/sensor-flow-bootstrap.log` con permessi `600`.

Non si passa una versione: viene applicata la revisione corrente di `stable`.
Il bootstrap è idempotente e:

- verifica i checksum degli asset pubblici;
- installa Compose e updater;
- installa `env.json` senza sovrascriverlo se identico (già il caso, dato che
  punta allo stesso file preparato al passo precedente);
- scarica le immagini `stable` e verifica la revisione tramite i digest del manifest;
- avvia lo stack;
- abilita `sensor-flow-update.timer`.

Per mantenere il timer utente attivo anche dopo il logout:

```bash
sudo loginctl enable-linger "$USER"
```

## 4. Verificare

```bash
cd "$HOME/sensor-flow"
docker compose -f compose.yaml ps
systemctl --user status sensor-flow-update.timer
systemctl --user list-timers sensor-flow-update.timer
jq '{revision, gitCommit}' .sensor-flow/applied.json
```

RabbitMQ, PostgreSQL e Grafana devono risultare `healthy`; gli altri servizi
`running` (`db-writer-migrate` termina con successo ed esce, non resta
`running`: è un passo one-shot che precede `db-writer`).

Log e code:

```bash
docker compose -f compose.yaml logs \
  config-manager queue-manager mqtt-ingress-relay raw-writer db-writer

docker compose -f compose.yaml exec rabbitmq \
  rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
```

Con i writer attivi, le code devono normalmente tornare a zero.

Lo stato `healthy` certifica il lifecycle del processo, non da solo l'avanzamento
dei dati. Verificare anche che `db-writer` veda il bind mount RAW canonico e abbia
scoperto almeno uno stream quando sono già presenti manifest `_stream.json`:

```bash
docker compose -f compose.yaml exec db-writer \
  test -r /app/volumes/raw

find volumes/raw -name _stream.json -print

docker compose -f compose.yaml exec postgres \
  psql -U sensor_flow -d sensor_flow \
  -c "SELECT stream_key, classification_status, last_ingress_ts, last_processed_ts FROM raw_streams;"
```

Un manifest presente sul filesystem con `raw_streams` vuota indica che il
verticale non è operativo, anche se il container risulta healthy. Controllare in
tal caso mount, log e backlog prima di proseguire.

Grafana ascolta soltanto sul loopback dell'istanza. Da una workstation aprire un
tunnel SSH:

```bash
ssh -L 3000:127.0.0.1:3000 utente@istanza
```

Aprire quindi `http://localhost:3000` e usare le credenziali iniziali M2A
`admin` / `sensor_flow_admin_dev`. Autenticazione e utenze cliente verranno
introdotte nella milestone successiva. Un'esposizione tramite reverse proxy deve
essere configurata esplicitamente con TLS e autenticazione adeguata.

Una guida opzionale descrive come
[usare Traefik per esporre selettivamente i servizi](guides/traefik-service-exposure.md).
Traefik e la relativa configurazione restano posseduti dall'host e non vengono
applicati dall'updater Sensor Flow.

`node-api` oggi non fa parte dello stack installato da questa guida. Quando verrà
abilitato, possiederà le proprie migrazioni e genererà al primo avvio il token
bootstrap in `volumes/config/node-api.token`; il token non appartiene a
`env.json`. La web app di amministrazione basata su `admin-api` arriverà in un
secondo momento.

Fino alla versione maggiore 1, PostgreSQL è esposto soltanto sul loopback
dell'istanza come supporto a debug e operatività iniziale:

```text
127.0.0.1:5433 -> postgres:5432
```

Da una workstation usare un tunnel dedicato:

```bash
ssh -L 5433:127.0.0.1:5433 utente@istanza
```

Poi configurare lo strumento SQL con host `localhost`, porta `5433`, database
`sensor_flow`, utente `sensor_flow` e password di sviluppo `sensor_flow_dev`.

## 5. Verificare i dati

```bash
find volumes/raw -type f | sort | tail

docker compose -f compose.yaml exec postgres \
  psql -U sensor_flow -d sensor_flow \
  -c "SELECT source, sid, s_type, processed_through, observed_minute FROM sensors;"
```

Per il broker `fvsg`, la root RAW è `volumes/raw/mqtt/fvsg/...` e la sorgente
database è `mqtt:fvsg`.

## 6. Aggiornamenti automatici

Ogni minuto il timer confronta `stable.json` con `.sensor-flow/applied.json`. Se è
cambiato soltanto `db-writer`, scarica e riconcilia soltanto `db-writer`.

Controllo manuale:

```bash
SENSOR_FLOW_ROOT="$HOME/sensor-flow" \
  "$HOME/sensor-flow/scripts/update.sh"

journalctl --user -u sensor-flow-update.service
```

Non occorrono token, tag o interventi manuali.

Per verificare un aggiornamento selettivo, registrare prima gli ID dei container,
eseguire il controllo manuale sopra e confrontarli dopo l'applicazione:

```bash
docker compose -f compose.yaml ps -q
```

Una modifica del solo Compose non scarica nuove immagini. Compose riconcilia lo
stack e ricrea soltanto i servizi la cui configurazione effettiva è cambiata; gli
ID degli altri container devono restare invariati.

Le installazioni aggiornate da una revisione precedente possono conservare un file
legacy `compose.release.yaml`: l'updater lo ignora e l'operatore può eliminarlo
manualmente dopo avere verificato che tutti i comandi usino il solo `compose.yaml`.

## 7. Dati da proteggere

Eseguire backup coerenti di:

```text
volumes/config/
volumes/raw/
volume Docker PostgreSQL
volume Docker RabbitMQ
volume Docker Grafana
```

Un aggiornamento ordinario non deve eliminare queste risorse.

## 8. Checklist

- [ ] Docker Engine e Compose disponibili.
- [ ] Clock sincronizzato.
- [ ] Nessun clone e nessuna credenziale GitHub sull'istanza.
- [ ] `env.json` preparato, modificato con le credenziali reali e protetto con
      permessi `600`.
- [ ] `stable.json` raggiungibile senza autenticazione.
- [ ] Immagini GHCR scaricabili senza login.
- [ ] Stack sano e primo dato acquisito.
- [ ] Timer abilitato e lingering attivo.
- [ ] Aggiornamento selettivo verificato.

## Appendice: installare Docker

Eseguire:

```bash
sudo apt update
sudo apt install -y ca-certificates curl jq acl
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

Aprire una nuova sessione (l'appartenenza al gruppo `docker` non si applica
altrimenti; equivale a privilegi root sulla macchina), poi eseguire:

```bash
docker run --rm hello-world
docker compose version
timedatectl show -p NTPSynchronized
```

Deve restituire:

```text
Hello from Docker!
(seguito dal messaggio esplicativo del container hello-world)

Docker Compose version v2.x.x

NTPSynchronized=yes
```

Se `NTPSynchronized=no`, sincronizzare il clock prima di proseguire (es.
`sudo timedatectl set-ntp true`).

## Appendice: installare Avahi

Eseguire:

```bash
sudo apt update
sudo apt install -y avahi-daemon libnss-mdns
sudo systemctl enable --now avahi-daemon
```

Verificare, dalla stessa istanza:

```bash
systemctl is-active avahi-daemon
ping -c 1 "$(hostname).local"
```

Deve restituire:

```text
active

PING nomepc.local (192.168.x.x) 56(84) bytes of data.
64 bytes from nomepc.local (192.168.x.x): icmp_seq=1 ttl=64 time=0.05 ms
```

Se il `ping` fallisce da un'altra macchina della stessa rete, verificare che
anche quella macchina supporti mDNS (macOS e la maggior parte delle
distribuzioni Linux desktop lo supportano di serie; su Windows serve Bonjour o
un client mDNS) e che non ci sia un firewall/isolamento client tra i
dispositivi (es. AP wifi con "client isolation" attiva).
