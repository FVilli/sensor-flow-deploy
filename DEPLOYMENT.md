# Deployment

Per il bootstrap completo di una macchina vergine vedere
[`INSTANCE_SETUP.md`](INSTANCE_SETUP.md).

## Modello

Il repository sorgente è privato. Le immagini GHCR e il repository
`FVilli/sensor-flow-deploy`, che contiene gli artefatti di deployment, sono pubblici.
Le istanze non usano token GitHub né un tag di versione.

Un push su `main` pubblica soltanto quando il messaggio del commit di testa contiene
`[deploy]`. La pipeline:

1. esegue build e test;
2. legge il `stable.json` attualmente pubblico;
3. confronta il suo `gitCommit` con il commit della release;
4. costruisce soltanto le immagini interessate dalle modifiche;
5. conserva i digest precedenti degli altri servizi;
6. verifica il pull anonimo di ogni immagine candidata;
7. pubblica asset e nuovo manifest nel repository pubblico.

Il push del repository pubblico aggiorna il riferimento Git in modo atomico. Il
manifest è preparato dopo gli asset e diventa quindi visibile insieme allo stato
completo.

## Selezione dei servizi

`scripts/select-changed-services.sh` contiene il grafo minimo delle dipendenze:

- modifica di un'app o del suo Dockerfile: solo quel servizio;
- `libs/logging`: tutti i servizi Node.js;
- `libs/mqtt-relay-contracts`: `mqtt-ingress-relay`;
- `libs/rabbit-contracts`: `queue-manager`;
- `libs/raw-contracts`: `raw-writer` e `db-writer`;
- package lock, package root o TypeScript config: tutti i servizi Node.js;
- configurazione RabbitMQ: `rabbitmq`;
- dashboard, provisioning o Dockerfile Grafana: `grafana`;
- prima pubblicazione: tutte le immagini.

Il manifest usa esclusivamente riferimenti immutabili:

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "revision": 2,
  "gitCommit": "0123456789abcdef0123456789abcdef01234567",
  "services": {
    "raw-writer": {
      "image": "ghcr.io/fvilli/sensor-flow-raw-writer",
      "digest": "sha256:..."
    }
  }
}
```

La pipeline interrompe la pubblicazione prima di aggiornare `stable.json` se anche
una sola immagine non concede un token GHCR anonimo o il relativo digest non è
scaricabile. Una nuova immagine privata non può quindi diventare una revisione
`stable`.

## Prerequisiti una tantum su GitHub

1. creare il repository pubblico `FVilli/sensor-flow-deploy`;
2. configurare nel repository sorgente il secret
   `DEPLOYMENT_REPOSITORY_SSH_KEY`, contenente una deploy key con scrittura
   limitata al solo repository pubblico;
3. dopo la prima pubblicazione, rendere pubblici i sette package GHCR;
4. verificare che `stable.json` e le immagini siano scaricabili anonimamente.

La pubblicazione dei package deve essere cambiata a pubblica una sola volta per
package; le versioni successive ne ereditano la visibilità.

## Aggiornamento delle istanze

Il timer utente `sensor-flow-update.timer` esegue ogni minuto:

```bash
~/sensor-flow/scripts/update.sh
```

Lo script:

1. scarica il manifest pubblico;
2. confronta i digest con `.sensor-flow/applied.json`;
3. scarica esclusivamente le immagini cambiate;
4. rigenera `compose.release.yaml`;
5. riconcilia con `--no-deps` i soli servizi interessati;
6. registra il manifest applicato;
7. ripristina i digest precedenti se Compose non raggiunge lo stato atteso.

Configurazione, RAW, PostgreSQL e RabbitMQ persistenti non vengono rimossi.

Il comando può essere rilanciato manualmente ed è idempotente:

```bash
SENSOR_FLOW_ROOT="$HOME/sensor-flow" \
  "$HOME/sensor-flow/scripts/update.sh"
```

Per un URL di test:

```bash
SENSOR_FLOW_MANIFEST_URL=https://example.test/stable.json \
SENSOR_FLOW_ROOT="$HOME/sensor-flow" \
  "$HOME/sensor-flow/scripts/update.sh"
```

## Pubblicare

1. preparare un incremento compilabile e testato;
2. usare `[deploy]` nel messaggio del commit che viene inviato su `main`;
3. eseguire il normale `git push`;
4. attendere `Publish stable deployment`;
5. verificare il nuovo `stable.json`;
6. verificare che una istanza applichi la nuova revisione;
7. confermare che siano stati ricreati soltanto i container attesi.

Esempio:

```bash
git commit -m "[deploy] Reduce RabbitMQ healthcheck overhead"
git push origin main
```

Un commit senza `[deploy]` non modifica il canale `stable`.

### Cache del manifest

`raw.githubusercontent.com` può servire temporaneamente la revisione precedente
dopo una pubblicazione. Le istanze riprovano al ciclo successivo del timer e la
revisione monotona impedisce downgrade. Per una verifica operativa immediata,
risolvere prima il commit corrente del repository pubblico e leggere il manifest
tramite quel commit invece del branch mobile.

## Limiti correnti

- il health gate verifica il lifecycle Compose, non ancora l'avanzamento funzionale;
- il manifest è protetto da HTTPS e controllo del repository, ma non ancora firmato;
- un aggiornamento degli asset di deployment è distribuito dal bootstrap, mentre
  l'auto-aggiornamento dello stesso updater sarà un incremento separato.

## Healthcheck RabbitMQ

`rabbitmq-diagnostics` avvia una VM Erlang separata e non è un probe economico. Il
controllo viene eseguito ogni 5 secondi durante lo startup, per sbloccare rapidamente
le dipendenze Compose, e ogni 60 secondi dopo il primo esito positivo. Non ridurre
l'intervallo a regime senza misurarne l'impatto con:

```bash
rabbitmq-diagnostics runtime_thread_stats --sample-interval 15
```
