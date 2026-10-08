import AWSContextCore
import SwiftUI

@main
struct AWSContextApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("showNameInMenuBar") private var showName = true

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if showName {
                    Text(model.activeProfile ?? "AWS")
                }
            }
        }
    }

    private var icon: String {
        if model.activity != nil { return "arrow.clockwise.icloud" }
        if let active = model.active, model.needsSignIn(active) { return "exclamationmark.icloud" }
        return model.activeProfile == nil ? "cloud" : "cloud.fill"
    }
}
