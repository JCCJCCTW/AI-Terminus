import SwiftUI
import SwiftTerm
@preconcurrency import AppKit

extension NSEvent: @retroactive @unchecked Sendable {}

private func appFocusLog(_ message: String) {
    NSLog("[Focus] %@", message)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var mouseLogMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SessionTerminalView.installResignFirstResponderOverride()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupKeyEventMonitor()
        setupMouseLogMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseLogMonitor { NSEvent.removeMonitor(m) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Key event routing
    //
    // SwiftUI's NSHostingView consumes ALL key events in performKeyEquivalent before
    // they reach AppKit's responder chain. We intercept them here and forward to the
    // focused terminal view — unless a SwiftUI TextField (backed by NSTextView) has focus.

    private func setupKeyEventMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { event in
            MainActor.assumeIsolated { AppDelegate.routeKeyEvent(event) }
        }
    }

    @MainActor
    private static func routeKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = NSApp.keyWindow else { return event }

        if AppState.shared.isSessionDragModeEnabled {
            if event.type == .keyDown,
               event.charactersIgnoringModifiers?.isEmpty == false,
               !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                AppState.shared.showDragModeKeyboardAlert = true
            }
            return nil
        }

        // If any editable text view is anywhere in the responder chain, leave
        // the event alone. SwiftUI TextField's field editor (NSTextView) is
        // sometimes wrapped in additional responders, so a direct `is NSTextView`
        // check on the first responder can miss it.
        if isEditingTextInResponderChain(of: window) { return event }

        if event.type == .keyDown,
           hasPlainCommandModifier(event),
           handleSessionNavigationShortcut(event) {
            return nil
        }

        // Find the focused terminal (must be in this window / currently visible).
        guard let tv = AppState.shared.focusedSession?.terminalView,
              tv.window === window
        else { return event }

        // Only handle events when the terminal is already the first responder.
        // Focus transitions to the terminal happen through explicit user action
        // (clicking the terminal, switching session, opening a new session);
        // we never steal focus here — that would break SwiftUI controls.
        guard window.firstResponder === tv else { return event }

        // Route plain Return/Enter directly to the terminal and swallow the event.
        // This prevents SwiftUI/AppKit focus navigation from treating Enter as a
        // control-activation key and moving the selected session unexpectedly.
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command]) {
            switch event.keyCode {
            case 36, 76:
                tv.keyDown(with: event)
                return nil
            default:
                break
            }
        }

        // Terminal owns focus — AppKit will deliver the event to it normally.
        return event
    }

    @MainActor
    private static func isEditingTextInResponderChain(of window: NSWindow) -> Bool {
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current is MentionTextView { return true }
            if let tv = current as? NSTextView, tv.isEditable { return true }
            if let tf = current as? NSTextField, tf.isEditable { return true }
            responder = current.nextResponder
        }
        return false
    }

    private static func hasPlainCommandModifier(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) && flags.isDisjoint(with: [.control, .option, .shift])
    }

    @MainActor
    private static func handleSessionNavigationShortcut(_ event: NSEvent) -> Bool {
        let direction: AppState.SessionFocusDirection
        switch event.keyCode {
        case 123:
            direction = .left
        case 124:
            direction = .right
        case 125:
            direction = .down
        case 126:
            direction = .up
        default:
            return false
        }

        AppState.shared.moveFocusedSession(direction)
        return true
    }

    private func setupMouseLogMonitor() {
        mouseLogMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            MainActor.assumeIsolated {
                AppDelegate.routeMouseSelection(event)
                AppDelegate.logMouseHitPath(event)
            }
            return event
        }
    }

    @MainActor
    private static func routeMouseSelection(_ event: NSEvent) {
        guard !AppState.shared.isSessionDragModeEnabled,
              let window = event.window ?? NSApp.keyWindow
        else { return }

        if shouldBypassMouseSessionRouting(in: window, event: event) {
            appFocusLog("mouseRoute skippedForTextInput")
            return
        }

        let point = event.locationInWindow
        guard let session = AppState.shared.session(atWindowPoint: point) else { return }

        if AppState.shared.focusedSessionId != session.id {
            AppState.shared.focusedSessionId = session.id
            appFocusLog("mouseRoute selected session=\(session.id.uuidString) point={x:\(Int(point.x)), y:\(Int(point.y))}")
        }

        let accepted = session.focusTerminal()
        appFocusLog("mouseRoute focusResult session=\(session.id.uuidString) accepted=\(accepted)")
    }

    @MainActor
    private static func shouldBypassMouseSessionRouting(in window: NSWindow, event: NSEvent) -> Bool {
        guard let contentView = window.contentView else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)

        var current: NSView? = contentView.hitTest(point)
        while let view = current {
            if view is MentionTextView ||
                view is NSTextView ||
                view is NSTextField ||
                view is NSScrollView ||
                view is NSClipView {
                return true
            }
            current = view.superview
        }

        return false
    }

    @MainActor
    private static func logMouseHitPath(_ event: NSEvent) {
        guard let window = event.window ?? NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let point = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(point)

        var chain: [String] = []
        var current: NSView? = hitView
        while let view = current {
            if let container = view as? TerminalViewContainer {
                chain.append("TerminalViewContainer(\(container.sessionID?.uuidString ?? "nil"))")
            } else {
                chain.append(String(describing: type(of: view)))
            }
            current = view.superview
        }

        NSLog(
            "[Focus] mouseHit point={x:%d,y:%d} hit=%@ chain=%@",
            Int(point.x),
            Int(point.y),
            hitView.map { String(describing: type(of: $0)) } ?? "nil",
            chain.joined(separator: " -> ")
        )
    }

}

@main
struct AITerminusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) { Divider() }

            CommandMenu("Session") {
                Button(appState.t("關閉目前 Session", "Close Current Session")) {
                    if let s = appState.focusedSession { appState.closeSession(s) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(appState.focusedSession == nil)

                Divider()

                Button(appState.t("上一頁", "Previous Page")) { if appState.currentPage > 0 { appState.currentPage -= 1 } }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                    .disabled(appState.currentPage == 0)

                Button(appState.t("下一頁", "Next Page")) {
                    if appState.currentPage < appState.pageCount - 1 { appState.currentPage += 1 }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(appState.currentPage >= appState.pageCount - 1)
            }

            CommandMenu(appState.t("AI 助理", "AI Assistant")) {
                Button(appState.t("顯示 / 隱藏 AI 面板", "Show / Hide AI Panel")) { appState.showAIPanel.toggle() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environmentObject(appState)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var draftConfig = AIConfig()
    @State private var draftLanguage: AppLanguage = .traditionalChinese

    var body: some View {
        AISettingsView(config: $draftConfig, language: $draftLanguage) {
            appState.aiConfig = draftConfig
            appState.language = draftLanguage
            appState.saveAIConfig()
        } onCancel: {
            draftConfig = appState.aiConfig
            draftLanguage = appState.language
        }
        .onAppear {
            draftConfig = appState.aiConfig
            draftLanguage = appState.language
        }
    }
}
