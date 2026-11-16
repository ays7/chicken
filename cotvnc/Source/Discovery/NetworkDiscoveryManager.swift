//
//  NetworkDiscoveryManager.swift
//  Chicken Fork
//
//  Coordinates active LAN subnet scanning for RDP servers and concurrent
//  hostname resolution, bridging events to Objective-C on the main queue.
//

import Foundation

@objc public protocol NetworkDiscoveryDelegate: AnyObject {
    func discoveryDidFindHost(_ address: String, port: UInt16, initialName: String?)
    func discoveryDidUpdateHost(_ address: String, port: UInt16, resolvedName: String)
    func discoveryDidUpdateProgress(_ scanned: Int, total: Int)
    func discoveryDidCompleteWithError(_ error: String?)
}

@objcMembers
public final class NetworkDiscoveryManager: NSObject {
    public static let shared = NetworkDiscoveryManager()

    private let maxConcurrency = 32
    private let maxRatePerSec = 150.0
    private var scanTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var _isScanning = false

    public var isScanning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isScanning
    }

    private func setScanning(_ value: Bool) {
        stateLock.lock()
        _isScanning = value
        stateLock.unlock()
    }

    /// Returns local subnet summary for consent/confirmation UI:
    /// `cidrs`: `[String]`, `totalHosts`: `Int`, `needsConfirmation`: `Bool`
    public func localSubnetsInfo() -> [String: Any] {
        let (subnets, localIPs) = SubnetScanner.detectLocalNetwork()
        let cidrs = subnets.map { $0.cidr }
        var total = 0
        for subnet in subnets {
            for ip in subnet.hosts() where !localIPs.contains(ip) {
                total += 1
            }
        }
        return [
            "cidrs": cidrs,
            "totalHosts": total,
            "needsConfirmation": total > SubnetScanner.confirmThresholdHosts
        ]
    }

    public func startScan(delegate: NetworkDiscoveryDelegate, excludedHosts: [String] = []) {
        stopScan()

        let (subnets, localIPs) = SubnetScanner.detectLocalNetwork()
        var targets = [UInt32]()
        var seen = Set<UInt32>()
        for subnet in subnets {
            for ip in subnet.hosts() where !localIPs.contains(ip) {
                if seen.insert(ip).inserted {
                    targets.append(ip)
                }
            }
        }

        guard !targets.isEmpty else {
            DispatchQueue.main.async {
                delegate.discoveryDidCompleteWithError("No scannable local IPv4 subnets found.")
            }
            return
        }

        setScanning(true)

        scanTask = Task.detached(priority: .utility) { [weak self, weak delegate] in
            guard let self else { return }

            let excludedIPs = Self.resolveIPv4Addresses(for: excludedHosts)
            let filteredTargets = excludedIPs.isEmpty ? targets : targets.filter { !excludedIPs.contains($0) }
            guard !filteredTargets.isEmpty else {
                self.setScanning(false)
                await MainActor.run {
                    delegate?.discoveryDidCompleteWithError(nil)
                }
                return
            }
            let total = filteredTargets.count

            let minGapNs = UInt64(1_000_000_000.0 / self.maxRatePerSec)
            var nextSlotNs = DispatchTime.now().uptimeNanoseconds

            await withTaskGroup(of: Void.self) { group in
                var index = 0
                var scanned = 0
                var inFlight = 0

                func enqueueNext() {
                    guard !Task.isCancelled, index < filteredTargets.count else { return }
                    let ip = filteredTargets[index]
                    index += 1
                    inFlight += 1

                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    let scheduledNs = max(nowNs, nextSlotNs)
                    nextSlotNs = scheduledNs + minGapNs
                    let delayNs = scheduledNs > nowNs ? (scheduledNs - nowNs) : 0

                    group.addTask { [weak delegate] in
                        if delayNs > 0 {
                            try? await Task.sleep(nanoseconds: delayNs)
                        }
                        if Task.isCancelled { return }

                        if let hit = SubnetScanner.probeRdp(ipAddr: ip) {
                            let initialName = hit.certCN.flatMap {
                                HostNameResolver.sanitizeHostname($0, ipStr: hit.ip)
                            }
                            await MainActor.run {
                                delegate?.discoveryDidFindHost(hit.ip, port: hit.port, initialName: initialName)
                            }

                            if !Task.isCancelled {
                                if let resolved = await HostNameResolver.resolve(ipAddr: ip, sharedCertCN: hit.certCN) {
                                    await MainActor.run {
                                        delegate?.discoveryDidUpdateHost(hit.ip, port: hit.port, resolvedName: resolved)
                                    }
                                }
                            }
                        }
                    }
                }

                while inFlight < self.maxConcurrency && index < filteredTargets.count && !Task.isCancelled {
                    enqueueNext()
                }

                while await group.next() != nil {
                    inFlight -= 1
                    scanned += 1
                    if scanned % 8 == 0 || scanned == total {
                        let currentScanned = scanned
                        await MainActor.run {
                            delegate?.discoveryDidUpdateProgress(currentScanned, total: total)
                        }
                    }
                    if !Task.isCancelled {
                        enqueueNext()
                    }
                }
            }

            self.setScanning(false)
            await MainActor.run {
                delegate?.discoveryDidCompleteWithError(nil)
            }
        }
    }

    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        setScanning(false)
    }

    private static func resolveIPv4Addresses(for hosts: [String]) -> Set<UInt32> {
        var result = Set<UInt32>()
        for rawHost in hosts {
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty { continue }

            var addr = in_addr()
            if inet_pton(AF_INET, host, &addr) == 1 {
                result.insert(UInt32(bigEndian: addr.s_addr))
                continue
            }

            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints, &res) == 0, let first = res {
                defer { freeaddrinfo(res) }
                var ptr: UnsafeMutablePointer<addrinfo>? = first
                while let info = ptr {
                    if let sa = info.pointee.ai_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        result.insert(UInt32(bigEndian: sin.sin_addr.s_addr))
                    }
                    ptr = info.pointee.ai_next
                }
            }
        }
        return result
    }
}
