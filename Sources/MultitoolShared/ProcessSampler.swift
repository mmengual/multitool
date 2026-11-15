import Darwin
import Foundation

/// Cumulative counters of one process at one instant. The app turns two
/// samples into rates (CPU %, MB/s, W).
public struct ProcessSample: Codable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// The process macOS holds responsible for this one: the app behind an XPC
    /// service or a WebKit process. Equal to `pid` when it is its own.
    public var responsible: Int32?
    public var uid: UInt32
    public var name: String
    public var path: String?
    /// Start time in microseconds since 1970: with the pid, identifies a process
    /// across samples even when pids are reused.
    public var start: UInt64
    /// False when macOS refused the counters (root process read without the helper).
    public var hasUsage: Bool
    public var cpuNs: UInt64 = 0
    public var footprint: UInt64 = 0
    public var diskRead: UInt64 = 0
    public var diskWritten: UInt64 = 0
    public var energyNj: UInt64 = 0
    public var wakeups: UInt64 = 0

    public var key: String { "\(pid)-\(start)" }
}

public struct ProcessSnapshot: Codable, Sendable {
    /// CLOCK_UPTIME_RAW in nanoseconds when the sample was taken.
    public var time: UInt64
    public var privileged: Bool
    public var processes: [ProcessSample]
}

public enum ProcessSampler {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Reads every process macOS lets this process read.
    public static func snapshot() -> ProcessSnapshot {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let estimate = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(max(estimate, 0)) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var processes: [ProcessSample] = []
        processes.reserveCapacity(Int(max(count, 0)))

        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            if let sample = sample(pid) { processes.append(sample) }
        }
        return ProcessSnapshot(time: now, privileged: geteuid() == 0, processes: processes)
    }

    private static func sample(_ pid: pid_t) -> ProcessSample? {
        guard let identity = identity(pid) else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil

        var sample = ProcessSample(
            pid: pid, ppid: identity.ppid, uid: identity.uid, name: identity.name, path: path,
            start: identity.start, hasUsage: false)
        if let responsibleFor {
            let owner = responsibleFor(pid)
            if owner > 0 && owner != pid { sample.responsible = owner }
        }

        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        if result == 0 {
            sample.hasUsage = true
            // CPU times are in Mach time units, not nanoseconds, on Apple silicon.
            sample.cpuNs = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
            sample.footprint = usage.ri_phys_footprint
            sample.diskRead = usage.ri_diskio_bytesread
            sample.diskWritten = usage.ri_diskio_byteswritten
            sample.energyNj = usage.ri_energy_nj
            sample.wakeups = usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups
        }
        return sample
    }

    /// Name, parent, owner and start time. `proc_pidinfo` refuses root's
    /// processes to a normal user, `sysctl(KERN_PROC_PID)` doesn't.
    private static func identity(_ pid: pid_t) -> (name: String, ppid: Int32, uid: UInt32, start: UInt64)? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size {
            var name = cString(bsd.pbi_name)
            if name.isEmpty { name = cString(bsd.pbi_comm) }
            return (name, Int32(bsd.pbi_ppid), bsd.pbi_uid,
                    UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec))
        }
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return (cString(info.kp_proc.p_comm), info.kp_eproc.e_ppid, info.kp_eproc.e_ucred.cr_uid,
                UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
    }

    /// What Activity Monitor uses to attribute XPC services to their app. Not in
    /// the public headers, so looked up at run time, and skipped if missing.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFor: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
