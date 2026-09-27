import AppKit
import Darwin

/// Opt-in diagnostics; no document contents are logged.
@MainActor enum EditorDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["TIDEPAD_PROFILE"] != nil
    static let auditViews = ProcessInfo.processInfo.environment["TIDEPAD_OBSERVATION_AUDIT"] != nil
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = ContinuousClock.now
        defer { print("PROFILE \(name): \(start.duration(to: .now))") }
        return try body()
    }
    static var viewCounts: [String: Int] = [:]
    static func view(_ name: String) {
        #if DEBUG
        if auditViews { viewCounts[name, default: 0] += 1 }
        #endif
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static var didReportLaunch = false
}
