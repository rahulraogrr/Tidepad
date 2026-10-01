import Foundation

/// What this copy of TidePad is and the Mac it runs on: for About, Copy and Close, bug reports and
/// the update check. The version comes from Info.plist; the build date is the app's own.
enum AppDetails {
    static let homePage = URL(string: "https://github.com/rahulraogrr/Tidepad")!

    private static func value(_ key: String) -> String { Bundle.main.infoDictionary?[key] as? String ?? "" }

    /// "0.9".
    static var version: String { value("CFBundleShortVersionString") }
    static var build: String { value("CFBundleVersion") }
    static var copyright: String { value("NSHumanReadableCopyright") }

    /// "Build 1, built on 30 September 2026".
    static var buildLine: String {
        let built = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let date = built.map { ", built on " + $0.formatted(date: .long, time: .omitted) } ?? ""
        return "Build \(build)\(date)"
    }

    /// "macOS 27.0 (26A428), Apple silicon".
    static var systemLine: String {
        let system = ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: "")
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        return "macOS \(system), \(chip)"
    }

    static var aiState: String {
        guard OnDeviceModel.isSupported else { return "needs macOS 26 or later" }
        return OnDeviceModel.unavailableReason() == nil ? "available" : "turned off or not ready"
    }

    /// The details in a few lines, for a bug report.
    static var summary: String {
        "TidePad \(version) (\(buildLine))\n\(systemLine)\nOn-device AI: \(aiState)"
    }
}
