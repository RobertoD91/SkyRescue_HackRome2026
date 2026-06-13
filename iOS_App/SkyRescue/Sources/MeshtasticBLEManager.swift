import CoreBluetooth
import Foundation
import MeshtasticProtobufs
import SwiftProtobuf

final class MeshtasticBLEManager: NSObject, ObservableObject {
    @Published private(set) var statusText = "Pronto per accoppiare"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var connectedDeviceName = ""
    @Published private(set) var myNode: MyNodeSummary?
    @Published private(set) var deviceInfo: [InfoRow] = []
    @Published private(set) var meshNodes: [MeshNodeSnapshot] = []
    @Published private(set) var telemetry: [TelemetrySnapshot] = []
    @Published private(set) var packetEvents: [PacketEvent] = []

    private let meshServiceUUID = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    private let fromRadioUUID = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
    private let toRadioUUID = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
    private let fromNumUUID = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")
    private let logRecordUUID = CBUUID(string: "5A3D6E49-06E6-4423-9944-E9DE8CDF9547")
    private let rawLogUUID = CBUUID(string: "6C6FD238-78FA-436B-AACF-15C5BE1EF2E2")
    private let deviceInfoServiceUUID = CBUUID(string: "180A")
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var currentPeripheral: CBPeripheral?
    private var fromRadioCharacteristic: CBCharacteristic?
    private var toRadioCharacteristic: CBCharacteristic?
    private var fromNumCharacteristic: CBCharacteristic?
    private var hasRequestedConfig = false
    private var configNonce = UInt32.random(in: 1...UInt32.max)
    private var nodesByID: [UInt32: MeshNodeSnapshot] = [:]
    private var telemetryByNode: [UInt32: TelemetrySnapshot] = [:]
    private var infoRowsByTitle: [String: InfoRow] = [:]
    private var scanAllDevices = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan(includeAllNamedDevices: Bool = false) {
        guard central.state == .poweredOn else {
            statusText = bluetoothStateText
            return
        }

        scanAllDevices = includeAllNamedDevices
        discoveredDevices = []
        peripherals = [:]
        isScanning = true
        statusText = includeAllNamedDevices ? "Cerco dispositivi BLE nelle vicinanze" : "Cerco dispositivi Meshtastic"
        let services = includeAllNamedDevices ? nil : [meshServiceUUID]
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if !isConnected {
            statusText = "Scansione fermata"
        }
    }

    func connect(to device: DiscoveredDevice) {
        guard let peripheral = peripherals[device.id] else { return }
        stopScan()
        resetSessionData(keepingDiscovery: true)
        statusText = "Connessione a \(device.name)"
        connectedDeviceName = device.name
        currentPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let currentPeripheral else { return }
        central.cancelPeripheralConnection(currentPeripheral)
    }

    func refreshConfig() {
        hasRequestedConfig = false
        requestConfigIfReady()
    }

    private var bluetoothStateText: String {
        switch central.state {
        case .poweredOff: return "Bluetooth spento"
        case .unauthorized: return "Permesso Bluetooth mancante"
        case .unsupported: return "Bluetooth non supportato"
        case .resetting: return "Bluetooth in reset"
        case .poweredOn: return "Bluetooth pronto"
        case .unknown: fallthrough
        @unknown default: return "Bluetooth non disponibile"
        }
    }

    private func resetSessionData(keepingDiscovery: Bool = false) {
        hasRequestedConfig = false
        fromRadioCharacteristic = nil
        toRadioCharacteristic = nil
        fromNumCharacteristic = nil
        myNode = nil
        deviceInfo = []
        meshNodes = []
        telemetry = []
        packetEvents = []
        nodesByID = [:]
        telemetryByNode = [:]
        infoRowsByTitle = [:]
        if !keepingDiscovery {
            discoveredDevices = []
            peripherals = [:]
        }
    }

    private func requestConfigIfReady() {
        guard !hasRequestedConfig,
              let peripheral = currentPeripheral,
              let toRadioCharacteristic,
              let fromRadioCharacteristic
        else { return }

        do {
            configNonce = UInt32.random(in: 1...UInt32.max)
            var toRadio = ToRadio()
            toRadio.wantConfigID = configNonce
            let payload = try toRadio.serializedData()
            hasRequestedConfig = true
            statusText = "Sincronizzo NodeDB Meshtastic"
            addEvent(title: "Richiesta config", subtitle: "wantConfigID \(configNonce)", details: "Inviato ToRadio.wantConfigID per scaricare configurazione, nodi e pacchetti in coda.")
            peripheral.writeValue(payload, for: toRadioCharacteristic, type: .withResponse)
            peripheral.readValue(for: fromRadioCharacteristic)
        } catch {
            statusText = "Errore protobuf: \(error.localizedDescription)"
        }
    }

    private func drainFromRadio() {
        guard let peripheral = currentPeripheral, let fromRadioCharacteristic else { return }
        peripheral.readValue(for: fromRadioCharacteristic)
    }

    private func setInfo(_ title: String, value: String, systemImage: String) {
        guard !value.isEmpty else { return }
        infoRowsByTitle[title] = InfoRow(title: title, value: value, systemImage: systemImage)
        deviceInfo = infoRowsByTitle.values.sorted { $0.title < $1.title }
    }

    private func addEvent(title: String, subtitle: String, details: String) {
        packetEvents.insert(PacketEvent(title: title, subtitle: subtitle, details: details), at: 0)
        if packetEvents.count > 200 {
            packetEvents.removeLast(packetEvents.count - 200)
        }
    }

    private func handleFromRadioData(_ data: Data) {
        guard !data.isEmpty else {
            if isConnected {
                statusText = "Connesso a \(connectedDeviceName)"
            }
            return
        }

        do {
            let fromRadio = try FromRadio(serializedBytes: data)
            switch fromRadio.payloadVariant {
            case .myInfo(let info):
                myNode = MyNodeSummary(
                    nodeNum: info.myNodeNum,
                    rebootCount: info.rebootCount,
                    minAppVersion: info.minAppVersion,
                    pioEnv: info.pioEnv,
                    nodedbCount: info.nodedbCount
                )
                setInfo("Nodo locale", value: UInt64(info.myNodeNum).hexNodeID, systemImage: "dot.radiowaves.left.and.right")
                setInfo("Piattaforma firmware", value: info.pioEnv, systemImage: "cpu")
                setInfo("NodeDB attesi", value: "\(info.nodedbCount)", systemImage: "point.3.connected.trianglepath.dotted")
                addEvent(title: "MyNodeInfo", subtitle: UInt64(info.myNodeNum).hexNodeID, details: String(describing: info))

            case .nodeInfo(let nodeInfo):
                upsertNode(from: nodeInfo)
                addEvent(title: "NodeInfo", subtitle: nodeInfo.user.longName.isEmpty ? UInt64(nodeInfo.num).hexNodeID : nodeInfo.user.longName, details: String(describing: nodeInfo))

            case .packet(let packet):
                handleMeshPacket(packet)

            case .config(let config):
                addEvent(title: "Config", subtitle: "Radio/device config", details: String(describing: config))

            case .moduleConfig(let moduleConfig):
                addEvent(title: "Module config", subtitle: "Configurazione moduli", details: String(describing: moduleConfig))

            case .channel(let channel):
                addEvent(title: "Canale", subtitle: "Index \(channel.index)", details: String(describing: channel))

            case .metadata(let metadata):
                setInfo("Firmware", value: metadata.firmwareVersion, systemImage: "memorychip")
                setInfo("Device state", value: "\(metadata.deviceStateVersion)", systemImage: "number")
                setInfo("Connettivita", value: metadataConnectivity(metadata), systemImage: "antenna.radiowaves.left.and.right")
                addEvent(title: "Metadata", subtitle: metadata.firmwareVersion, details: String(describing: metadata))

            case .queueStatus(let queue):
                addEvent(title: "Coda radio", subtitle: "Queue status", details: String(describing: queue))

            case .logRecord(let log):
                addEvent(title: "Log firmware", subtitle: log.source.isEmpty ? String(describing: log.level) : log.source, details: log.message)

            case .clientNotification(let notification):
                addEvent(title: "Notifica client", subtitle: "Firmware", details: String(describing: notification))

            case .configCompleteID(let id):
                statusText = id == configNonce ? "Sincronizzazione completata" : "Config ricevuta da sessione precedente"
                addEvent(title: "Config completa", subtitle: "ID \(id)", details: "Nonce locale: \(configNonce)")

            case .rebooted(let rebooted):
                addEvent(title: "Dispositivo riavviato", subtitle: rebooted ? "Reboot rilevato" : "Stato reboot", details: String(describing: fromRadio))

            case .mqttClientProxyMessage, .fileInfo, .xmodemPacket, .deviceuiConfig, .lockdownStatus:
                addEvent(title: "FromRadio", subtitle: "Payload \(String(describing: fromRadio.payloadVariant))", details: String(describing: fromRadio))

            case .none:
                addEvent(title: "FromRadio", subtitle: "Payload vuoto", details: String(describing: fromRadio))
            }
        } catch {
            addEvent(title: "Pacchetto non decodificato", subtitle: "\(data.count) byte", details: error.localizedDescription)
        }
    }

    private func upsertNode(from nodeInfo: NodeInfo) {
        var node = nodesByID[nodeInfo.num] ?? MeshNodeSnapshot(num: nodeInfo.num)
        if nodeInfo.hasUser {
            applyUser(nodeInfo.user, to: &node)
        }
        node.snr = nodeInfo.snr
        node.lastHeard = nodeInfo.lastHeard
        node.viaMqtt = nodeInfo.viaMqtt
        if nodeInfo.hasHopsAway { node.hopsAway = nodeInfo.hopsAway }
        if nodeInfo.hasPosition { applyPosition(nodeInfo.position, to: &node) }
        if nodeInfo.hasDeviceMetrics { applyDeviceMetrics(nodeInfo.deviceMetrics, to: &node) }
        nodesByID[node.num] = node
        meshNodes = nodesByID.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func handleMeshPacket(_ packet: MeshPacket) {
        let from = packet.from
        var node = nodesByID[from] ?? MeshNodeSnapshot(num: from)
        node.rssi = packet.rxRssi
        node.snr = packet.rxSnr == 0 ? node.snr : packet.rxSnr

        switch packet.payloadVariant {
        case .decoded(let decoded):
            switch decoded.portnum {
            case .textMessageApp:
                let text = String(data: decoded.payload, encoding: .utf8) ?? "<testo non UTF-8>"
                addEvent(title: "Messaggio", subtitle: "\(UInt64(from).hexNodeID) -> \(UInt64(packet.to).hexNodeID)", details: text)

            case .positionApp:
                if let position = try? Position(serializedBytes: decoded.payload) {
                    applyPosition(position, to: &node)
                    addEvent(title: "Posizione", subtitle: UInt64(from).hexNodeID, details: String(describing: position))
                }

            case .nodeinfoApp:
                if let user = try? User(serializedBytes: decoded.payload) {
                    applyUser(user, to: &node)
                    addEvent(title: "User info", subtitle: user.longName.isEmpty ? UInt64(from).hexNodeID : user.longName, details: String(describing: user))
                }

            case .telemetryApp:
                if let telemetry = try? Telemetry(serializedBytes: decoded.payload) {
                    applyTelemetry(telemetry, nodeNum: from, node: &node)
                    addEvent(title: "Telemetry", subtitle: UInt64(from).hexNodeID, details: String(describing: telemetry))
                }

            default:
                addEvent(title: "Mesh packet", subtitle: String(describing: decoded.portnum), details: String(describing: packet))
            }

        case .encrypted(let encrypted):
            addEvent(title: "Pacchetto criptato", subtitle: "\(encrypted.count) byte da \(UInt64(from).hexNodeID)", details: String(describing: packet))

        case .none:
            addEvent(title: "Mesh packet", subtitle: "Payload vuoto", details: String(describing: packet))
        }

        nodesByID[from] = node
        meshNodes = nodesByID.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func applyUser(_ user: User, to node: inout MeshNodeSnapshot) {
        node.longName = user.longName
        node.shortName = user.shortName
        node.userID = user.id
        node.hardware = String(describing: user.hwModel)
        node.role = String(describing: user.role)
    }

    private func applyPosition(_ position: Position, to node: inout MeshNodeSnapshot) {
        if position.hasLatitudeI { node.latitude = Double(position.latitudeI) * 1e-7 }
        if position.hasLongitudeI { node.longitude = Double(position.longitudeI) * 1e-7 }
        if position.hasAltitude { node.altitude = position.altitude }
    }

    private func applyDeviceMetrics(_ metrics: DeviceMetrics, to node: inout MeshNodeSnapshot) {
        if metrics.hasBatteryLevel { node.batteryLevel = metrics.batteryLevel }
        if metrics.hasVoltage { node.voltage = metrics.voltage }
        if metrics.hasChannelUtilization { node.channelUtilization = metrics.channelUtilization }
        if metrics.hasAirUtilTx { node.airUtilTx = metrics.airUtilTx }
        if metrics.hasUptimeSeconds { node.uptimeSeconds = metrics.uptimeSeconds }
    }

    private func applyTelemetry(_ telemetryPacket: Telemetry, nodeNum: UInt32, node: inout MeshNodeSnapshot) {
        var rows: [InfoRow] = []

        switch telemetryPacket.variant {
        case .deviceMetrics(let metrics):
            applyDeviceMetrics(metrics, to: &node)
            if metrics.hasBatteryLevel { rows.append(InfoRow(title: "Batteria", value: "\(metrics.batteryLevel)%", systemImage: "battery.75percent")) }
            if metrics.hasVoltage { rows.append(InfoRow(title: "Voltaggio", value: String(format: "%.2f V", metrics.voltage), systemImage: "bolt")) }
            if metrics.hasChannelUtilization { rows.append(InfoRow(title: "Canale", value: String(format: "%.1f%%", metrics.channelUtilization), systemImage: "waveform.path.ecg")) }
            if metrics.hasAirUtilTx { rows.append(InfoRow(title: "Air TX", value: String(format: "%.1f%%", metrics.airUtilTx), systemImage: "antenna.radiowaves.left.and.right")) }
            if metrics.hasUptimeSeconds { rows.append(InfoRow(title: "Uptime", value: formatDuration(metrics.uptimeSeconds), systemImage: "timer")) }

        case .environmentMetrics(let env):
            rows.append(contentsOf: [
                InfoRow(title: "Temperatura", value: String(format: "%.1f C", env.temperature), systemImage: "thermometer.medium"),
                InfoRow(title: "Umidita", value: String(format: "%.1f%%", env.relativeHumidity), systemImage: "humidity"),
                InfoRow(title: "Pressione", value: String(format: "%.1f hPa", env.barometricPressure), systemImage: "barometer")
            ])

        case .airQualityMetrics(let air):
            rows.append(InfoRow(title: "Qualita aria", value: String(describing: air), systemImage: "aqi.medium"))

        case .powerMetrics(let power):
            rows.append(InfoRow(title: "Power", value: String(describing: power), systemImage: "powerplug"))

        case .localStats(let stats):
            rows.append(InfoRow(title: "Local stats", value: String(describing: stats), systemImage: "chart.bar"))

        case .healthMetrics(let health):
            rows.append(InfoRow(title: "Health", value: String(describing: health), systemImage: "heart.text.square"))

        case .hostMetrics(let host):
            rows.append(InfoRow(title: "Host", value: String(describing: host), systemImage: "server.rack"))

        case .trafficManagementStats(let traffic):
            rows.append(InfoRow(title: "Traffic", value: String(describing: traffic), systemImage: "point.3.connected.trianglepath.dotted"))

        case .none:
            rows.append(InfoRow(title: "Telemetry", value: "Payload vuoto", systemImage: "sensor"))
        }

        telemetryByNode[nodeNum] = TelemetrySnapshot(nodeNum: nodeNum, title: node.title, rows: rows)
        telemetry = telemetryByNode.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func metadataConnectivity(_ metadata: DeviceMetadata) -> String {
        var parts: [String] = []
        if metadata.hasBluetooth_p { parts.append("Bluetooth") }
        if metadata.hasWifi_p { parts.append("Wi-Fi") }
        if metadata.hasEthernet_p { parts.append("Ethernet") }
        if metadata.canShutdown { parts.append("shutdown") }
        return parts.isEmpty ? "Non dichiarata" : parts.joined(separator: ", ")
    }

    private func formatDuration(_ seconds: UInt32) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return "\(hours)h \(minutes)m"
    }

    private func stringValue(from data: Data?) -> String {
        guard let data else { return "" }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)) ?? ""
    }
}

extension MeshtasticBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        statusText = bluetoothStateText
        if central.state == .poweredOn {
            startScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Dispositivo senza nome"
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isMeshtastic = advertised.contains(meshServiceUUID) || name.localizedCaseInsensitiveContains("meshtastic")
        guard isMeshtastic || scanAllDevices else { return }

        peripherals[peripheral.identifier] = peripheral
        let detail = isMeshtastic ? "Meshtastic BLE" : "BLE generico"
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, details: detail)

        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }
        discoveredDevices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectedDeviceName = peripheral.name ?? connectedDeviceName
        statusText = "Scopro servizi BLE"
        peripheral.discoverServices([meshServiceUUID, deviceInfoServiceUUID, batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        statusText = error?.localizedDescription ?? "Connessione fallita"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        currentPeripheral = nil
        statusText = error == nil ? "Disconnesso" : "Disconnesso: \(error?.localizedDescription ?? "errore")"
    }
}

extension MeshtasticBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusText = "Errore servizi: \(error.localizedDescription)"
            return
        }

        peripheral.services?.forEach { service in
            switch service.uuid {
            case meshServiceUUID:
                peripheral.discoverCharacteristics([fromRadioUUID, toRadioUUID, fromNumUUID, logRecordUUID, rawLogUUID], for: service)
            case deviceInfoServiceUUID, batteryServiceUUID:
                peripheral.discoverCharacteristics(nil, for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            statusText = "Errore caratteristiche: \(error.localizedDescription)"
            return
        }

        service.characteristics?.forEach { characteristic in
            switch characteristic.uuid {
            case fromRadioUUID:
                fromRadioCharacteristic = characteristic
            case toRadioUUID:
                toRadioCharacteristic = characteristic
            case fromNumUUID:
                fromNumCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case logRecordUUID, rawLogUUID:
                peripheral.setNotifyValue(true, for: characteristic)
            case batteryLevelUUID:
                peripheral.readValue(for: characteristic)
            default:
                if service.uuid == deviceInfoServiceUUID {
                    peripheral.readValue(for: characteristic)
                }
            }
        }

        requestConfigIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusText = "Scrittura fallita: \(error.localizedDescription)"
            return
        }
        if characteristic.uuid == toRadioUUID {
            drainFromRadio()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            statusText = "Lettura fallita: \(error.localizedDescription)"
            return
        }

        switch characteristic.uuid {
        case fromRadioUUID:
            let data = characteristic.value ?? Data()
            handleFromRadioData(data)
            if !data.isEmpty {
                drainFromRadio()
            }

        case fromNumUUID:
            addEvent(title: "FromNum", subtitle: "Nuovi pacchetti disponibili", details: characteristic.value?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "")
            drainFromRadio()

        case logRecordUUID:
            if let data = characteristic.value, let log = try? LogRecord(serializedBytes: data) {
                addEvent(title: "Log firmware", subtitle: log.source, details: log.message)
            }

        case rawLogUUID:
            addEvent(title: "Raw log", subtitle: "Firmware", details: stringValue(from: characteristic.value))

        case batteryLevelUUID:
            if let level = characteristic.value?.first {
                setInfo("Batteria BLE", value: "\(level)%", systemImage: "battery.75percent")
            }

        default:
            if let service = characteristic.service, service.uuid == deviceInfoServiceUUID {
                let title = gattInfoTitle(for: characteristic.uuid)
                setInfo(title, value: stringValue(from: characteristic.value), systemImage: "info.circle")
            }
        }
    }

    private func gattInfoTitle(for uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case "2A24": return "Modello"
        case "2A25": return "Seriale"
        case "2A26": return "Firmware BLE"
        case "2A27": return "Hardware"
        case "2A28": return "Software"
        case "2A29": return "Produttore"
        case "2A50": return "PnP ID"
        default: return "GATT \(uuid.uuidString)"
        }
    }
}
