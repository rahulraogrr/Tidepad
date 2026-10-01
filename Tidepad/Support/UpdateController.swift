import AppKit

/// TidePad ▸ Check for Updates…, and the automatic check: at most once a week, a few seconds after
/// launch, only when "Check for updates automatically" is on (Settings ▸ General). The automatic
/// check says something only when there's a new version; the menu command always answers. A new
/// version is downloaded from its release page in the browser; TidePad never installs anything itself.
@MainActor final class UpdateController {
    private let preferences: EditorPreferences
    private let defaults: UserDefaults
    private static let lastCheckKey = "Tidepad.LastUpdateCheck"
    /// One check at a time, and one alert.
    private var checking = false

    init(preferences: EditorPreferences, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.defaults = defaults
    }

    func checkNow() {
        guard !checking else { return }
        checking = true
        Task {
            let outcome = await UpdateCheck.check(current: AppDetails.version)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            show(outcome, asked: true)
        }
    }

    func scheduleAutomaticCheck() {
        guard preferences.checkForUpdates else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= UpdateCheck.interval else { return }
        Task {
            try? await Task.sleep(for: .seconds(10)) // After launch has settled.
            guard preferences.checkForUpdates, !checking else { return }
            checking = true
            let outcome = await UpdateCheck.check(current: AppDetails.version)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            show(outcome, asked: false)
        }
    }

    private func show(_ outcome: UpdateCheck.Outcome, asked: Bool) {
        let alert = NSAlert()
        switch outcome {
        case .available(let release):
            alert.messageText = "TidePad \(release.version) is available"
            alert.informativeText = "You have TidePad \(AppDetails.version). Download the new version from its release page, then replace TidePad in your Applications folder."
            let download = alert.addButton(withTitle: "Download")
            let later = alert.addButton(withTitle: "Later")
            if !asked {
                // Unasked, it may appear while someone is typing: Return mustn't open the browser.
                download.keyEquivalent = ""
                later.keyEquivalent = "\r"
            }
            present(alert) { if $0 == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) } }
            return
        case .upToDate:
            alert.messageText = "TidePad is up to date"
            alert.informativeText = "TidePad \(AppDetails.version) is the newest version."
        case .noReleases:
            alert.messageText = "No releases yet"
            alert.informativeText = "There are no TidePad releases to download yet."
        case .failed(let reason):
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = reason
        }
        guard asked else { checking = false; return }
        present(alert) { _ in }
    }

    /// As a sheet on the front window when there is one (it doesn't block the app's other windows),
    /// otherwise as an alert.
    private func present(_ alert: NSAlert, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.checking = false
                then(response)
            }
        } else {
            let response = alert.runModal()
            checking = false
            then(response)
        }
    }
}
