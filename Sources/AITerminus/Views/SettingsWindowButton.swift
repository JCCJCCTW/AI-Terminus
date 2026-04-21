import SwiftUI

struct SettingsWindowButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: openSettingsWindow) {
            label()
        }
    }

    private func openSettingsWindow() {
        openWindow(id: "app-settings")
    }
}
