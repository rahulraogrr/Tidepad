import AppKit

// Only active when the benchmark driver supplies explicit environment variables.

@MainActor extension EditorDiagnostics {
    static func launched(window: NSWindow, context: WorkspaceCommandContext) {
        guard !didReportLaunch else { return }
        didReportLaunch = true
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TIDEPAD_LAUNCH_REPORT"], let raw = environment["TIDEPAD_LAUNCH_START"], let start = Double(raw) {
            DispatchQueue.main.async {
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                let report = "usable_ms=\((Date().timeIntervalSince1970 - start) * 1000) path=\(Bundle.main.bundleURL.path) editable=\(context.session?.textView.isEditable == true)\n"
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        if let fixture = environment["TIDEPAD_MEMORY_FIXTURE"], let reportPath = environment["TIDEPAD_MEMORY_REPORT"] {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                let baseline = residentBytes()
                let began = ContinuousClock.now
                var maximumMainActorGap = 0.0
                let heartbeat = Task { @MainActor in
                    var previous = Date()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                        let now = Date()
                        maximumMainActorGap = max(maximumMainActorGap, now.timeIntervalSince(previous) * 1000)
                        previous = now
                    }
                }
                let url = URL(fileURLWithPath: fixture)
                context.documents.openInBackground([url])
                for _ in 0..<200 {
                    if context.documents.selectedDocument?.fileURL == url { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let openTime = began.duration(to: .now)
                try? await Task.sleep(for: .seconds(1))
                heartbeat.cancel()
                let report = "open=\(openTime) maximumMainActorGap_ms=\(maximumMainActorGap) baseline=\(baseline) populated=\(residentBytes()) length=\(context.session?.textView.textStorage?.length ?? 0) path=\(Bundle.main.bundleURL.path)\n"
                try? report.write(toFile: reportPath, atomically: true, encoding: .utf8)
            }
        }
        #if DEBUG
        if let path = environment["TIDEPAD_OBSERVATION_REPORT"] {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard let session = context.session else { return }
                session.textView.insertText("first line\nsecond line", replacementRange: NSRange(location: 0, length: 0))
                try? await Task.sleep(for: .milliseconds(200))
                viewCounts = [:]
                session.textView.setSelectedRange(NSRange(location: 1, length: 0))
                try? await Task.sleep(for: .milliseconds(200))
                var report = "caret: \(viewCounts)\n"
                viewCounts = [:]
                session.textView.setSelectedRange(NSRange(location: 1, length: 12))
                try? await Task.sleep(for: .milliseconds(200))
                report += "selection: \(viewCounts)\n"
                viewCounts = [:]
                session.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
                try? await Task.sleep(for: .milliseconds(200))
                report += "typing already dirty: \(viewCounts)\n"
                viewCounts = [:]
                session.document.markSaved(at: URL(fileURLWithPath: "/tmp/observation-fixture.txt"))
                try? await Task.sleep(for: .milliseconds(200))
                report += "savepoint: \(viewCounts)\n"
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
}
