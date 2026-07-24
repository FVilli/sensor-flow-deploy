# Sensor Flow public deployment channel

Questo repository contiene gli artefatti pubblici usati dalle istanze Sensor Flow:

- `stable.json`: stato desiderato del canale stabile;
- `compose.yaml`: definizione base dello stack;
- `update.sh`: riconciliazione automatica per digest;
- `sensor-flow-bootstrap.sh`: bootstrap idempotente di una nuova istanza;
- `SHA256SUMS`: checksum degli asset;
- `INSTANCE_SETUP.md`: installazione di una nuova istanza;
- `DEPLOYMENT.md`: modello di pubblicazione e aggiornamento.

Il codice sorgente applicativo resta nel repository privato. Le immagini indicate
nel manifest sono pubbliche e vengono sempre referenziate tramite digest
immutabile.

Le istanze non richiedono token GitHub, login Docker o una versione esplicita:
controllano periodicamente `stable.json` e convergono sulla revisione pubblicata.
