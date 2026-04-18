import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var draftAIConfig = AIConfig()
    @State private var draftLanguage: AppLanguage = .traditionalChinese
    @State private var aiPanelResetToken = UUID()
    @State private var aiSubsystemFailureMessage: String?

    var body: some View {
        HSplitView {
            // Left: host list sidebar
            HostListView()
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
                .contentShape(Rectangle())
                .onTapGesture { appState.focusedSessionId = nil }

            // Center: session grid + tab bar
            SessionGridView()
                .frame(minWidth: 400)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(appState.isSessionDragModeEnabled ? Color.red.opacity(0.85) : Color.clear, lineWidth: 3)
                        .padding(4)
                }

            // Right: AI assistant panel
            if appState.showAIPanel {
                Group {
                    if let aiSubsystemFailureMessage {
                        AIUnavailableView(
                            message: aiSubsystemFailureMessage,
                            onReload: {
                                self.aiSubsystemFailureMessage = nil
                                aiPanelResetToken = UUID()
                            }
                        )
                    } else {
                        AIAssistantView { message in
                            aiSubsystemFailureMessage = message
                        }
                        .id(aiPanelResetToken)
                    }
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation {
                        appState.showAIPanel.toggle()
                    }
                } label: {
                    Label(
                        appState.showAIPanel ? appState.t("隱藏 AI 面板", "Hide AI Panel") : appState.t("顯示 AI 面板", "Show AI Panel"),
                        systemImage: "sparkles"
                    )
                }
                .help(appState.showAIPanel ? appState.t("隱藏 AI 助理", "Hide AI Assistant") : appState.t("顯示 AI 助理", "Show AI Assistant"))
            }
        }
        .sheet(isPresented: $appState.showAISettingsSheet) {
            AISettingsView(config: $draftAIConfig, language: $draftLanguage) {
                appState.aiConfig = draftAIConfig
                appState.language = draftLanguage
                appState.saveAIConfig()
                appState.showAISettingsSheet = false
            } onCancel: {
                appState.showAISettingsSheet = false
            }
        }
        .onChange(of: appState.showAISettingsSheet) { show in
            if show {
                draftAIConfig = appState.aiConfig
                draftLanguage = appState.language
            }
        }
        .alert(appState.t("提醒", "Notice"), isPresented: $appState.showDragModeKeyboardAlert) {
            Button(appState.t("確定", "OK"), role: .cancel) {}
        } message: {
            Text(appState.t("請關閉連線拖曳", "Please disable session dragging first."))
        }
    }
}

private struct AIUnavailableView: View {
    @EnvironmentObject var appState: AppState

    let message: String
    let onReload: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bolt.slash.circle")
                .font(.system(size: 34))
                .foregroundStyle(.orange)
            Text(appState.t("AI 面板已隔離", "AI Panel Isolated"))
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Text(appState.t("SSH Session 仍可繼續使用；重新載入 AI 面板即可恢復。", "SSH sessions remain active; reload the AI panel to restore it."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Button(appState.t("重新載入 AI 面板", "Reload AI Panel"), action: onReload)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
