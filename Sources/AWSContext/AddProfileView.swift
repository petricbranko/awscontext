import AppKit
import AWSContextCore
import SwiftUI

/// Hosts the "Add Profile" form in a plain AppKit window, which behaves more
/// predictably than SwiftUI scenes in an app that only lives in the menu bar.
@MainActor
enum AddProfileWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Add AWS Profile"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AddProfileView(model: model) {
                window.close()
            })
            self.window = window
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AddProfileView: View {
    @ObservedObject var model: AppModel
    var onDone: () -> Void

    @State private var profile = NewProfile(output: "json")
    @State private var activateAfterAdding = true
    @State private var error: String?

    private static let regions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1",
        "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2", "eu-north-1", "eu-south-1",
        "ap-south-1", "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-northeast-2",
        "sa-east-1", "me-south-1", "af-south-1",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Copied credentials from the AWS portal? Paste them to fill the form.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Paste from Clipboard", action: pasteFromClipboard)
                    .help("Accepts a credentials block, export AWS_… lines or STS JSON")
            }

            Form {
                TextField("Profile name", text: $profile.name, prompt: Text("e.g. production"))
                TextField("Access Key ID", text: $profile.accessKeyId, prompt: Text("AKIA…"))
                SecureField("Secret Access Key", text: $profile.secretAccessKey)
                SecureField("Session Token", text: $profile.sessionToken, prompt: Text("Optional"))
                HStack {
                    TextField("Region", text: $profile.region, prompt: Text("Optional, e.g. us-east-1"))
                    Menu {
                        ForEach(Self.regions, id: \.self) { region in
                            Button(region) { profile.region = region }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose a region")
                }
                Picker("Output", selection: $profile.output) {
                    Text("json").tag("json")
                    Text("yaml").tag("yaml")
                    Text("text").tag("text")
                    Text("table").tag("table")
                    Text("Not set").tag("")
                }
                Toggle("Switch to this profile after adding", isOn: $activateAfterAdding)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Add Profile", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.name.isEmpty || profile.accessKeyId.isEmpty || profile.secretAccessKey.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let parsed = CredentialParser.parse(text) else {
            error = "No AWS credentials found on the clipboard."
            return
        }
        error = nil
        if !parsed.name.isEmpty { profile.name = parsed.name }
        profile.accessKeyId = parsed.accessKeyId
        profile.secretAccessKey = parsed.secretAccessKey
        profile.sessionToken = parsed.sessionToken
        if !parsed.region.isEmpty { profile.region = parsed.region }
        if !parsed.output.isEmpty { profile.output = parsed.output }
    }

    private func save() {
        do {
            try model.add(profile, activate: activateAfterAdding)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func close() {
        profile = NewProfile(output: "json")
        error = nil
        onDone()
    }
}
