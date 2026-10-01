import Foundation

/// TidePad started by its own in-app checks (Debug builds only, with a TIDEPAD_… variable such as
/// TIDEPAD_MENU_VALIDATE): a throwaway settings store and session folder, so the checks never change
/// the user's preferences, last folder, recent files or unsaved tabs, and no update check or crash
/// report runs.
enum CheckEnvironment {
    static let isActive: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("TIDEPAD_") }
        #else
        return false
        #endif
    }()

    private static let suiteName = "Tidepad.Checks"
    static let defaults: UserDefaults = {
        guard isActive, let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName) // Every run starts from the defaults.
        return suite
    }()

    static let sessionDirectory: URL? = isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("Tidepad-Checks-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent("Session", isDirectory: true)
        : nil
}
