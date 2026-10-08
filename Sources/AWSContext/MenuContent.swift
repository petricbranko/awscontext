import AWSContextCore
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @AppStorage("showNameInMenuBar") private var showName = true

    var body: some View {
        if let activity = model.activity {
            Text(activity)
            Button("Cancel") { model.cancelActivity() }
            Divider()
        }

        if let active = model.active {
            Text(header(for: active))
            if let status = statusLine(for: active) {
                Text(status)
            }
            if active.sso != nil {
                Button(model.needsSignIn(active) ? "Sign In Again…" : "Sign In with SSO…") { model.signIn(active) }
                    .keyboardShortcut("l")
                    .disabled(model.activity != nil)
            }
            Button("Open AWS Console") { model.openConsole(active) }
                .keyboardShortcut("o")
                .disabled(model.activity != nil)
            if let previous = model.previousProfile {
                Button("Switch Back to \(previous)") { model.switchToPrevious() }
                    .keyboardShortcut("p")
            }
            Divider()
        }

        if model.profiles.isEmpty {
            Text("No AWS profiles yet")
        } else {
            ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                let toggle = Toggle(isOn: Binding(
                    get: { model.activeProfile == profile.name },
                    set: { _ in model.activate(profile.name) }
                )) {
                    Text(title(for: profile))
                }
                if index < 9 {
                    toggle.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                } else {
                    toggle
                }
            }
        }

        Divider()

        if !model.profiles.isEmpty {
            Menu("Open Console For") {
                ForEach(model.profiles) { profile in
                    Button(profile.name) { model.openConsole(profile) }
                }
            }
        }

        Button("Add Profile…") { AddProfileWindow.show(model: model) }
            .keyboardShortcut("n")

        if !model.profiles.isEmpty {
            Menu("Remove Profile") {
                ForEach(model.profiles) { profile in
                    Button(profile.name) { model.confirmRemove(profile.name) }
                }
            }
        }

        if let active = model.activeProfile {
            Button("Copy “export AWS_PROFILE=\(active)”") { model.copyExportCommand() }
                .keyboardShortcut("c")
        }

        Divider()

        Menu("Settings") {
            Button("Edit Credentials File") { model.openInEditor(model.store.paths.credentials) }
            Button("Edit Config File") { model.openInEditor(model.store.paths.config) }
            Divider()
            Toggle("Show Profile Name in Menu Bar", isOn: $showName)
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.launchAtLogin = $0 }
            ))
        }

        Divider()

        Button("Quit AWSContext") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func header(for profile: Profile) -> String {
        var parts = [profile.name]
        if let accountId = profile.accountId { parts.append(accountId) }
        if let roleName = profile.roleName { parts.append(roleName) }
        return parts.joined(separator: "  ·  ")
    }

    private func statusLine(for profile: Profile) -> String? {
        guard profile.sso != nil else { return nil }
        if model.needsSignIn(profile) {
            return model.sessions[profile.name] == .signedOut ? "⚠️ Not signed in" : "⚠️ SSO session expired"
        }
        switch model.sessions[profile.name] {
        case .valid(let until):
            return "✓ Signed in · \(Self.remaining(until)) left"
        case .refreshable:
            return "✓ Signed in · renews automatically"
        default:
            return nil
        }
    }

    private func title(for profile: Profile) -> String {
        var parts = [profile.name]
        if let region = profile.region { parts.append(region) }
        if profile.kind != .accessKeys { parts.append(profile.kind.rawValue) }
        var title = parts.joined(separator: "  ·  ")
        if model.needsSignIn(profile) { title += "  ⚠️" }
        return title
    }

    private static func remaining(_ date: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = date.timeIntervalSinceNow >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, date.timeIntervalSinceNow)) ?? ""
    }
}
