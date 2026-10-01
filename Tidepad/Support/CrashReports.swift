import AppKit
import MetricKit

/// Crash and hang reports from Apple's MetricKit, kept on this Mac only: macOS hands them to TidePad
/// (usually at the next launch after a crash), and they're saved as JSON in
/// ~/Library/Application Support/Tidepad/Diagnostics. Nothing is sent anywhere. Help ▸ Report a
/// Problem… opens a new GitHub issue with the version and system details filled in, and Help ▸ Show
/// Crash Reports shows the folder, so a report can be attached by hand.
final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReports()

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tidepad", isDirectory: true).appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Starts receiving reports (at launch; MetricKit itself costs nothing until it has something).
    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        for payload in payloads {
            let name = "diagnostic-" + stamp.string(from: payload.timeStampEnd).replacingOccurrences(of: ":", with: "-") + ".json"
            try? payload.jsonRepresentation().write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    /// The saved reports, newest first.
    static var reports: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Help ▸ Show Crash Reports.
    @MainActor static func showReports() {
        guard let newest = reports.first else {
            let alert = NSAlert()
            alert.messageText = "No crash reports"
            alert.informativeText = "TidePad hasn’t crashed on this Mac, or macOS hasn’t delivered a report yet."
            alert.runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([newest])
    }

    /// Help ▸ Report a Problem…: a new GitHub issue with the details filled in.
    @MainActor static func reportProblem() {
        let crash = reports.isEmpty ? "" : "\n\nTidePad has crash reports saved: Help ▸ Show Crash Reports. Please attach the newest one."
        let body = """
        **What happened**


        **Steps to reproduce**
        1. 

        **TidePad**
        \(AppDetails.summary)\(crash)
        """
        var components = URLComponents(url: AppDetails.homePage.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
