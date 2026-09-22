import Foundation
import Darwin

@_silgen_name("glassmetrics_read_temperature")
private func smcTemperature(_ key: UnsafePointer<CChar>, _ value: UnsafeMutablePointer<Double>) -> Int32
@_silgen_name("glassmetrics_hid_cpu_temperature")
private func hidTemperature() -> Double

final class TemperatureSampler: Sendable {
    // CPU keys adapted from exelban/stats (MIT); only known CPU core sensors are averaged.
    private let keys = ["Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
                        "Tp0P", "Tp0T", "Tp0L", "Tp0X", "Tp0C", "TC0D", "TC0E"]

    func sample() -> Double? {
        let hid = hidTemperature()
        if hid > 0 { return hid }
        var values: [Double] = []
        for key in keys {
            var value = 0.0
            if key.withCString({ smcTemperature($0, &value) }) == 1 { values.append(value) }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
final class NetworkSampler {
    private var previous: (received: UInt64, sent: UInt64, time: TimeInterval)?

    func sample() -> (download: Double, upload: Double)? {
        var cursor: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&cursor) == 0 else { return nil }
        defer { if let cursor { freeifaddrs(cursor) } }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var current = cursor
        while let entry = current?.pointee {
            defer { current = entry.ifa_next }
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0,
                  let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(stats.ifi_ibytes)
            sent += UInt64(stats.ifi_obytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (received, sent, now) }
        guard let previous, now > previous.time,
              received >= previous.received, sent >= previous.sent else { return nil }
        let elapsed = now - previous.time
        return (Double(received - previous.received) / elapsed,
                Double(sent - previous.sent) / elapsed)
    }
}
