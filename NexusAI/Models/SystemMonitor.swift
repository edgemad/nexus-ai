import Foundation
import SwiftUI
import Darwin
import IOKit.ps

struct SystemSnapshot {
    var cpuUsage: Double
    var memoryUsedGB: Double
    var memoryTotalGB: Double
    var diskUsedGB: Double
    var diskTotalGB: Double
    var uptimeSeconds: TimeInterval
    var processCount: Int
    var topProcesses: [(name: String, cpu: Double, memoryMB: Double)]
    var batteryLevel: Double?
    var timestamp: Date

    var memoryFraction: Double {
        memoryTotalGB > 0 ? memoryUsedGB / memoryTotalGB : 0
    }

    var diskFraction: Double {
        diskTotalGB > 0 ? diskUsedGB / diskTotalGB : 0
    }

    var statusColor: Color {
        if cpuUsage < 50 && memoryFraction < 0.75 && diskFraction < 0.9 {
            return .green
        } else if cpuUsage < 85 && memoryFraction < 0.9 && diskFraction < 0.97 {
            return .yellow
        } else {
            return .red
        }
    }

    static var empty: SystemSnapshot {
        SystemSnapshot(
            cpuUsage: 0,
            memoryUsedGB: 0,
            memoryTotalGB: 0,
            diskUsedGB: 0,
            diskTotalGB: 0,
            uptimeSeconds: 0,
            processCount: 0,
            topProcesses: [],
            batteryLevel: nil,
            timestamp: Date()
        )
    }
}

/// Lightweight system monitor.
///
/// Sampling hits the kernel once per process, so it is throttled hard:
/// a single PID scan per capture (never overlapping), infrequent polling
/// (30s), and name lookups only for the handful of processes that rank in
/// the top list. Sampling runs off the main thread so the UI never freezes.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot.empty

    private var timer: Timer?
    private var isCapturing = false
    private let queue = DispatchQueue(label: "com.nexusai.systemmonitor", qos: .utility)

    init() {
        // Sampling only runs while the Health panel is open (see setActive), so
        // the app does no periodic kernel work while idling in other panels.
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts/stops the periodic sampler. Called when the user switches between
    /// panels so we don't scan processes in the background when Health isn't
    /// visible.
    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            let action = { [weak self] in self?.scheduleRefresh() }
            timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in action() }
            scheduleRefresh()
        } else {
            timer?.invalidate()
            timer = nil
            isCapturing = false
        }
    }

    /// Triggers a background capture and publishes the result onto the main thread.
    /// Skips the work if a previous capture is still in flight.
    func scheduleRefresh() {
        guard !isCapturing else { return }
        isCapturing = true
        queue.async { [weak self] in
            let snap = SystemMonitor.capture()
            DispatchQueue.main.async { [weak self] in
                self?.snapshot = snap
                self?.isCapturing = false
            }
        }
    }

    /// Public refresh (used by the Health view's button). Non-blocking: does the
    /// sampling off the main thread so the UI never freezes.
    func refresh() {
        scheduleRefresh()
    }

    nonisolated static func capture() -> SystemSnapshot {
        // One PID scan, reused for both the count and the top list below.
        let pids = allPIDs()
        let cpu = hostCPULoad()
        let mem = (usedGB: usedMemoryGB(), totalGB: totalMemoryGB())
        let disk = (usedGB: usedDiskGB(), totalGB: totalDiskGB())
        let uptime = ProcessInfo.processInfo.systemUptime
        let top = topProcesses(from: pids, limit: 5)
        let battery = batteryLevel()

        return SystemSnapshot(
            cpuUsage: cpu,
            memoryUsedGB: mem.usedGB,
            memoryTotalGB: mem.totalGB,
            diskUsedGB: disk.usedGB,
            diskTotalGB: disk.totalGB,
            uptimeSeconds: uptime,
            processCount: pids.count,
            topProcesses: top,
            batteryLevel: battery,
            timestamp: Date()
        )
    }

    // MARK: - CPU

    private nonisolated static func hostCPULoad() -> Double {
        var loadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(loadInfo.cpu_ticks.0)
        let system = Double(loadInfo.cpu_ticks.1)
        let idle = Double(loadInfo.cpu_ticks.2)
        let nice = Double(loadInfo.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return (user + system + nice) / total * 100
    }

    // MARK: - Memory

    private nonisolated static func memoryStats() -> (usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let pageSize = Double(vm_kernel_page_size)
        let free = Double(stats.free_count)
        let inactive = Double(stats.inactive_count)
        let wired = Double(stats.wire_count)
        let compressed = Double(stats.compressor_page_count)
        let usedBytes = (wired + compressed) * pageSize
        let totalBytes = usedBytes + ((free + inactive) * pageSize)
        return (usedBytes / 1_073_741_824, totalBytes / 1_073_741_824)
    }

    private nonisolated static func totalMemoryGB() -> Double { memoryStats().totalGB }
    private nonisolated static func usedMemoryGB() -> Double { memoryStats().usedGB }

    // MARK: - Disk

    private nonisolated static func diskStats() -> (usedGB: Double, totalGB: Double) {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue,
              let total = (attrs[.systemSize] as? NSNumber)?.doubleValue else {
            return (0, 0)
        }
        return (max(0, (total - free) / 1_000_000_000), total / 1_000_000_000)
    }

    private nonisolated static func usedDiskGB() -> Double { diskStats().usedGB }
    private nonisolated static func totalDiskGB() -> Double { diskStats().totalGB }

    // MARK: - Processes

    private nonisolated static func allPIDs() -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        _ = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, size)
        }
        return pids.filter { $0 > 0 }
    }

    private nonisolated static func topProcesses(from pids: [pid_t], limit: Int) -> [(name: String, cpu: Double, memoryMB: Double)] {
        // One syscall per process (resident size only). Name lookups happen
        // only for the few that actually rank in the top list.
        var found: [(pid: pid_t, memoryMB: Double)] = []
        found.reserveCapacity(pids.count)
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        for pid in pids {
            let res = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int8.self, capacity: size) {
                    proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(size))
                }
            }
            guard res == size else { continue }
            let memoryMB = Double(info.pti_resident_size) / 1_048_576
            if memoryMB > 0 {
                found.append((pid: pid, memoryMB: memoryMB))
            }
        }
        return found
            .sorted { $0.memoryMB > $1.memoryMB }
            .prefix(limit)
            .map { (processName(pid: $0.pid), 0, $0.memoryMB) }
    }

    private nonisolated static func processName(pid: pid_t) -> String {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let res = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: Int8.self, capacity: size) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
            }
        }
        guard res == size else { return "pid \(pid)" }
        let pbiName = info.pbi_name
        let nameBytes = withUnsafePointer(to: pbiName) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: pbiName)) {
                String(cString: $0)
            }
        }
        return nameBytes.isEmpty ? "pid \(pid)" : nameBytes
    }

    // MARK: - Battery

    private nonisolated static func batteryLevel() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let level = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int,
               max > 0 {
                return Double(level) / Double(max) * 100
            }
        }
        return nil
    }
}
