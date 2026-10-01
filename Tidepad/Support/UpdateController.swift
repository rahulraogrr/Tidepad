import AppKit

/// TidePad ▸ Check for Updates…, and the automatic check: at most once a week, a few seconds after
/// launch, only when "Check for updates automatically" is on (Settings ▸ General). The automatic
/// check says something only when there's a new version; the menu command always answers. A new
/// version is downloaded from its release page in the browser; TidePad never installs anything itself.
@MainActor final class UpdateController {
    private let preferences: EditorPreferences
    private let defaults: UserDefaults
    private static let lastCheckKey = "Tidepad.LastUpdateCheck"

    init(preferences: EditorPreferences, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.defaults = defaults
    }

    func checkNow() {
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
            guard preferences.checkForUpdates else { return }
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
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
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
        guard asked else { return }
        alert.runModal()
    }
}
