# Come esporre i servizi di Sensor Flow

## 1. Scopo e confine di responsabilità

Sensor Flow viene distribuito tramite un Compose standard, indipendente dall'ambiente di installazione. Questa guida descrive come il gestore dell'host può rendere raggiungibili le superfici HTTP supportate, senza modificare il deployment applicativo.

L'esposizione è un livello infrastrutturale separato. Reverse proxy, DNS, certificati, firewall, autenticazione perimetrale e scelta delle superfici raggiungibili sono responsabilità dell'utilizzatore.

L'operatore:

* non modifica `compose.yaml` di Sensor Flow;
* non aggiunge label Traefik ai servizi applicativi;
* non cambia bind di porta, IP o configurazioni dei container;
* non modifica file sotto `.sensor-flow/`;
* non utilizza `docker network connect` come soluzione permanente.

Se una superficie non è disponibile nello stack installato, non deve essere abilitata modificando autonomamente Sensor Flow. Occorre attendere una versione che la includa ufficialmente.

## 2. Architettura di esposizione

```text
Client Internet / LAN / VPN
            │
            ▼
    Reverse proxy dell'host
    Traefik, Caddy, Nginx...
            │
            ▼
    Network Docker sensor-flow
            │
            ├── Grafana
            ├── admin-api
            ├── node-api (quando disponibile)
            └── altri servizi supportati
```

Il proxy può essere eseguito direttamente sull'host oppure in un Compose separato. Nel secondo caso si collega alla network Docker canonica `sensor-flow`, senza modificare lo stack applicativo.

La revisione `stable` corrente pubblica inoltre alcune porte esclusivamente su `127.0.0.1` per operatività locale. Questi bind sono parte del deployment attuale e possono essere utilizzati da un proxy nativo sull'host, ma non devono essere ampliati dall'operatore.

### Network Docker

La network ha nome stabile `sensor-flow`, indipendente dal project name Compose. Sensor Flow supporta una sola istanza per host e possiede questa network.

Un proxy Docker deve dichiararla come esterna:

```yaml
networks:
  sensor-flow:
    external: true
    name: sensor-flow
```

La direttiva `expose` nei servizi applicativi è facoltativa e documenta le porte interne; non è necessaria per consentire la comunicazione tra container sulla stessa network.

## 3. Superfici disponibili e pubblicabilità

Non tutto ciò che ascolta su una porta è una superficie da esporre. La seguente tabella distingue lo stato dello stack `stable` corrente dall'intento architetturale.

| Superficie            | Stato corrente                                                       | Uso previsto                                            | Esposizione                                                                  |
| --------------------- | -------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Grafana               | Presente su `127.0.0.1:3000` e `grafana:3000` nella network Compose  | Dashboard e osservazione                                | Sì, su scelta dell'operatore                                                 |
| `node-api`            | Implementata nel sorgente, non ancora abilitata nello stack pubblico | API versionata per dati, export e integrazioni          | Prevista; non configurare ancora la route                                    |
| `admin-api`           | Presente su `127.0.0.1:8081` e `admin-api:8081`, solo per ADR-043    | Backend della dashboard `Gestione utenti-sensori`       | Sì, su scelta dell'operatore — nessuna autenticazione applicativa, vedi §6.3 |
| RabbitMQ Management   | Presente su `127.0.0.1:15672`                                        | Diagnosi tecnica locale                                 | No; usare tunnel SSH o rete amministrativa privata                           |
| RabbitMQ MQTT/AMQP    | Presenti sul loopback e nella network Docker                         | Bus interno dell'istanza                                | No; questa guida non prevede router TCP                                      |
| PostgreSQL            | Presente su `127.0.0.1:5433`                                         | Debug e operatività locale fino alla major 1            | No; usare tunnel SSH o rete amministrativa privata                           |
| Worker, probe e agent | Nessuna REST API pubblica                                            | Elaborazione e osservabilità interne                    | No                                                                           |
| `mqtt-ingress-relay`  | Nessuna porta pubblica in ingresso                                   | Connessioni in uscita verso broker sorgente configurati | No                                                                           |

La lista deve essere verificata rispetto alla versione installata. Una nuova porta non diventa automaticamente pubblicabile: deve essere classificata nella documentazione architetturale di Sensor Flow.

## 4. Scelta della modalità di accesso

L'operatore può esporre soltanto le superfici necessarie, oppure non esporne alcuna. Per ogni superficie candidata decide il pubblico destinatario (Internet, LAN, VPN o amministratori), l'URL, l'autenticazione e le eventuali policy infrastrutturali.

### Intranet

Per una installazione semplice, la documentazione propone Caddy in un Compose separato, con porte HTTP distinte. È un esempio pronto all'uso che il sistemista può adattare o sostituire.

### Cloud o infrastruttura già gestita

L'utilizzatore può utilizzare Traefik, Caddy, Nginx o un reverse proxy esistente. La configurazione di domini, HTTPS, certificati e sicurezza perimetrale rimane di sua competenza.

Per le route HTTPS di questa guida si utilizzano sottodomini dedicati, ad esempio `grafana.example.com`. I path prefix come `example.com/grafana` richiedono configurazioni applicative aggiuntive e non sono coperti dall'esempio cloud.

## 5. Installazione intranet — Caddy

Questa è la soluzione suggerita per rendere rapidamente accessibili le superfici HTTP supportate in una rete interna. Caddy viene collegato alla network `sensor-flow` e pubblica le porte desiderate sull'host.

L'esempio non configura TLS. L'eventuale aggiunta di HTTPS o di altre misure infrastrutturali è lasciata al gestore dell'ambiente.

### 5.1 Esempio di accesso

| Servizio            | URL intranet            | Destinazione Docker |
| ------------------- | ----------------------- | ------------------- |
| Grafana             | `http://ip-server:3000` | `grafana:3000`      |
| `admin-api`         | `http://ip-server:8081` | `admin-api:8081`    |
| `node-api` (futura) | `http://ip-server:3001` | `node-api:8080`     |

`admin-api` non richiede autenticazione applicativa sui suoi endpoint (vedi §6.3):
esporla anche solo in intranet significa che chiunque sulla rete interna può
leggere e modificare le associazioni utente-sensore. Includerla solo se la
rete interna è già considerata affidabile.

La route `node-api` è riportata come modello futuro e non deve essere abilitata finché il servizio non sarà presente nel Compose canonico.

### 5.2 compose.intranet.yml

```yaml
services:
  caddy:
    image: caddy:2
    ports:
      - "3000:3000"
      - "8081:8081" # admin-api, opzionale — vedi la nota sulla fiducia della rete in §5.1
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    networks:
      - sensor-flow

networks:
  sensor-flow:
    external: true
    name: sensor-flow
```

### 5.3 Caddyfile

```caddyfile
:3000 {
    reverse_proxy grafana:3000
}

:8081 {
    reverse_proxy admin-api:8081
}
```

Le porte esterne coincidono con quelle di ascolto di Caddy, evitando mappature con numerazioni differenti.

Quando `node-api` sarà ufficialmente disponibile, l'operatore potrà aggiungere al Compose:

```yaml
ports:
  - "3000:3000"
  - "3001:3001"
```

E al Caddyfile:

```caddyfile
:3001 {
    reverse_proxy node-api:8080
}
```

I nomi e le porte interne devono sempre corrispondere a quelli della versione installata.

### 5.4 Alternativa con percorsi

È possibile utilizzare un'unica porta con percorsi distinti, ad esempio `/grafana` e `/api`. Questa soluzione richiede però che le applicazioni supportino correttamente un base path. Per evitare configurazioni aggiuntive e problemi con redirect o asset, l'esempio intranet predefinito utilizza porte distinte.

## 6. Installazione cloud — Traefik esistente

Questa sezione si rivolge a chi dispone già di un Traefik amministrato dall'infrastruttura. Non prevede l'installazione o la configurazione completa di Traefik.

### 6.1 Prerequisiti

Gli esempi assumono:

* un entrypoint HTTPS chiamato `websecure`;
* un certificate resolver ACME chiamato `letsencrypt`, oppure certificati statici già gestiti dall'host;
* file provider abilitato, con reload automatico o procedura di reload nota;
* record DNS A e, se utilizzato, AAAA diretti all'host Traefik;
* porte 80 e 443 gestite secondo la politica dell'infrastruttura.

Sostituire nomi, domini e resolver con quelli reali. Un router con `tls.certResolver` richiede che il resolver sia già definito nella configurazione statica di Traefik.

### 6.2 Preparazione di Grafana

Grafana è l'unica superficie pubblicabile già presente nello stack `stable`.

Prima di creare una route accessibile dall'esterno, accedere tramite tunnel SSH e sostituire la password amministrativa di sviluppo con una password unica e robusta:

```bash
ssh -L 3000:127.0.0.1:3000 ubuntu@istanza
```

Aprire `http://localhost:3000`, autenticarsi e cambiare la password. Non conservare la nuova password nei file Traefik o nel repository Sensor Flow.

Verificare sull'istanza:

```bash
cd "$HOME/sensor-flow"

docker compose -f compose.yaml ps grafana
curl --fail --silent --show-error http://127.0.0.1:3000/api/health
ss -ltn | grep '127.0.0.1:3000'
```

Non proseguire se Grafana non è healthy o se la porta 3000 ascolta su `0.0.0.0` o `[::]`.

### 6.3 Preparazione di admin-api

`admin-api` è presente nello stack `stable` corrente, ma solo per la superficie
stretta di gestione delle associazioni utente-sensore (ADR-043): due endpoint
`GET`/`PUT /api/v1/users/:grafanaUserId/sensors` più `GET /api/v1/sensors`. Questi
endpoint **non richiedono autenticazione applicativa** — chiunque raggiunga l'URL
pubblico può leggere e modificare le associazioni. Non è un problema di
confidenzialità dei dati (le misure dei sensori non sono considerate sensibili,
vedi ADR-040), ma di integrità: chiunque conosca l'URL potrebbe alterare quali
sensori compaiono nel filtro di un altro utente.

Esporre `admin-api` è quindi una scelta consapevole dell'operatore, non un passo
obbligato. Se non la si espone, la dashboard `Sensor Flow · Gestione
utenti-sensori` resta comunque utilizzabile tramite tunnel SSH sulla porta
`127.0.0.1:8081`, come per Grafana.

Se si sceglie di esporla, dopo aver creato la route (§6.4/§6.5) aggiornare
`adminApiPublicUrl` in `volumes/config/env.json` con l'URL pubblico scelto e
riavviare `db-writer` perché la dashboard lo recuperi automaticamente:

```bash
docker compose -f compose.yaml restart db-writer
```

Senza questo passo la dashboard continua a puntare al valore precedente (di
default `http://localhost:8081`) finché `db-writer` non viene riavviato.

Verificare sull'istanza:

```bash
cd "$HOME/sensor-flow"

docker compose -f compose.yaml ps admin-api
curl --fail --silent --show-error http://127.0.0.1:8081/health
ss -ltn | grep '127.0.0.1:8081'
```

### 6.4 Caso A — Traefik nativo sull'host

Un Traefik eseguito direttamente sull'host può utilizzare le porte loopback già pubblicate dal Compose canonico. L'operatore non deve aggiungere nuovi mapping.

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

Se l'host usa certificati statici, mantenere `tls: {}` e omettere `certResolver`. Applicare o ricaricare Traefik con la procedura della sua installazione.

Se si è scelto di esporre anche `admin-api` (§6.3), aggiungere allo stesso file:

```yaml
http:
  routers:
    sensor-flow-admin-api:
      rule: "Host(`admin-api.example.com`)"
      entryPoints:
        - websecure
      service: sensor-flow-admin-api
      tls:
        certResolver: letsencrypt

  services:
    sensor-flow-admin-api:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://127.0.0.1:8081"
```

### 6.5 Caso B — Traefik in Docker

Un container Traefik non può raggiungere le porte `127.0.0.1` dell'host attraverso il proprio loopback. Deve quindi essere collegato alla network Docker canonica di Sensor Flow.

Verificare che la rete esista:

```bash
docker network inspect sensor-flow >/dev/null
```

Nel Compose posseduto da Traefik aggiungere la network esterna al servizio esistente, conservando tutte le altre reti già configurate:

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

Non rinominare o ricreare la network dal Compose di Traefik. Applicare il Compose con la procedura dell'host, senza utilizzare `docker network connect` come soluzione permanente.

Nel file dinamico aggiungere:

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

Verificare l'appartenenza alla rete senza dipendere dagli IP dei container:

```bash
docker network inspect sensor-flow \
  --format '{{range .Containers}}{{println .Name}}{{end}}'
```

L'output deve includere il container Grafana di Sensor Flow e quello Traefik.

Se si è scelto di esporre anche `admin-api` (§6.3), aggiungere allo stesso file:

```yaml
http:
  routers:
    sensor-flow-admin-api:
      rule: "Host(`admin-api.example.com`)"
      entryPoints:
        - websecure
      service: sensor-flow-admin-api
      tls:
        certResolver: letsencrypt

  services:
    sensor-flow-admin-api:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://admin-api:8081"
```

### 6.6 Modello futuro per node-api

`node-api` è il futuro confine HTTP pubblico dell'istanza e utilizza bearer token per gli endpoint protetti. Nella revisione pubblica corrente non è incluso nello stack.

Quando la documentazione della versione installata ne dichiarerà la disponibilità, un Traefik Docker potrà raggiungerlo tramite il DNS interno:

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

Per Traefik nativo sull'host, il modello sarà applicabile soltanto se il Compose canonico pubblicherà ufficialmente una porta loopback, ad esempio `127.0.0.1:8080`. In tal caso la destinazione sarà:

```yaml
servers:
  - url: "http://127.0.0.1:8080"
```

Non applicare oggi queste route e non aggiungere autonomamente `node-api` al Compose. Il token applicativo non sostituisce TLS e non deve essere copiato in label, middleware o file Traefik.

## 7. Verifica dell'esposizione

Per ogni superficie effettivamente selezionata, verificare da una macchina esterna all'host.

### Grafana

```bash
curl --fail --silent --show-error \
  https://grafana.example.com/api/health
```

Verificare inoltre nel browser:

* certificato valido per il dominio, se si utilizza HTTPS;
* eventuale redirect HTTP → HTTPS previsto dall'infrastruttura;
* login con la password aggiornata;
* apertura delle dashboard provisionate;
* datasource `Sensor Flow PostgreSQL` sano;
* assenza di errori nelle richieste `/api/live/`.

Traefik gestisce WebSocket e WSS attraverso il normale router HTTP; non servono header di upgrade aggiunti manualmente. Eventuali proxy intermedi devono essere verificati separatamente.

### admin-api, se esposta

```bash
curl --fail --silent --show-error \
  https://admin-api.example.com/health

curl --fail --silent --show-error \
  https://admin-api.example.com/api/v1/sensors
```

La seconda chiamata deve restituire l'elenco dei sensori senza alcun header di
autenticazione: è il comportamento atteso (§6.3), non un errore. Verificare anche
che la dashboard `Sensor Flow · Gestione utenti-sensori` carichi/salvi
correttamente le associazioni usando l'URL pubblico appena verificato.

### node-api, quando disponibile

Verificare soltanto l'health endpoint pubblico:

```bash
curl --fail --silent --show-error \
  https://api.example.com/health
```

### Controllo del deployment

Sul server confermare che Sensor Flow non sia diventato direttamente pubblico:

```bash
ss -ltn | grep -E '127.0.0.1:(3000|5433|8081|15672)'

cd "$HOME/sensor-flow"
docker compose -f compose.yaml ps
```

Le verifiche devono essere coerenti con la modalità scelta: nel caso intranet, Caddy pubblica intenzionalmente le proprie porte HTTP; nel caso cloud, l'esposizione è gestita dal proxy dell'host.

## 8. Diagnosi rapida

| Sintomo                         | Controllo                                                    |
| ------------------------------- | ------------------------------------------------------------ |
| `404` Traefik                   | Regola `Host`, entrypoint e caricamento del file dinamico    |
| `502` con Traefik nativo        | Porta loopback già pubblicata da Sensor Flow e health locale |
| `502` con Traefik Docker        | Network condivisa e nome DNS del servizio                    |
| `502` con Caddy                 | Network condivisa, nome DNS e porta interna del backend      |
| Certificato predefinito         | DNS, resolver, certificati e log del proxy                   |
| Login o redirect Grafana errato | URL utilizzato, `root_url` e header Host                     |
| Grafana Live non connesso       | Richieste `/api/live/`, proxy intermedi e WebSocket          |

Non correggere questi sintomi modificando IP dei container o file gestiti da Sensor Flow. Se il backend non è previsto dal contratto della versione corrente, la route non è ancora supportata.

## 9. Rimozione dell'esposizione

Per disabilitare l'accesso, rimuovere o disabilitare i router e i service aggiunti nel reverse proxy.

Nel caso Docker, rimuovere anche la network `sensor-flow` dal Compose del proxy se non è più utilizzata da altre route. Nel caso intranet, arrestare o rimuovere il Compose opzionale di Caddy.

Non sono necessarie modifiche o riavvii di Sensor Flow. Le superfici loopback previste dallo stack restano disponibili tramite tunnel SSH.

Se si era esposta `admin-api`, ripristinare `adminApiPublicUrl` in `env.json`
all'URL raggiungibile (es. `http://localhost:8081`) e riavviare `db-writer`;
altrimenti la dashboard `Sensor Flow · Gestione utenti-sensori` continua a
puntare all'URL pubblico ora rimosso.

## 10. Riferimenti

* [Traefik: file provider e configurazione dinamica](https://doc.traefik.io/traefik/reference/dynamic-configuration/file/)
* [Traefik: router HTTP](https://doc.traefik.io/traefik/reference/routing-configuration/http/routing/router/)
* [Traefik: TLS sui router HTTP](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/overview/)
* [Traefik: WebSocket](https://doc.traefik.io/traefik/master/user-guides/websocket/)
* [Caddy: reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
* [Grafana: configurazione del server e root_url](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
