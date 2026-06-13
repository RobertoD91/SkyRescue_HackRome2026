import Foundation

struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var details: String
}

struct InfoRow: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var value: String
    var systemImage: String
}

struct MyNodeSummary: Hashable {
    var nodeNum: UInt32
    var rebootCount: UInt32
    var minAppVersion: UInt32
    var pioEnv: String
    var nodedbCount: UInt32

    var nodeHex: String {
        UInt64(nodeNum).hexNodeID
    }
}

struct MeshNodeSnapshot: Identifiable, Hashable {
    var id: UInt32 { num }
    var num: UInt32
    var longName: String = ""
    var shortName: String = ""
    var userID: String = ""
    var hardware: String = ""
    var role: String = ""
    var snr: Float = 0
    var rssi: Int32 = 0
    var lastHeard: UInt32 = 0
    var hopsAway: UInt32?
    var batteryLevel: UInt32?
    var voltage: Float?
    var channelUtilization: Float?
    var airUtilTx: Float?
    var uptimeSeconds: UInt32?
    var latitude: Double?
    var longitude: Double?
    var altitude: Int32?
    var viaMqtt: Bool = false

    var title: String {
        if !longName.isEmpty { return longName }
        if !shortName.isEmpty { return shortName }
        return UInt64(num).hexNodeID
    }

    var subtitle: String {
        var parts = [UInt64(num).hexNodeID]
        if let batteryLevel { parts.append("Batteria \(batteryLevel)%") }
        if snr != 0 { parts.append(String(format: "SNR %.1f dB", snr)) }
        if let hopsAway { parts.append(hopsAway == 0 ? "diretto" : "\(hopsAway) hop") }
        return parts.joined(separator: " - ")
    }

    var coordinateText: String? {
        guard let latitude, let longitude else { return nil }
        if let altitude {
            return String(format: "%.5f, %.5f - %dm", latitude, longitude, altitude)
        }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }
}

struct PacketEvent: Identifiable, Hashable {
    let id = UUID()
    var date = Date()
    var title: String
    var subtitle: String
    var details: String
}

struct TelemetrySnapshot: Identifiable, Hashable {
    var id: UInt32 { nodeNum }
    var nodeNum: UInt32
    var title: String
    var rows: [InfoRow]
}

extension UInt64 {
    var hexNodeID: String {
        "!" + String(format: "%08llX", self)
    }
}

extension UInt32 {
    var epochDate: Date? {
        guard self > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(self))
    }
}
