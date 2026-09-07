# Usare Traefik per esporre i servizi di Sensor Flow

## Scopo e confine di responsabilità

Questa guida aiuta il gestore di un host a scegliere quali superfici HTTP di una
istanza Sensor Flow rendere raggiungibili attraverso un Traefik già amministrato
dall'host.

Traefik, DNS, certificati, firewall, autenticazione perimetrale e selezione delle
superfici pubbliche non fanno parte del deployment Sensor Flow. L'operatore agisce
esclusivamente sulla configurazione di Traefik e della sua infrastruttura:

- non modifica `compose.yaml` di Sensor Flow;
- non aggiunge label Traefik ai servizi Sensor Flow;
- non cambia i bind di porta o gli IP dei container Sensor Flow;
- non collega manualmente container con `docker network connect` come soluzione
  permanente;
- non modifica file sotto `.sensor-flow/`.

Se una superficie non è presente nello stack pubblicato o non è raggiungibile dal
Traefik esistente, non spetta all'operatore alterare Sensor Flow per abilitarla. La
superficie dovrà prima essere resa disponibile da una successiva versione del
progetto.

## Superfici dell'istanza

Non tutto ciò che ascolta su una porta è una superficie da pubblicare. La tabella
distingue lo stato della revisione `stable` corrente dall'intento architetturale.

| Superficie | Stato nello stack pubblico | Uso previsto | Esposizione tramite Traefik |
| --- | --- | --- | --- |
| Grafana | Presente; HTTP su `127.0.0.1:3000` e `grafana:3000` nella rete Compose | UI per dashboard e osservazione | Sì, scegliendo esplicitamente di pubblicarla e proteggendola con HTTPS |
| `node-api` | Implementata nel sorgente ma non ancora abilitata nello stack pubblico | API versionata per dati, export e integrazioni | Prevista; non applicare ancora una route sull'istanza pubblica corrente |
| `admin-api` | Implementata nel sorgente ma non ancora abilitata nello stack pubblico | Control plane amministrativo e Swagger iniziale | No, finché autenticazione e perimetro operativo non saranno approvati |
| RabbitMQ Management | Presente su `127.0.0.1:15672` | Diagnosi tecnica locale | No; usare tunnel SSH o rete amministrativa privata |
| RabbitMQ MQTT/AMQP | Presenti sul loopback e nella rete Docker | Bus interno dell'istanza | No; non sono API pubbliche e questa guida non crea router TCP |
| PostgreSQL | Presente su `127.0.0.1:5433` | Debug e operatività locale fino alla major 1 | No; usare tunnel SSH o rete amministrativa privata |
| Worker, probe e agent | Nessuna REST API pubblica | Elaborazione e osservabilità interne | No |
| `mqtt-ingress-relay` | Nessuna porta pubblica in ingresso | Connessioni in uscita verso broker sorgente configurati | No |

La lista va riletta contro la versione installata prima di ogni esposizione. Una
nuova porta non diventa automaticamente pubblicabile: deve essere classificata
nella documentazione architetturale di Sensor Flow.

## Scegliere cosa esporre

Per ogni superficie candidata decidere separatamente:

- pubblico destinatario: Internet, rete aziendale, VPN o soli amministratori;
- nome DNS dedicato, per esempio `grafana.example.com`;
- autenticazione applicativa disponibile;
- eventuale autenticazione aggiuntiva, allowlist o forward-auth posseduta
  dall'host;
- necessità reale: è corretto esporre soltanto un sottoinsieme, oppure nulla.

Usare un sottodominio alla radice per ogni servizio. I path prefix come
`example.com/grafana` richiedono configurazioni applicative quali `root_url` e non
sono coperti dalla procedura corrente.

## Prerequisiti Traefik

Gli esempi assumono:

- un entrypoint HTTPS chiamato `websecure`;
- un certificate resolver ACME chiamato `letsencrypt`, oppure certificati statici
  già gestiti dall'host;
- file provider Traefik abilitato con reload automatico o una procedura nota di
  reload;
- record DNS A e, se usato, AAAA diretti all'host Traefik;
- TCP 80 e 443 aperte soltanto verso Traefik secondo la politica dell'host.

Sostituire nomi, domini e resolver con quelli reali. Un router con
`tls.certResolver` richiede che il resolver sia già definito nella configurazione
statica di Traefik.

## Preparare le superfici selezionate

### Grafana

Grafana è l'unica superficie pubblicabile già presente nello stack `stable`.
Prima di creare la route, accedere tramite tunnel SSH e sostituire la password
amministrativa di sviluppo con una password unica e robusta:

```bash
ssh -L 3000:127.0.0.1:3000 ubuntu@istanza
```

Aprire `http://localhost:3000`, autenticarsi e cambiare la password. Non conservare
la nuova password nei file Traefik o nel repository Sensor Flow.

Verificare sull'istanza:

```bash
cd "$HOME/sensor-flow"

docker compose -f compose.yaml ps grafana
curl --fail --silent --show-error http://127.0.0.1:3000/api/health
ss -ltn | grep '127.0.0.1:3000'
```

Non proseguire se Grafana non è healthy o se la porta 3000 ascolta su `0.0.0.0` o
`[::]`.

### node-api

`node-api` è il futuro confine HTTP pubblico dell'istanza e usa bearer token per
gli endpoint protetti. Il token non sostituisce TLS e non deve essere copiato in
label, middleware o file Traefik.

Nella revisione pubblica corrente il servizio non è nello stack: la configurazione
mostrata più avanti è un modello per quando Sensor Flow lo abiliterà ufficialmente.
L'operatore non deve aggiungerlo autonomamente al Compose.

### admin-api

Non esporre `admin-api` con questa guida. Lo scaffold e il CRUD iniziale non
costituiscono ancora un control plane approvato per l'accesso da reti esterne.

## Caso A — Traefik eseguito direttamente sull'host

Un Traefik nativo può usare soltanto le porte loopback che il Compose canonico di
Sensor Flow pubblica già. L'operatore non deve aggiungere nuovi mapping di porta.

### Route Grafana

Nel file dinamico posseduto da Traefik aggiungere:

```yaml
http:
  routers:
    sensor-flow-grafana:
      rule: "Host(`grafana.example.com`)"
      entryPoints:
        - websecure
      service: sensor-flow-grafana
      tls:
        certResolver: letsencrypt

  services:
    sensor-flow-grafana:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:3000"
```

Se l'host usa certificati statici, mantenere `tls: {}` e omettere
`certResolver`. Applicare o ricaricare Traefik con la procedura della sua
installazione.

### Modello futuro per node-api

Usare questo modello soltanto quando la guida della versione installata dichiarerà
`node-api` presente e pubblicata sul loopback:

```yaml
http:
  routers:
    sensor-flow-node-api:
      rule: "Host(`api.example.com`)"
      entryPoints:
        - websecure
      service: sensor-flow-node-api
      tls:
        certResolver: letsencrypt

  services:
    sensor-flow-node-api:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:8080"
```

Se la porta 8080 non è pubblicata dal Compose canonico, il modello non è
applicabile a Traefik nativo e non va aggirato modificando Sensor Flow.

## Caso B — Traefik in Docker sullo stesso host

Un container Traefik non può raggiungere le porte `127.0.0.1` dell'host attraverso
il proprio loopback. Deve unirsi, tramite il suo Compose, alla rete Docker canonica
`sensor-flow` già creata dallo stack. Questa modifica riguarda soltanto Traefik.

Verificare che la rete esista:

```bash
docker network inspect sensor-flow >/dev/null
```

Nel Compose posseduto da Traefik aggiungere la rete esterna al servizio esistente,
conservando tutte le altre reti già configurate:

```yaml
services:
  traefik:
    networks:
      - sensor-flow

networks:
  sensor-flow:
    external: true
    name: sensor-flow
```

Il nome reale della rete non dipende dal project name Compose. Sensor Flow supporta
una sola istanza per host e possiede questa rete: non rinominarla o ricrearla dal
Compose di Traefik.

### Route Grafana

Nel file dinamico posseduto da Traefik aggiungere:

```yaml
http:
  routers:
    sensor-flow-grafana:
      rule: "Host(`grafana.example.com`)"
      entryPoints:
        - websecure
      service: sensor-flow-grafana
      tls:
        certResolver: letsencrypt

  services:
    sensor-flow-grafana:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://grafana:3000"
```

### Modello futuro per node-api

Quando `node-api` sarà ufficialmente presente nello stack, lo stesso Traefik potrà
raggiungerlo tramite il DNS interno del servizio:

```yaml
http:
  routers:
    sensor-flow-node-api:
      rule: "Host(`api.example.com`)"
      entryPoints:
        - websecure
      service: sensor-flow-node-api
      tls:
        certResolver: letsencrypt

  services:
    sensor-flow-node-api:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://node-api:8080"
```

Non applicare oggi questa route: il nome DNS esisterà soltanto quando il servizio
sarà incluso dal Compose canonico.

Applicare il Compose e la configurazione dinamica di Traefik con la procedura
propria dell'host. Non usare `docker network connect` come soluzione permanente.

Verificare l'appartenenza alla rete senza dipendere dagli IP dei container:

```bash
docker network inspect sensor-flow \
  --format '{{range .Containers}}{{println .Name}}{{end}}'
```

Per la route Grafana, l'output deve includere il container Grafana di Sensor Flow e
quello Traefik.

## Verifica esterna

Per ogni superficie effettivamente selezionata, verificare da una macchina esterna
all'host.

Grafana:

```bash
curl --fail --silent --show-error \
  https://grafana.example.com/api/health
```

Quando `node-api` sarà abilitata, il solo health endpoint pubblico:

```bash
curl --fail --silent --show-error \
  https://api.example.com/health
```

Per Grafana verificare inoltre nel browser:

- certificato valido per il dominio;
- redirect da HTTP a HTTPS, se previsto dalla politica generale di Traefik;
- login con la password ruotata;
- apertura delle dashboard provisionate;
- datasource `Sensor Flow PostgreSQL` sano;
- assenza di errori nelle richieste `/api/live/`.

Traefik gestisce WebSocket e WSS attraverso il normale router HTTP; non servono
header di upgrade aggiunti manualmente. Un proxy intermedio potrebbe comunque
rimuoverli e va verificato separatamente.

Sul server confermare che Sensor Flow non sia diventato direttamente pubblico:

```bash
ss -ltn | grep -E '127.0.0.1:(3000|5433|15672)'

cd "$HOME/sensor-flow"
docker compose -f compose.yaml ps
```

## Diagnosi rapida

| Sintomo | Controllo |
| --- | --- |
| `404` Traefik | Regola `Host`, entrypoint e caricamento del file dinamico |
| `502` con Traefik nativo | Porta loopback già pubblicata da Sensor Flow e health locale del servizio |
| `502` con Traefik Docker | Rete esterna condivisa e nome DNS del servizio nella rete Compose |
| Certificato predefinito | DNS, resolver ACME, challenge e log Traefik |
| Login o redirect Grafana errato | Sottodominio alla radice e `Host` originale preservato |
| Grafana Live non connesso | Richieste `/api/live/`, proxy intermedi e policy WebSocket |

Non correggere questi sintomi modificando IP dei container o file gestiti da Sensor
Flow. Se il backend non è esposto dal contratto corrente, la route non è ancora
supportata.

## Rollback

Rimuovere o disabilitare dal solo Traefik i router e i service aggiunti. Nel caso
Docker, rimuovere anche la rete `sensor-flow` dal Compose di Traefik se non è usata
da altre route.

Il rollback non richiede modifiche o riavvii di Sensor Flow. Le superfici loopback
restano disponibili tramite tunnel SSH.

## Riferimenti

- [Traefik: file provider e configurazione dinamica](https://doc.traefik.io/traefik/reference/dynamic-configuration/file/)
- [Traefik: router HTTP](https://doc.traefik.io/traefik/reference/routing-configuration/http/routing/router/)
- [Traefik: TLS sui router HTTP](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/overview/)
- [Traefik: WebSocket](https://doc.traefik.io/traefik/master/user-guides/websocket/)
- [Grafana: configurazione del server e `root_url`](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
