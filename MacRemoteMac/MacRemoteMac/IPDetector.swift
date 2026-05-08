import Foundation
import Darwin

struct DetectedAddress: Identifiable, Equatable {
    var id: String { "\(interface)-\(address)" }
    var label: String     // user-facing ("Tailscale", "Wi-Fi", "Ethernet")
    var interface: String // e.g. "en0", "utun3"
    var address: String   // dotted IPv4
}

enum IPDetector {
    /// Enumerate IPv4 addresses on active interfaces. Filters out loopback
    /// and link-local. Labels Tailscale CGNAT (100.64.0.0/10) explicitly.
    static func detect() -> [DetectedAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        let ret = getifaddrs(&head)
        NSLog("[IPDetector] getifaddrs returned \(ret), head nil=\(head == nil)")
        guard ret == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var out: [DetectedAddress] = []
        var ptr = first
        while true {
            let ifa = ptr.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &hostBuf, socklen_t(hostBuf.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostBuf)
                    NSLog("[IPDetector] found \(name) \(ip) include=\(shouldInclude(name: name, ip: ip))")
                    if shouldInclude(name: name, ip: ip) {
                        out.append(DetectedAddress(label: label(name: name, ip: ip),
                                                   interface: name, address: ip))
                    }
                }
            }
            guard let next = ifa.ifa_next else { break }
            ptr = next
        }
        NSLog("[IPDetector] total: \(out.count)")
        // De-dup, prefer Tailscale → en0 → others
        let order: (DetectedAddress) -> Int = { a in
            if a.label == "Tailscale" { return 0 }
            if a.interface == "en0"   { return 1 }
            if a.interface == "en1"   { return 2 }
            return 3
        }
        return out.sorted { order($0) < order($1) }
    }

    private static func shouldInclude(name: String, ip: String) -> Bool {
        if name == "lo0" { return false }
        if ip.hasPrefix("169.254.") { return false } // link-local
        // Tailscale: utunN with 100.x.x.x CGNAT
        // Wi-Fi/Ethernet: enX
        // Bridge: bridgeX (skip)
        if name.hasPrefix("bridge") || name.hasPrefix("awdl") || name.hasPrefix("llw") { return false }
        return name.hasPrefix("en") || (name.hasPrefix("utun") && isTailscale(ip))
    }

    private static func isTailscale(_ ip: String) -> Bool {
        // 100.64.0.0/10 = 100.64.0.0 .. 100.127.255.255
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func label(name: String, ip: String) -> String {
        if isTailscale(ip) { return "Tailscale" }
        if name == "en0" { return "Wi-Fi" }
        if name.hasPrefix("en") { return "Ethernet" }
        return name
    }
}
