# SkyRescue iOS

App iOS SwiftUI per accoppiare un dispositivo Meshtastic via Bluetooth LE e visualizzare dati radio, NodeDB, telemetry e log pacchetti.

## Stack

- SwiftUI per UI Apple-native.
- CoreBluetooth per pairing e GATT BLE.
- `MeshtasticProtobufs` locale, copiato dalla repo ufficiale `meshtastic/Meshtastic-Apple`, per codificare `ToRadio.wantConfigID` e decodificare `FromRadio`.

## Flusso Meshtastic implementato

1. Scan BLE del servizio Meshtastic `6BA1B218-15A8-461F-9FA8-5DCAE273EAFD`.
2. Connessione al device e discovery di `FromRadio`, `ToRadio`, `FromNum`, log, Battery Service e Device Information Service.
3. Invio `ToRadio.wantConfigID`.
4. Lettura ripetuta di `FromRadio` e subscribe a `FromNum`.
5. Dashboard con nodo locale, info hardware BLE, NodeDB, telemetry e log pacchetti.

## Avvio

Apri `SkyRescue.xcodeproj` in Xcode, seleziona un iPhone reale e premi Run. Il simulatore iOS non puo testare BLE verso hardware Meshtastic reale.
