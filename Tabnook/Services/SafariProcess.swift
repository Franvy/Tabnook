import AppKit

enum SafariProcess {
    static let bundleID = "com.apple.Safari"

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Quits Safari and waits for the process to fully exit so callers can safely
    /// rewrite Safari's data files before relaunching.
    /// - Returns: `true` if Safari was running (and has now been asked to quit),
    ///   `false` if it was not running.
    @discardableResult
    static func quit(waitingUpTo timeout: Duration = .seconds(5)) async -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        guard !running.isEmpty else { return false }

        for app in running {
            app.terminate()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !isRunning { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Still alive after the grace period — force it so the relaunch is clean.
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
            app.forceTerminate()
        }
        return true
    }

    static func launch() async {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
    }

    static func restart() async {
        _ = await quit()
        await launch()
    }
}
