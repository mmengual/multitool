import Darwin
import Foundation
import CoreGraphics

/// Machine-wide counters, read without privileges.
struct SystemReading {
    var time: Date
    /// Busy share of all cores, 0...1.
    var cpu: Double
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var memoryPressure: Int
    var swapUsed: UInt64
    var networkIn: UInt64
    var networkOut: UInt64
    var thermal: ProcessInfo.ThermalState
    /// Process holding Secure Input: global shortcuts and key remappers stop working.
    var secureInputPID: Int32?
}

enum SystemStats {
    private static var previousTicks: (busy: UInt64, total: UInt64)?

    static func read() -> SystemReading {
        let (inBytes, outBytes) = networkBytes()
        let (used, total) = memory()
        return SystemReading(
            time: Date(), cpu: cpuLoad(), memoryUsed: used, memoryTotal: total,
            memoryPressure: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1,
            swapUsed: swapUsed(), networkIn: inBytes, networkOut: outBytes,
            thermal: ProcessInfo.processInfo.thermalState,
            secureInputPID: secureInputPID())
    }

    // MARK: CPU

    private static func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return 0 }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    // MARK: Memory

    /// "Memory used" as Activity Monitor counts it: app memory, wired, compressed.
    private static func memory() -> (used: UInt64, total: UInt64) {
        let total = UInt64(sysctlInt64("hw.memsize") ?? 0)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    // MARK: Network

    /// Cumulative bytes on every interface but loopback, from the 64-bit counters.
    private static func networkBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0 {
                        inBytes += message.ifm_data.ifi_ibytes
                        outBytes += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (inBytes, outBytes)
    }

    // MARK: Secure Input

    private static func secureInputPID() -> Int32? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
    }

    // MARK: sysctl

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
