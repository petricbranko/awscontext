import AppKit
import AWSContextCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfile: String?
    @Published private(set) var sessions: [String: SSOSessionStatus] = [:]
    /// What the app is doing right now, e.g. "Signing in to prod…".
    @Published private(set) var activity: String?

    let store: ProfileStore
    let cli: AWSCLI
    private let notifications = SessionNotifications()
    private var watchers: [DirectoryWatcher] = []
    private var timer: Timer?
    private var runningProcess: Process?
    /// SSO sessions (keyed by token cache file) whose silent refresh was verified to fail.
    private var refreshFailed: Set<String> = []
    private var lastVerified: [String: Date] = [:]

    private static let previousProfileKey = "previousProfile"

    init(store: ProfileStore = ProfileStore()) {
        self.store = store
        self.cli = AWSCLI(paths: store.paths)
        Self.terminateOtherInstances()
        reload()

        let directories = Set([store.paths.credentials, store.paths.config, store.paths.state, store.paths.ssoCache]
            .map { $0.deletingLastPathComponent() } + [store.paths.ssoCache])
        watchers = directories.compactMap { url in
            DirectoryWatcher(url: url) { [weak self] in self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSessions(notify: true) }
        }
        notifications.onSignInRequested = { [weak self] in
            guard let self, let profile = self.active else { return }
            self.signIn(profile)
        }
        if active?.sso != nil { notifications.requestAuthorization() }
    }

    var active: Profile? { profiles.first { $0.name == activeProfile } }

    var previousProfile: String? {
        guard let name = UserDefaults.standard.string(forKey: Self.previousProfileKey),
              name != activeProfile, profiles.contains(where: { $0.name == name }) else { return nil }
        return name
    }

    func needsSignIn(_ profile: Profile) -> Bool {
        guard let sso = profile.sso else { return false }
        if refreshFailed.contains(SSOTokenCache.cacheFileName(for: sso)) { return true }
        switch sessions[profile.name] {
        case .expired, .signedOut: return true
        default: return false
        }
    }

    // MARK: Loading

    func reload() {
        profiles = store.profiles()
        activeProfile = store.activeProfileName()
        refreshSessions()
    }

    /// `notify` is true for background checks only; user actions never trigger a notification.
    func refreshSessions(notify: Bool = false) {
        var result: [String: SSOSessionStatus] = [:]
        for profile in profiles {
            if let sso = profile.sso {
                result[profile.name] = SSOTokenCache.status(for: sso, cacheDirectory: store.paths.ssoCache)
            }
        }
        sessions = result
        for profile in profiles {
            if let sso = profile.sso, case .valid = result[profile.name] {
                refreshFailed.remove(SSOTokenCache.cacheFileName(for: sso))
            }
        }
        if let active { verifyRefreshableSession(active) }
        let expired = active.flatMap { needsSignIn($0) ? $0.name : nil }
        if expired == nil || (notify && activity == nil) {
            notifications.update(profile: expired)
        }
    }

    /// The CLI can renew an expired access token silently. Check once in a while whether that still works,
    /// so the menu bar can warn when the Identity Center session itself has ended.
    private func verifyRefreshableSession(_ profile: Profile) {
        guard let sso = profile.sso, sessions[profile.name] == .refreshable, activity == nil else { return }
        let key = SSOTokenCache.cacheFileName(for: sso)
        guard Date().timeIntervalSince(lastVerified[key] ?? .distantPast) > 600 else { return }
        lastVerified[key] = Date()
        Task {
            do {
                try await cli.run(["sts", "get-caller-identity", "--profile", profile.name])
                refreshFailed.remove(key)
            } catch {
                // Ignore network trouble; only token errors mean the session has ended.
                let message = error.localizedDescription.lowercased()
                if message.contains("token") || message.contains("sso") || message.contains("expired") {
                    refreshFailed.insert(key)
                }
            }
            refreshSessions()
        }
    }

    // MARK: Actions

    func activate(_ name: String) {
        let previous = activeProfile
        perform { try store.activate(name) }
        if let previous, previous != name, activeProfile == name {
            UserDefaults.standard.set(previous, forKey: Self.previousProfileKey)
        }
        guard let profile = active, profile.name == name, profile.sso != nil else { return }
        notifications.requestAuthorization()
        if needsSignIn(profile) { signIn(profile) }
    }

    func switchToPrevious() {
        if let previousProfile { activate(previousProfile) }
    }

    func signIn(_ profile: Profile) {
        Task { await signInNow(profile) }
    }

    @discardableResult
    private func signInNow(_ profile: Profile) async -> Bool {
        guard let sso = profile.sso, activity == nil else { return false }
        activity = "Signing in to \(profile.name) in your browser…"
        defer {
            activity = nil
            runningProcess = nil
            refreshSessions()
        }
        do {
            try await cli.run(["sso", "login", "--profile", sso.profile]) { process in
                Task { @MainActor in self.runningProcess = process }
            }
            let key = SSOTokenCache.cacheFileName(for: sso)
            refreshFailed.remove(key)
            lastVerified[key] = Date()
            return true
        } catch AWSCLIError.cancelled {
            return false
        } catch {
            present(error)
            return false
        }
    }

    func openConsole(_ profile: Profile) {
        Task {
            // Only non-SSO-shortcut profiles need working CLI credentials first.
            let usesShortcut = profile.kind == .sso && profile.accountId != nil && profile.roleName != nil
            if !usesShortcut && needsSignIn(profile) {
                guard await signInNow(profile) else { return }
            }
            guard activity == nil else { return }
            activity = "Opening the AWS console for \(profile.name)…"
            defer { activity = nil }
            do {
                NSWorkspace.shared.open(try await ConsoleSignIn.url(for: profile, cli: cli))
            } catch {
                present(error)
            }
        }
    }

    func cancelActivity() {
        runningProcess?.terminate()
    }

    func add(_ profile: NewProfile, activate shouldActivate: Bool) throws {
        try store.add(profile)
        reload()
        if shouldActivate { activate(profile.name.trimmingCharacters(in: .whitespaces)) }
    }

    func confirmRemove(_ name: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "The profile will be deleted from your AWS credentials and config files."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            perform { try store.remove(name) }
        }
    }

    func copyExportCommand() {
        guard let activeProfile else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("export AWS_PROFILE=\(activeProfile)", forType: .string)
    }

    func openInEditor(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            perform {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            }
        }
    }

    // MARK: Helpers

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            present(error)
        }
        reload()
    }

    private func present(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }

    /// Launching a fresh copy (e.g. after `make install`) replaces any copy that is already running.
    private static func terminateOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app != .current {
            app.terminate()
        }
    }
}

/// Calls back (debounced, on the main queue) whenever a directory's contents change.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }
}
