//
//  HostNameResolver.swift
//  Chicken Fork
//
//  6-rung concurrent hostname resolution ladder for scanned LAN IP addresses.
//  Ported from DeskVNC's vnc-discovery crate (resolve.rs, dnsmsg.rs, netbios.rs, msrpc.rs).
//

import Darwin
import Foundation

enum NameSource: Int, Comparable {
    case mdnsPtr = 0
    case reverseDns = 1
    case netBios = 2
    case llmnr = 3
    case msrpcEndpoint = 4
    case rdpCertificate = 5

    static func < (lhs: NameSource, rhs: NameSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HostNameResolver {
    static let resolveBudgetMs: Int = 500
    private static let retryAfterMs: Int = 180
    private static let maxHostnameLen = 128

    /// Resolve `ipAddr` over all 6 rungs concurrently within `resolveBudgetMs`.
    /// Reuses `sharedCertCN` if the RDP probe already read the TLS certificate CN.
    static func resolve(ipAddr: UInt32, sharedCertCN: String?) async -> String? {
        let ipStr = SubnetScanner.ipString(ipAddr)
        let deadline = Date().addingTimeInterval(Double(resolveBudgetMs) / 1000.0)

        return await withTaskGroup(of: (NameSource, String?).self) { group in
            group.addTask { (.mdnsPtr, mdnsReversePtr(ipAddr: ipAddr, ipStr: ipStr, deadline: deadline)) }
            group.addTask { (.reverseDns, unicastReversePtr(ipAddr: ipAddr, ipStr: ipStr, deadline: deadline)) }
            group.addTask { (.netBios, netbiosNodeStatus(ipAddr: ipAddr, ipStr: ipStr, deadline: deadline)) }
            group.addTask { (.llmnr, llmnrReversePtr(ipAddr: ipAddr, ipStr: ipStr, deadline: deadline)) }
            group.addTask { (.msrpcEndpoint, msrpcEndpointName(ipAddr: ipAddr, ipStr: ipStr, deadline: deadline)) }
            group.addTask {
                if let cn = sharedCertCN, let clean = sanitizeHostname(cn, ipStr: ipStr) {
                    return (.rdpCertificate, clean)
                }
                return (.rdpCertificate, rdpCertificateName(ipAddr: ipAddr, ipStr: ipStr, deadline: deadline))
            }

            var best: (NameSource, String)? = nil
            for await (source, name) in group {
                guard let name else { continue }
                if let current = best {
                    if source < current.0 {
                        best = (source, name)
                    }
                } else {
                    best = (source, name)
                }
            }
            return best?.1
        }
    }

    static func sanitizeHostname(_ raw: String, ipStr: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".local") {
            name = String(name.dropLast(6))
        }
        guard !name.isEmpty, name.count <= maxHostnameLen else { return nil }
        guard name.utf8.allSatisfy({ ($0 >= 0x21 && $0 < 0x7F) && $0 != UInt8(ascii: "/") && $0 != UInt8(ascii: "\\") }) else {
            return nil
        }
        if name == ipStr { return nil }
        var addr4 = in_addr()
        var addr6 = in6_addr()
        if inet_pton(AF_INET, name, &addr4) == 1 || inet_pton(AF_INET6, name, &addr6) == 1 {
            return nil
        }
        return name
    }

    // MARK: - Rung 1 & 4: mDNS / LLMNR Reverse PTR

    private static func mdnsReversePtr(ipAddr: UInt32, ipStr: String, deadline: Date) -> String? {
        let id = randomTxId()
        let qname = reversePtrQName(ipAddr: ipAddr)
        let query = buildDnsQuery(id: id, qname: qname, qtype: 12, qclass: 1) // PTR, IN
        let mcastIP: UInt32 = (224 << 24) | (0 << 16) | (0 << 8) | 251 // 224.0.0.251
        guard let reply = udpQuery(targetIP: ipAddr, destIP: mcastIP, destPort: 5353, query: query, multicastTTL: 255, deadline: deadline),
              let ptrName = firstPtrAnswer(msg: reply, expectedId: id)
        else { return nil }
        return sanitizeHostname(ptrName, ipStr: ipStr)
    }

    private static func llmnrReversePtr(ipAddr: UInt32, ipStr: String, deadline: Date) -> String? {
        let id = randomTxId()
        let qname = reversePtrQName(ipAddr: ipAddr)
        let query = buildDnsQuery(id: id, qname: qname, qtype: 12, qclass: 1) // PTR, IN
        let mcastIP: UInt32 = (224 << 24) | (0 << 16) | (0 << 8) | 252 // 224.0.0.252
        guard let reply = udpQuery(targetIP: ipAddr, destIP: mcastIP, destPort: 5355, query: query, multicastTTL: 1, deadline: deadline),
              let ptrName = firstPtrAnswer(msg: reply, expectedId: id)
        else { return nil }
        return sanitizeHostname(ptrName, ipStr: ipStr)
    }

    // MARK: - Rung 2: Unicast Reverse DNS (getnameinfo)

    private static func unicastReversePtr(ipAddr: UInt32, ipStr: String, deadline: Date) -> String? {
        // Run getnameinfo with a bounded semaphore wait so a slow DNS server never blocks past budget.
        let sem = DispatchSemaphore(value: 0)
        var resolved: String? = nil

        DispatchQueue.global(qos: .utility).async {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_addr = in_addr(s_addr: ipAddr.bigEndian)

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = withUnsafePointer(to: &sin) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NAMEREQD)
                }
            }
            if err == 0 {
                resolved = String(cString: hostBuf)
            }
            sem.signal()
        }

        let remaining = max(0.01, deadline.timeIntervalSinceNow)
        if sem.wait(timeout: .now() + remaining) == .success, let name = resolved {
            return sanitizeHostname(name, ipStr: ipStr)
        }
        return nil
    }

    // MARK: - Rung 3: NetBIOS Node Status (UDP 137)

    private static func netbiosNodeStatus(ipAddr: UInt32, ipStr: String, deadline: Date) -> String? {
        let id = randomTxId()
        // Encode wildcard '*' padded with 15 NULs into 32-byte first-level NetBIOS name
        var raw = [UInt8](repeating: 0, count: 16)
        raw[0] = UInt8(ascii: "*")
        var qname = [UInt8]()
        qname.reserveCapacity(34)
        qname.append(32)
        for byte in raw {
            qname.append((byte >> 4) + UInt8(ascii: "A"))
            qname.append((byte & 0x0F) + UInt8(ascii: "A"))
        }
        qname.append(0)

        let query = buildDnsQuery(id: id, qname: qname, qtype: 0x0021, qclass: 1) // NBSTAT, IN
        guard let reply = udpQuery(targetIP: ipAddr, destIP: ipAddr, destPort: 137, query: query, multicastTTL: nil, deadline: deadline) else {
            return nil
        }
        guard let rdata = findAnswerRData(msg: reply, expectedId: id, rtype: 0x0021),
              let countByte = rdata.first
        else { return nil }

        let count = Int(countByte)
        guard count <= 64 else { return nil }
        let tableEnd = 1 + count * 18
        guard rdata.count >= tableEnd else { return nil }

        for i in 0..<count {
            let entryStart = 1 + i * 18
            let flags = (UInt16(rdata[entryStart + 16]) << 8) | UInt16(rdata[entryStart + 17])
            if (flags & 0x8000) != 0 { continue } // Skip group names

            let nameSlice = rdata[entryStart..<(entryStart + 15)]
            var endIdx = nameSlice.endIndex
            while endIdx > nameSlice.startIndex {
                let prev = nameSlice.index(before: endIdx)
                if nameSlice[prev] == 0x20 || nameSlice[prev] == 0x00 {
                    endIdx = prev
                } else {
                    break
                }
            }
            let trimmed = nameSlice[nameSlice.startIndex..<endIdx]
            if !trimmed.isEmpty,
               trimmed.allSatisfy({ $0 >= 0x21 && $0 < 0x7F }),
               let rawName = String(bytes: trimmed, encoding: .ascii),
               let clean = sanitizeHostname(rawName, ipStr: ipStr) {
                return clean
            }
        }
        return nil
    }

    // MARK: - Rung 5: MSRPC Endpoint Mapper (TCP 135)

    private static func msrpcEndpointName(ipAddr: UInt32, ipStr: String, deadline: Date) -> String? {
        let remainingMs = Int32(max(20, deadline.timeIntervalSinceNow * 1000.0))
        guard let fd = SubnetScanner.connectTCP(ipAddr: ipAddr, port: 135, timeoutMs: remainingMs) else {
            return nil
        }
        defer { Darwin.close(fd) }

        let bindPdu = msrpcBindPdu()
        guard SubnetScanner.writeAll(fd: fd, bytes: bindPdu, timeoutMs: 150) else { return nil }

        guard let bindAck = SubnetScanner.readBytes(fd: fd, maxBytes: 1024, timeoutMs: 200),
              bindAck.count >= 16, bindAck[0] == 5, bindAck[2] == 12 // PTYPE_BIND_ACK
        else { return nil }

        let lookupPdu = msrpcEptLookupPdu()
        guard SubnetScanner.writeAll(fd: fd, bytes: lookupPdu, timeoutMs: 150) else { return nil }

        var reply = [UInt8]()
        let maxRead = 96 * 1024
        while reply.count < maxRead {
            let rem = Int32(max(10, deadline.timeIntervalSinceNow * 1000.0))
            guard let chunk = SubnetScanner.readBytes(fd: fd, maxBytes: 8192, timeoutMs: rem) else {
                break
            }
            if reply.isEmpty && chunk.count >= 16 && chunk[0] == 5 && chunk[2] == 3 {
                return nil // PTYPE_FAULT
            }
            reply.append(contentsOf: chunk)
            if let found = findMsrpcServerName(in: reply),
               let clean = sanitizeHostname(found, ipStr: ipStr) {
                return clean
            }
            if Date() >= deadline { break }
        }
        return nil
    }

    private static func msrpcHeader(ptype: UInt8, fragLen: UInt16, callId: UInt32) -> [UInt8] {
        var h: [UInt8] = [5, 0, ptype, 0x03, 0x10, 0x00, 0x00, 0x00]
        h.append(UInt8(fragLen & 0xFF))
        h.append(UInt8(fragLen >> 8))
        h.append(contentsOf: [0x00, 0x00]) // auth_length = 0
        h.append(UInt8(callId & 0xFF))
        h.append(UInt8((callId >> 8) & 0xFF))
        h.append(UInt8((callId >> 16) & 0xFF))
        h.append(UInt8((callId >> 24) & 0xFF))
        return h
    }

    private static func msrpcBindPdu() -> [UInt8] {
        let epmUUID: [UInt8] = [0x08, 0x83, 0xaf, 0xe1, 0x1f, 0x5d, 0xc9, 0x11, 0x91, 0xa4, 0x08, 0x00, 0x2b, 0x14, 0xa0, 0xfa]
        let ndrUUID: [UInt8] = [0x04, 0x5d, 0x88, 0x8a, 0xeb, 0x1c, 0xc9, 0x11, 0x9f, 0xe8, 0x08, 0x00, 0x2b, 0x10, 0x48, 0x60]

        var body: [UInt8] = [
            0xd0, 0x16, 0xd0, 0x16, // max_xmit=5840, max_recv=5840
            0x00, 0x00, 0x00, 0x00, // assoc_group_id
            0x01, 0x00, 0x00, 0x00, // n_context_elem=1, reserved
            0x00, 0x00, 0x01, 0x00  // p_cont_id=0, n_transfer_syn=1, reserved=0
        ]
        body.append(contentsOf: epmUUID)
        body.append(contentsOf: [0x03, 0x00, 0x00, 0x00]) // v3.0
        body.append(contentsOf: ndrUUID)
        body.append(contentsOf: [0x02, 0x00, 0x00, 0x00]) // NDR v2

        var pdu = msrpcHeader(ptype: 11, fragLen: UInt16(16 + body.count), callId: 1)
        pdu.append(contentsOf: body)
        return pdu
    }

    private static func msrpcEptLookupPdu() -> [UInt8] {
        var stub = [UInt8](repeating: 0, count: 40)
        // max_entries = 500 (0x01F4) at offset 36
        stub[36] = 0xf4
        stub[37] = 0x01

        var pdu = msrpcHeader(ptype: 0, fragLen: UInt16(16 + 8 + stub.count), callId: 2)
        let allocHint = UInt32(stub.count)
        pdu.append(UInt8(allocHint & 0xFF))
        pdu.append(UInt8((allocHint >> 8) & 0xFF))
        pdu.append(UInt8((allocHint >> 16) & 0xFF))
        pdu.append(UInt8((allocHint >> 24) & 0xFF))
        pdu.append(contentsOf: [0x00, 0x00, 0x02, 0x00]) // p_cont_id=0, opnum=2 (ept_lookup)
        pdu.append(contentsOf: stub)
        return pdu
    }

    private static func findMsrpcServerName(in buf: [UInt8]) -> String? {
        var at = 0
        while at + 2 < buf.count {
            if buf[at] == UInt8(ascii: "\\") && buf[at + 1] == UInt8(ascii: "\\") {
                let start = at + 2
                var end = start
                while end < buf.count && end - start <= 15 {
                    let b = buf[end]
                    if b == 0 {
                        if end > start {
                            let first = buf[start]
                            let isFirstAlnum = (first >= 0x30 && first <= 0x39) || (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)
                            if isFirstAlnum, let s = String(bytes: buf[start..<end], encoding: .ascii) {
                                return s
                            }
                        }
                        break
                    }
                    let isLegal = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
                    if !isLegal { break }
                    end += 1
                }
            }
            at += 1
        }
        return nil
    }

    // MARK: - Rung 6: RDP TLS Certificate CN Fallback

    private static func rdpCertificateName(ipAddr: UInt32, ipStr: String, deadline: Date) -> String? {
        let rem = Int32(max(20, deadline.timeIntervalSinceNow * 1000.0))
        guard let fd = SubnetScanner.connectTCP(ipAddr: ipAddr, port: SubnetScanner.rdpPort, timeoutMs: rem) else {
            return nil
        }
        defer { Darwin.close(fd) }
        guard let cn = SubnetScanner.readTlsCertificateCN(fd: fd, timeoutMs: rem) else { return nil }
        return sanitizeHostname(cn, ipStr: ipStr)
    }

    // MARK: - UDP & DNS Wire Helpers

    private static func randomTxId() -> UInt16 {
        let id = UInt16.random(in: 1...UInt16.max)
        return id
    }

    private static func udpQuery(
        targetIP: UInt32,
        destIP: UInt32,
        destPort: UInt16,
        query: [UInt8],
        multicastTTL: UInt8?,
        deadline: Date
    ) -> [UInt8]? {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        if var ttl = multicastTTL {
            _ = Darwin.setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        }

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = destPort.bigEndian
        dest.sin_addr = in_addr(s_addr: destIP.bigEndian)

        let sendOnce: () -> Bool = {
            query.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                return withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.sendto(fd, base, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == query.count
                    }
                }
            }
        }

        guard sendOnce() else { return nil }

        let retryAt = Date().addingTimeInterval(Double(retryAfterMs) / 1000.0)
        var resent = false
        var recvBuf = [UInt8](repeating: 0, count: 1500)

        while true {
            let until = resent ? deadline : min(deadline, retryAt)
            let waitMs = Int32(max(1, until.timeIntervalSinceNow * 1000.0))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pfd, 1, waitMs)

            if ready > 0 {
                var src = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &src) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.recvfrom(fd, &recvBuf, recvBuf.count, 0, sa, &srcLen)
                    }
                }
                if n > 0 && UInt32(bigEndian: src.sin_addr.s_addr) == targetIP {
                    return Array(recvBuf[0..<n])
                }
            } else if ready == 0 {
                if resent || Date() >= deadline { return nil }
                resent = true
                if !sendOnce() { return nil }
            } else {
                return nil
            }
        }
    }

    private static func reversePtrQName(ipAddr: UInt32) -> [UInt8] {
        let b0 = (ipAddr >> 24) & 0xFF
        let b1 = (ipAddr >> 16) & 0xFF
        let b2 = (ipAddr >> 8) & 0xFF
        let b3 = ipAddr & 0xFF
        let labels = ["\(b3)", "\(b2)", "\(b1)", "\(b0)", "in-addr", "arpa"]
        var out = [UInt8]()
        for label in labels {
            let bytes = Array(label.utf8)
            out.append(UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(0)
        return out
    }

    private static func buildDnsQuery(id: UInt16, qname: [UInt8], qtype: UInt16, qclass: UInt16) -> [UInt8] {
        var msg = [UInt8]()
        msg.append(UInt8(id >> 8))
        msg.append(UInt8(id & 0xFF))
        msg.append(contentsOf: [0x00, 0x00]) // standard query
        msg.append(contentsOf: [0x00, 0x01]) // QDCOUNT = 1
        msg.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // AN/NS/AR = 0
        msg.append(contentsOf: qname)
        msg.append(UInt8(qtype >> 8))
        msg.append(UInt8(qtype & 0xFF))
        msg.append(UInt8(qclass >> 8))
        msg.append(UInt8(qclass & 0xFF))
        return msg
    }

    private static func firstPtrAnswer(msg: [UInt8], expectedId: UInt16) -> String? {
        guard let rdata = findAnswerRData(msg: msg, expectedId: expectedId, rtype: 12),
              let offset = findAnswerRDataOffset(msg: msg, expectedId: expectedId, rtype: 12)
        else { return nil }
        _ = rdata
        return readDnsName(msg: msg, startOffset: offset)
    }

    private static func findAnswerRData(msg: [UInt8], expectedId: UInt16, rtype: UInt16) -> [UInt8]? {
        guard let offset = findAnswerRDataOffset(msg: msg, expectedId: expectedId, rtype: rtype) else {
            return nil
        }
        let rdlen = (Int(msg[offset - 2]) << 8) | Int(msg[offset - 1])
        guard offset + rdlen <= msg.count else { return nil }
        return Array(msg[offset..<(offset + rdlen)])
    }

    private static func findAnswerRDataOffset(msg: [UInt8], expectedId: UInt16, rtype: UInt16) -> Int? {
        guard msg.count >= 12 else { return nil }
        let msgId = (UInt16(msg[0]) << 8) | UInt16(msg[1])
        guard msgId == expectedId else { return nil }
        let flags = (UInt16(msg[2]) << 8) | UInt16(msg[3])
        guard (flags & 0x8000) != 0 else { return nil } // QR = response

        let qdCount = (Int(msg[4]) << 8) | Int(msg[5])
        let anCount = (Int(msg[6]) << 8) | Int(msg[7])
        guard qdCount <= 16, anCount > 0, anCount <= 64 else { return nil }

        var off = 12
        for _ in 0..<qdCount {
            guard let next = skipDnsName(msg: msg, offset: off) else { return nil }
            off = next + 4
            guard off <= msg.count else { return nil }
        }

        for _ in 0..<anCount {
            guard let next = skipDnsName(msg: msg, offset: off) else { return nil }
            off = next
            guard off + 10 <= msg.count else { return nil }
            let rrType = (UInt16(msg[off]) << 8) | UInt16(msg[off + 1])
            let rdLen = (Int(msg[off + 8]) << 8) | Int(msg[off + 9])
            off += 10
            guard off + rdLen <= msg.count else { return nil }
            if rrType == rtype {
                return off
            }
            off += rdLen
        }
        return nil
    }

    private static func skipDnsName(msg: [UInt8], offset: Int) -> Int? {
        var off = offset
        var steps = 0
        while off < msg.count && steps < 128 {
            steps += 1
            let len = msg[off]
            if len == 0 {
                return off + 1
            } else if (len & 0xC0) == 0xC0 {
                guard off + 2 <= msg.count else { return nil }
                return off + 2
            } else {
                off += 1 + Int(len)
            }
        }
        return nil
    }

    private static func readDnsName(msg: [UInt8], startOffset: Int) -> String? {
        var off = startOffset
        var labels = [String]()
        var jumps = 0
        while off < msg.count && jumps < 16 {
            let len = msg[off]
            if len == 0 {
                return labels.joined(separator: ".")
            } else if (len & 0xC0) == 0xC0 {
                guard off + 1 < msg.count else { return nil }
                let ptr = (Int(len & 0x3F) << 8) | Int(msg[off + 1])
                guard ptr < msg.count else { return nil }
                off = ptr
                jumps += 1
            } else {
                off += 1
                guard off + Int(len) <= msg.count else { return nil }
                if let label = String(bytes: msg[off..<(off + Int(len))], encoding: .utf8) {
                    labels.append(label)
                }
                off += Int(len)
            }
        }
        return nil
    }
}
