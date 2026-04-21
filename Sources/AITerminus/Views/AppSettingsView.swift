import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case terminal
    case ai

    var id: String { rawValue }
}

struct AppSettingsView: View {
    @EnvironmentObject var appState: AppState

    @Binding var aiConfig: AIConfig
    @Binding var language: AppLanguage
    @Binding var terminalAppearance: TerminalAppearance

    let onSave: () -> Void
    let onCancel: () -> Void
    var showsActions: Bool = true

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                GeneralSettingsTab(language: $language)
                    .environmentObject(appState)
                    .tabItem {
                        Label(appState.t("一般", "General"), systemImage: "gearshape")
                    }
                    .tag(SettingsTab.general)

                TerminalSettingsTab(appearance: $terminalAppearance)
                    .environmentObject(appState)
                    .tabItem {
                        Label(appState.t("終端機", "Terminal"), systemImage: "terminal")
                    }
                    .tag(SettingsTab.terminal)

                AISettingsForm(config: $aiConfig, language: $language)
                    .environmentObject(appState)
                    .tabItem {
                        Label("AI", systemImage: "sparkles")
                    }
                    .tag(SettingsTab.ai)
            }

            if showsActions {
                Divider()
                HStack {
                    Spacer()
                    Button(appState.t("取消", "Cancel")) { onCancel() }
                        .keyboardShortcut(.escape)
                    Button(appState.t("儲存", "Save")) { onSave() }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
        }
        .frame(width: 720, height: 520)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @Binding var language: AppLanguage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProviderSection(title: appState.t("介面", "Interface")) {
                    LabeledRow(label: appState.t("語言", "Language")) {
                        Picker("", selection: $language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct TerminalSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @Binding var appearance: TerminalAppearance

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProviderSection(title: appState.t("預設風格", "Presets")) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(TerminalThemePreset.allCases) { preset in
                            TerminalPresetCard(
                                preset: preset,
                                isSelected: appearance.themePreset == preset
                            )
                            .onTapGesture {
                                appearance.themePreset = preset
                            }
                        }
                    }
                }

                Divider()

                ProviderSection(title: appState.t("文字", "Typography")) {
                    LabeledRow(label: appState.t("字型", "Font")) {
                        Picker("", selection: $appearance.fontPreset) {
                            ForEach(TerminalFontPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .labelsHidden()
                    }

                    HStack(spacing: 12) {
                        LabeledRow(label: appState.t("字體大小", "Font Size")) {
                            HStack {
                                Slider(value: $appearance.fontSize, in: 10...28, step: 1)
                                Text("\(Int(appearance.fontSize)) pt")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }

                }

                Divider()

                ProviderSection(title: appState.t("預覽", "Preview")) {
                    TerminalPreviewCard(appearance: appearance)
                }
            }
            .padding(20)
        }
    }
}

private struct TerminalPresetCard: View {
    @EnvironmentObject var appState: AppState

    let preset: TerminalThemePreset
    let isSelected: Bool

    var body: some View {
        let palette = preset.appearance

        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: palette.background))
                .frame(height: 94)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("$ ssh prod-api")
                            .foregroundStyle(Color(nsColor: palette.cursor))
                        Text("Last login: Fri 10:42")
                            .foregroundStyle(Color(nsColor: palette.foreground))
                        Text("deploy@prod:~ % tail -f app.log")
                            .foregroundStyle(Color(nsColor: palette.foreground).opacity(0.88))
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(12)
                }

            Text(preset.localizedName)
                .font(.system(size: 13, weight: .semibold))
            Text(preset.localizedDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.22), lineWidth: isSelected ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TerminalPreviewCard: View {
    let appearance: TerminalAppearance

    var body: some View {
        let palette = appearance.palette

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.9)).frame(width: 10, height: 10)
                Circle().fill(Color.orange.opacity(0.9)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.9)).frame(width: 10, height: 10)
                Spacer()
                Text(appearance.fontPreset.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: palette.selection))

            VStack(alignment: .leading, spacing: 7) {
                Text("user@aiterminus:~ % kubectl get pods")
                Text("api-64d7d57f5c-qr4d8      1/1     Running")
                Text("worker-6bdbfd86c-6m8pn    1/1     Running")
                Text("db-migration-job          0/1     Completed")
            }
            .font(.custom(appearance.makeFont().fontName, size: appearance.fontSize))
            .foregroundStyle(Color(nsColor: palette.foreground))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: palette.background))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}
