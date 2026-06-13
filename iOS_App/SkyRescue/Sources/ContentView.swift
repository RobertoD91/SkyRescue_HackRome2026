import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var meshtastic: MeshtasticBLEManager

    var body: some View {
        NavigationStack {
            Group {
                if meshtastic.isConnected {
                    DashboardView()
                } else {
                    PairingView()
                }
            }
            .navigationTitle("SkyRescue")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if meshtastic.isConnected {
                        Menu {
                            Button {
                                meshtastic.refreshConfig()
                            } label: {
                                Label("Aggiorna dati", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) {
                                meshtastic.disconnect()
                            } label: {
                                Label("Disconnetti", systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }
}

private struct PairingView: View {
    @EnvironmentObject private var meshtastic: MeshtasticBLEManager

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accoppia il tuo Meshtastic")
                            .font(.title2.weight(.semibold))
                        Text(meshtastic.statusText)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button {
                            meshtastic.startScan()
                        } label: {
                            Label(meshtastic.isScanning ? "Scansione attiva" : "Cerca dispositivo", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(meshtastic.isScanning)

                        if meshtastic.isScanning {
                            Button {
                                meshtastic.stopScan()
                            } label: {
                                Image(systemName: "stop.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.vertical, 10)
            }

            Section("Dispositivi vicini") {
                if meshtastic.discoveredDevices.isEmpty {
                    ContentUnavailableView(
                        "Nessun dispositivo",
                        systemImage: "magnifyingglass",
                        description: Text("Accendi il dispositivo Meshtastic e verifica che il Bluetooth sia abilitato.")
                    )
                    Button {
                        meshtastic.startScan(includeAllNamedDevices: true)
                    } label: {
                        Label("Scansione BLE ampia", systemImage: "scope")
                    }
                } else {
                    ForEach(meshtastic.discoveredDevices) { device in
                        Button {
                            meshtastic.connect(to: device)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(.blue)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(device.details) - RSSI \(device.rssi)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var meshtastic: MeshtasticBLEManager
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Vista", selection: $selectedTab) {
                Text("Stato").tag(0)
                Text("Nodi").tag(1)
                Text("Telemetry").tag(2)
                Text("Log").tag(3)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])

            TabView(selection: $selectedTab) {
                StatusView().tag(0)
                NodesView().tag(1)
                TelemetryView().tag(2)
                PacketLogView().tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }
}

private struct StatusView: View {
    @EnvironmentObject private var meshtastic: MeshtasticBLEManager

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meshtastic.connectedDeviceName.isEmpty ? "Dispositivo connesso" : meshtastic.connectedDeviceName)
                            .font(.headline)
                        Text(meshtastic.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            if let myNode = meshtastic.myNode {
                Section("Nodo locale") {
                    LabeledContent("Node ID", value: myNode.nodeHex)
                    LabeledContent("Reboot", value: "\(myNode.rebootCount)")
                    LabeledContent("Min app", value: "\(myNode.minAppVersion)")
                    LabeledContent("NodeDB", value: "\(myNode.nodedbCount)")
                    if !myNode.pioEnv.isEmpty {
                        LabeledContent("Firmware env", value: myNode.pioEnv)
                    }
                }
            }

            Section("Hardware") {
                ForEach(meshtastic.deviceInfo) { row in
                    Label {
                        LabeledContent(row.title, value: row.value)
                    } icon: {
                        Image(systemName: row.systemImage)
                    }
                }
            }
        }
    }
}

private struct NodesView: View {
    @EnvironmentObject private var meshtastic: MeshtasticBLEManager

    var body: some View {
        List {
            if meshtastic.meshNodes.isEmpty {
                ContentUnavailableView("NodeDB vuoto", systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                ForEach(meshtastic.meshNodes) { node in
                    NavigationLink {
                        NodeDetailView(node: node)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.title)
                                .font(.headline)
                            Text(node.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct NodeDetailView: View {
    let node: MeshNodeSnapshot

    var body: some View {
        List {
            Section("Identita") {
                LabeledContent("Node ID", value: UInt64(node.num).hexNodeID)
                if !node.longName.isEmpty { LabeledContent("Nome", value: node.longName) }
                if !node.shortName.isEmpty { LabeledContent("Short", value: node.shortName) }
                if !node.hardware.isEmpty { LabeledContent("Hardware", value: node.hardware) }
                if !node.role.isEmpty { LabeledContent("Ruolo", value: node.role) }
            }

            Section("Radio") {
                LabeledContent("SNR", value: String(format: "%.1f dB", node.snr))
                if node.rssi != 0 { LabeledContent("RSSI", value: "\(node.rssi) dBm") }
                if let hopsAway = node.hopsAway { LabeledContent("Hop", value: "\(hopsAway)") }
                LabeledContent("MQTT", value: node.viaMqtt ? "Si" : "No")
            }

            Section("Metriche") {
                if let batteryLevel = node.batteryLevel { LabeledContent("Batteria", value: "\(batteryLevel)%") }
                if let voltage = node.voltage { LabeledContent("Voltaggio", value: String(format: "%.2f V", voltage)) }
                if let channelUtilization = node.channelUtilization { LabeledContent("Canale", value: String(format: "%.1f%%", channelUtilization)) }
                if let airUtilTx = node.airUtilTx { LabeledContent("Air TX", value: String(format: "%.1f%%", airUtilTx)) }
                if let uptimeSeconds = node.uptimeSeconds { LabeledContent("Uptime", value: "\(uptimeSeconds)s") }
            }

            if let coordinateText = node.coordinateText {
                Section("Posizione") {
                    LabeledContent("Coordinate", value: coordinateText)
                }
            }
        }
        .navigationTitle(node.title)
    }
}

private struct TelemetryView: View {
    @EnvironmentObject private var meshtastic: MeshtasticBLEManager

    var body: some View {
        List {
            if meshtastic.telemetry.isEmpty {
                ContentUnavailableView("Nessuna telemetry", systemImage: "sensor")
            } else {
                ForEach(meshtastic.telemetry) { telemetry in
                    Section(telemetry.title) {
                        ForEach(telemetry.rows) { row in
                            Label {
                                LabeledContent(row.title, value: row.value)
                            } icon: {
                                Image(systemName: row.systemImage)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PacketLogView: View {
    @EnvironmentObject private var meshtastic: MeshtasticBLEManager

    var body: some View {
        List {
            if meshtastic.packetEvents.isEmpty {
                ContentUnavailableView("Nessun pacchetto", systemImage: "doc.text.magnifyingglass")
            } else {
                ForEach(meshtastic.packetEvents) { event in
                    DisclosureGroup {
                        Text(event.details)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title)
                                .font(.headline)
                            Text(event.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
