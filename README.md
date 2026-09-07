# Sensor Flow public deployment channel

Questo repository contiene gli artefatti pubblici usati dalle istanze Sensor Flow:

- `stable.json`: stato desiderato del canale stabile;
- `compose.yaml`: definizione completa dello stack con immagini `stable`;
- `update.sh`: riconciliazione automatica selettiva tramite i digest del manifest;
- `prepare.sh`: prepara il filesystem locale di una nuova istanza;
- `bootstrap.sh`: bootstrap idempotente di una nuova istanza;
- `SHA256SUMS`: checksum degli asset;
- `INSTANCE_SETUP.md`: installazione di una nuova istanza.
- `guides/`: integrazioni opzionali possedute dall'host, non applicate dall'updater.

Il codice sorgente applicativo resta nel repository privato. Le immagini sono
pubbliche e il Compose le referenzia tramite il tag mobile `stable`; i digest
immutabili nel manifest restano la base per confronto, audit e verifica.

Le istanze non richiedono token GitHub, login Docker o una versione esplicita:
controllano periodicamente `stable.json` e convergono sulla revisione pubblicata.
