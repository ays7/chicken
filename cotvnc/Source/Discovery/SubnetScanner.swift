//
//  SubnetScanner.swift
//  Chicken Fork
//
//  Polite, rate-limited active IPv4 subnet scanner for RDP (TCP 3389).
//  Ported from DeskVNC's vnc-discovery crate.
//
//  NOTE: Active VNC probing (5900-5909) is deliberately omitted: VNC is
//  unencrypted by default and should not be exposed via active network sweeps.
//

import Darwin
import Foundation
import Security

struct LocalSubnet: Hashable {
    let network: UInt32
    let prefix: Int
    let cidr: String
    let hostCount: Int

    func hosts() -> [UInt32] {
        guard prefix >= 16 && prefix <= 30 else { return [] }
        let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
        let net = network & mask
        let broadcast = net | ~mask
        guard broadcast > net + 1 else { return [] }
        return Array((net + 1)..<broadcast)
    }
}

struct RdpProbeHit {
    let ip: String
    let ipAddr: UInt32
    let port: UInt16
    let certCN: String?
}

enum SubnetScanner {
    static let rdpPort: UInt16 = 3389
    static let maxScanPrefix = 16
    static let confirmThresholdHosts = 1022 // > /22

    private static let excludedInterfacePrefixes = [
        "lo", "utun", "ipsec", "ppp", "bridge", "awdl", "llw", "anpi", "ap", "gif", "stf"
    ]

    /// Enumerate safe local private IPv4 subnets and this machine's own IPv4 addresses.
    static func detectLocalNetwork() -> (subnets: [LocalSubnet], localIPs: Set<UInt32>) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return ([], [])
        }
        defer { freeifaddrs(ifaddrPtr) }

        var localIPs = Set<UInt32>()
        var seenSubnets = Set<LocalSubnet>()
        var subnets = [LocalSubnet]()

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let iface = current.pointee
            ptr = iface.ifa_next

            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = Int32(iface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0 else {
                continue
            }

            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
            localIPs.insert(ip)

            if (flags & IFF_LOOPBACK) != 0 { continue }

            let name = String(cString: iface.ifa_name)
            if excludedInterfacePrefixes.contains(where: { name.hasPrefix($0) }) {
                continue
            }

            guard isPrivateIPv4(ip), !isLinkLocalIPv4(ip) else {
                continue
            }

            guard let maskAddr = iface.ifa_netmask else { continue }
            let maskSin = maskAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = UInt32(bigEndian: maskSin.sin_addr.s_addr)
            let prefix = mask.nonzeroBitCount

            guard prefix >= maxScanPrefix && prefix <= 30 else { continue }

            let network = ip & mask
            let hostCount = max(0, (1 << (32 - prefix)) - 2)
            let cidr = "\(ipString(network))/\(prefix)"
            let subnet = LocalSubnet(network: network, prefix: prefix, cidr: cidr, hostCount: hostCount)
            if seenSubnets.insert(subnet).inserted {
                subnets.append(subnet)
            }
        }

        return (subnets, localIPs)
    }

    static func isPrivateIPv4(_ ip: UInt32) -> Bool {
        let b0 = (ip >> 24) & 0xFF
        let b1 = (ip >> 16) & 0xFF
        if b0 == 10 { return true }
        if b0 == 172 && (16...31).contains(b1) { return true }
        if b0 == 192 && b1 == 168 { return true }
        if b0 == 100 && (64...127).contains(b1) { return true } // CGNAT 100.64.0.0/10
        return false
    }

    static func isLinkLocalIPv4(_ ip: UInt32) -> Bool {
        let b0 = (ip >> 24) & 0xFF
        let b1 = (ip >> 16) & 0xFF
        return b0 == 169 && b1 == 254
    }

    static func ipString(_ ip: UInt32) -> String {
        "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
    }

    /// Probe a single IP on TCP 3389 with an X.224 Connection Request (SSL | HYBRID).
    /// Reads X.224 Connection Confirm and, if TLS/NLA is selected, reads the TLS Certificate CN
    /// on the same socket before closing (zero authentication).
    static func probeRdp(ipAddr: UInt32, timeoutMs: Int32 = 500) -> RdpProbeHit? {
        let ipStr = ipString(ipAddr)
        guard let fd = connectTCP(ipAddr: ipAddr, port: rdpPort, timeoutMs: timeoutMs) else {
            return nil
        }
        defer { Darwin.close(fd) }

        // 19-byte TPKT + X.224 Connection Request (PROTOCOL_SSL | PROTOCOL_HYBRID = 0x03)
        let request: [UInt8] = [
            0x03, 0x00, 0x00, 0x13, // TPKT header (version 3, length 19)
            0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, // X.224 CR TPDU
            0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00 // RDP_NEG_REQ (SSL | HYBRID)
        ]
        guard writeAll(fd: fd, bytes: request, timeoutMs: 250) else {
            return nil
        }

        // Read TPKT + X.224 Connection Confirm (<= 19 bytes typically, cap 512)
        guard let confirm = readTpktFrame(fd: fd, maxBytes: 512, timeoutMs: 250),
              confirm.count >= 11,
              confirm[5] == 0xd0 // X.224 Connection Confirm TPDU code
        else {
            return nil
        }

        var certCN: String? = nil
        // Check if RDP_NEG_RSP (type 0x02) selected SSL (0x01) or HYBRID (0x02)
        if confirm.count >= 19 && confirm[11] == 0x02 {
            let selectedProtocol = UInt32(confirm[15])
                | (UInt32(confirm[16]) << 8)
                | (UInt32(confirm[17]) << 16)
                | (UInt32(confirm[18]) << 24)
            if (selectedProtocol & 0x03) != 0 {
                certCN = readTlsCertificateCN(fd: fd, timeoutMs: 700)
            }
        }

        return RdpProbeHit(ip: ipStr, ipAddr: ipAddr, port: rdpPort, certCN: certCN)
    }

    // MARK: - Low-level Non-blocking Socket Helpers

    static func connectTCP(ipAddr: UInt32, port: UInt16, timeoutMs: Int32) -> Int32? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var nosigpipe: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr = in_addr(s_addr: ipAddr.bigEndian)

        let res = withUnsafePointer(to: &sin) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if res != 0 {
            if errno != EINPROGRESS {
                Darwin.close(fd)
                return nil
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&pfd, 1, timeoutMs)
            guard ready > 0, (pfd.revents & Int16(POLLOUT)) != 0 else {
                Darwin.close(fd)
                return nil
            }
            var sockErr: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen)
            if sockErr != 0 {
                Darwin.close(fd)
                return nil
            }
        }

        return fd
    }

    static func writeAll(fd: Int32, bytes: [UInt8], timeoutMs: Int32) -> Bool {
        var sent = 0
        while sent < bytes.count {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&pfd, 1, timeoutMs)
            guard ready > 0 else { return false }

            let n = bytes.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    static func readBytes(fd: Int32, maxBytes: Int, timeoutMs: Int32) -> [UInt8]? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&pfd, 1, timeoutMs)
        guard ready > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.recv(fd, &buf, maxBytes, 0)
        guard n > 0 else { return nil }
        return Array(buf[0..<n])
    }

    private static func readTpktFrame(fd: Int32, maxBytes: Int, timeoutMs: Int32) -> [UInt8]? {
        var buf = [UInt8]()
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while buf.count < maxBytes {
            let remainingMs = Int32(max(10, deadline.timeIntervalSinceNow * 1000.0))
            guard let chunk = readBytes(fd: fd, maxBytes: min(256, maxBytes - buf.count), timeoutMs: remainingMs) else {
                break
            }
            buf.append(contentsOf: chunk)
            if buf.count >= 4 {
                guard buf[0] == 0x03 else { return nil } // TPKT version must be 3
                let totalLen = (Int(buf[2]) << 8) | Int(buf[3])
                guard totalLen >= 7 && totalLen <= maxBytes else { return nil }
                if buf.count >= totalLen {
                    return Array(buf[0..<totalLen])
                }
            }
            if Date() >= deadline { break }
        }
        return nil
    }

    // MARK: - Minimal TLS 1.2 ClientHello + Certificate CN Extractor

    static func readTlsCertificateCN(fd: Int32, timeoutMs: Int32) -> String? {
        let hello = buildTls12ClientHello()
        guard writeAll(fd: fd, bytes: hello, timeoutMs: 250) else { return nil }

        var flight = [UInt8]()
        let maxTlsRead = 16 * 1024
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        while flight.count < maxTlsRead {
            let remainingMs = Int32(max(10, deadline.timeIntervalSinceNow * 1000.0))
            guard let chunk = readBytes(fd: fd, maxBytes: 2048, timeoutMs: remainingMs) else {
                break
            }
            flight.append(contentsOf: chunk)
            if let derCert = extractFirstCertificateDER(from: flight) {
                return extractCommonName(fromDER: derCert)
            }
            if Date() >= deadline { break }
        }
        return nil
    }

    private static func buildTls12ClientHello() -> [UInt8] {
        var random = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &random)

        let suites: [UInt16] = [
            0xc02f, 0xc030, 0xc027, 0xc028, 0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035
        ]
        let groups: [UInt16] = [0x0017, 0x0018, 0x0019]
        let sigAlgs: [UInt16] = [0x0401, 0x0501, 0x0601, 0x0403, 0x0503, 0x0603, 0x0201]

        var body = [UInt8]()
        body.append(contentsOf: [0x03, 0x03]) // TLS 1.2
        body.append(contentsOf: random)
        body.append(0x00) // empty session_id
        let suitesLen = UInt16(suites.count * 2)
        body.append(UInt8(suitesLen >> 8))
        body.append(UInt8(suitesLen & 0xFF))
        for s in suites {
            body.append(UInt8(s >> 8))
            body.append(UInt8(s & 0xFF))
        }
        body.append(contentsOf: [0x01, 0x00]) // null compression

        var ext = [UInt8]()
        // supported_groups (10)
        ext.append(contentsOf: [0x00, 0x0a])
        let gBytes = UInt16(groups.count * 2)
        ext.append(UInt8((gBytes + 2) >> 8))
        ext.append(UInt8((gBytes + 2) & 0xFF))
        ext.append(UInt8(gBytes >> 8))
        ext.append(UInt8(gBytes & 0xFF))
        for g in groups {
            ext.append(UInt8(g >> 8))
            ext.append(UInt8(g & 0xFF))
        }
        // ec_point_formats (11)
        ext.append(contentsOf: [0x00, 0x0b, 0x00, 0x02, 0x01, 0x00])
        // signature_algorithms (13)
        ext.append(contentsOf: [0x00, 0x0d])
        let saBytes = UInt16(sigAlgs.count * 2)
        ext.append(UInt8((saBytes + 2) >> 8))
        ext.append(UInt8((saBytes + 2) & 0xFF))
        ext.append(UInt8(saBytes >> 8))
        ext.append(UInt8(saBytes & 0xFF))
        for sa in sigAlgs {
            ext.append(UInt8(sa >> 8))
            ext.append(UInt8(sa & 0xFF))
        }

        let extLen = UInt16(ext.count)
        body.append(UInt8(extLen >> 8))
        body.append(UInt8(extLen & 0xFF))
        body.append(contentsOf: ext)

        // Handshake header (type 1 = ClientHello, 24-bit length)
        let hsLen = body.count
        var handshake: [UInt8] = [
            0x01,
            UInt8((hsLen >> 16) & 0xFF),
            UInt8((hsLen >> 8) & 0xFF),
            UInt8(hsLen & 0xFF)
        ]
        handshake.append(contentsOf: body)

        // TLS record header (type 22 = handshake, version TLS 1.0 0x0301 for compatibility)
        let recLen = UInt16(handshake.count)
        var record: [UInt8] = [
            0x16, 0x03, 0x01,
            UInt8(recLen >> 8),
            UInt8(recLen & 0xFF)
        ]
        record.append(contentsOf: handshake)
        return record
    }

    private static func extractFirstCertificateDER(from flight: [UInt8]) -> Data? {
        var handshakeStream = [UInt8]()
        var offset = 0
        while offset + 5 <= flight.count {
            let recType = flight[offset]
            let recLen = (Int(flight[offset + 3]) << 8) | Int(flight[offset + 4])
            offset += 5
            guard offset + recLen <= flight.count else { break }
            if recType == 22 { // handshake
                handshakeStream.append(contentsOf: flight[offset..<(offset + recLen)])
            }
            offset += recLen
        }

        var hsOff = 0
        while hsOff + 4 <= handshakeStream.count {
            let hsType = handshakeStream[hsOff]
            let hsLen = (Int(handshakeStream[hsOff + 1]) << 16)
                | (Int(handshakeStream[hsOff + 2]) << 8)
                | Int(handshakeStream[hsOff + 3])
            hsOff += 4
            guard hsOff + hsLen <= handshakeStream.count else { break }
            if hsType == 11 { // Certificate
                // 3 bytes total cert list len + 3 bytes first cert len
                guard hsLen >= 6 else { return nil }
                let firstCertLen = (Int(handshakeStream[hsOff + 3]) << 16)
                    | (Int(handshakeStream[hsOff + 4]) << 8)
                    | Int(handshakeStream[hsOff + 5])
                let certStart = hsOff + 6
                guard certStart + firstCertLen <= hsOff + hsLen, firstCertLen > 0 else { return nil }
                return Data(handshakeStream[certStart..<(certStart + firstCertLen)])
            }
            hsOff += hsLen
        }
        return nil
    }

    private static func extractCommonName(fromDER der: Data) -> String? {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return nil
        }
        var cnRef: CFString?
        let status = SecCertificateCopyCommonName(cert, &cnRef)
        guard status == errSecSuccess, let cn = cnRef as String? else {
            return nil
        }
        return cn
    }
}
