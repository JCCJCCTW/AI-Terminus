import SwiftUI
import SwiftTerm
import AppKit
import UniformTypeIdentifiers

private let sessionDragPayloadPrefix = "aiterminus-session:"
private let isFocusLoggingEnabled = false

private func focusLog(_ message: @autoclosure () -> String) {
    guard isFocusLoggingEnabled else { return }
    NSLog("[Focus] %@", message())
}

private func responderName(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    if let terminal = responder as? SessionTerminalView,
       let session = terminal.session {
        return "SessionTerminalView(\(session.id.uuidString))"
    }
    return String(describing: type(of: responder))
}

private func rectLog(_ rect: NSRect) -> String {
    "{x:\(Int(rect.origin.x)), y:\(Int(rect.origin.y)), w:\(Int(rect.size.width)), h:\(Int(rect.size.height))}"
}

final class SessionTerminalView: LocalProcessTerminalView {
    weak var session: SSHSession?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let text = String(decoding: slice, as: UTF8.self)
        Task { @MainActor [weak session] in
            session?.recordTerminalOutput(text)
        }
    }

    override func markedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    static func installResignFirstResponderOverride() {
        let selector = #selector(NSResponder.resignFirstResponder)
        guard let parentMethod = class_getInstanceMethod(self, selector) else { return }
        let parentImplementation = method_getImplementation(parentMethod)

        let block: @convention(block) (AnyObject) -> Bool = { object in
            typealias ResignFunction = @convention(c) (AnyObject, Selector) -> Bool
            let original = unsafeBitCast(parentImplementation, to: ResignFunction.self)
            _ = original(object, selector)
            return true
        }
        let implementation = imp_implementationWithBlock(block)
        class_addMethod(self, selector, implementation, method_getTypeEncoding(parentMethod))
    }
}

@MainActor
final class SessionFrameTrackingView: NSView {
    var sessionID: UUID?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportFrame()
    }

    deinit {
        guard let sessionID else { return }
        Task { @MainActor in
            AppState.shared.updateSessionWindowFrame(nil, for: sessionID)
        }
    }

    private func reportFrame() {
        guard let sessionID, window != nil else {
            if let sessionID {
                AppState.shared.updateSessionWindowFrame(nil, for: sessionID)
            }
            return
        }

        let frameInWindow = convert(bounds, to: nil)
        AppState.shared.updateSessionWindowFrame(frameInWindow, for: sessionID)
        focusLog("frameReport session=\(sessionID.uuidString) frame=\(rectLog(frameInWindow))")
    }
}

struct SessionFrameReporter: NSViewRepresentable {
    let sessionID: UUID

    func makeNSView(context: Context) -> SessionFrameTrackingView {
        let view = SessionFrameTrackingView(frame: .zero)
        view.sessionID = sessionID
        return view
    }

    func updateNSView(_ nsView: SessionFrameTrackingView, context: Context) {
        nsView.sessionID = sessionID
    }
}

// Container NSView — hosts the terminal view and survives page switches.
// Uses layout() override to keep the terminal filling the container even
// when the container starts with frame .zero (autoresizingMask math breaks
// at zero size because 0/0 is undefined).
class TerminalViewContainer: NSView {
    private(set) var terminalView: LocalProcessTerminalView?
    var sessionID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        visibleRect.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        focusLog(
            "mouseDown container=\(sessionID?.uuidString ?? "nil") responder=\(responderName(window?.firstResponder)) point={x:\(Int(localPoint.x)), y:\(Int(localPoint.y))} frame=\(rectLog(frame)) bounds=\(rectLog(bounds)) visible=\(rectLog(visibleRect))"
        )
        guard bounds.contains(localPoint) else {
            focusLog("mouseDown ignoredOutsideBounds container=\(sessionID?.uuidString ?? "nil")")
            super.mouseDown(with: event)
            return
        }
        focusAndForward(event) { tv, forwardedEvent in
            tv.mouseDown(with: forwardedEvent)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        focusLog(
            "rightMouseDown container=\(sessionID?.uuidString ?? "nil") responder=\(responderName(window?.firstResponder)) point={x:\(Int(localPoint.x)), y:\(Int(localPoint.y))} frame=\(rectLog(frame)) bounds=\(rectLog(bounds)) visible=\(rectLog(visibleRect))"
        )
        guard bounds.contains(localPoint) else {
            focusLog("rightMouseDown ignoredOutsideBounds container=\(sessionID?.uuidString ?? "nil")")
            super.rightMouseDown(with: event)
            return
        }
        if let sessionID, AppState.shared.focusedSessionId != sessionID {
            AppState.shared.focusedSessionId = sessionID
            focusLog("rightMouseDown selected session=\(sessionID.uuidString)")
        }
        _ = focusTerminal()
        super.rightMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        terminalView?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        terminalView?.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        terminalView?.scrollWheel(with: event)
    }

    // Called whenever the container is resized — keeps the terminal filling bounds.
    override func layout() {
        super.layout()
        focusLog("layout container=\(sessionID?.uuidString ?? "nil") frame=\(rectLog(frame)) bounds=\(rectLog(bounds)) visible=\(rectLog(visibleRect))")
        refreshTerminalLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusLog("viewDidMoveToWindow container=\(sessionID?.uuidString ?? "nil") frame=\(rectLog(frame)) bounds=\(rectLog(bounds)) visible=\(rectLog(visibleRect))")
        refreshTerminalLayout()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refreshTerminalLayout()
    }

    func attach(_ tv: LocalProcessTerminalView) {
        guard terminalView !== tv else { return }
        terminalView?.removeFromSuperview()
        tv.removeFromSuperview()
        terminalView = tv
        // Frame-based layout: seed initial frame, autoresizingMask as secondary guard,
        // layout() override as the definitive resize handler.
        tv.autoresizingMask = [.width, .height]
        addSubview(tv)
        refreshTerminalLayout()
    }

    func applyAppearance(_ appearance: TerminalAppearance) {
        layer?.backgroundColor = appearance.palette.background.cgColor
    }

    @discardableResult
    func focusTerminal() -> Bool {
        guard let tv = terminalView,
              let targetWindow = tv.window ?? window else { return false }
        if targetWindow.firstResponder !== tv {
            let cleared = targetWindow.makeFirstResponder(nil)
            let accepted = targetWindow.makeFirstResponder(tv)
            focusLog("focusTerminal makeFirstResponder session=\(sessionID?.uuidString ?? "nil") cleared=\(cleared) accepted=\(accepted) responder=\(responderName(targetWindow.firstResponder))")
            return accepted
        }
        return true
    }

    private func focusAndForward(
        _ event: NSEvent,
        using handler: (LocalProcessTerminalView, NSEvent) -> Void
    ) {
        guard let tv = terminalView,
              let targetWindow = tv.window ?? window else { return }
        if let sessionID, AppState.shared.focusedSessionId != sessionID {
            AppState.shared.focusedSessionId = sessionID
            focusLog("focusAndForward selected session=\(sessionID.uuidString)")
        }
        _ = focusTerminal()
        handler(tv, event)
        focusLog("focusAndForward forwarded session=\(sessionID?.uuidString ?? "nil") responder=\(responderName(targetWindow.firstResponder))")
    }

    private func refreshTerminalLayout() {
        guard let tv = terminalView else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }

        let targetSize = bounds.size
        if tv.frame.size != targetSize {
            tv.setFrameSize(targetSize)
        }
        if tv.frame.origin != .zero {
            tv.setFrameOrigin(.zero)
        }

        tv.needsDisplay = true
        tv.displayIfNeeded()
        needsDisplay = true
        displayIfNeeded()

        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self, let tv, tv.superview === self else { return }
            tv.needsDisplay = true
            tv.displayIfNeeded()
        }
    }
}

// NSViewRepresentable that reuses an existing LocalProcessTerminalView
// across page switches, keeping the SSH process alive.
struct TerminalSessionView: NSViewRepresentable {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: SSHSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalViewContainer {
        if let existingContainer = session.terminalContainer {
            existingContainer.sessionID = session.id
            existingContainer.applyAppearance(appState.terminalAppearance)
            if let terminalView = session.terminalView, existingContainer.terminalView !== terminalView {
                existingContainer.attach(terminalView)
            }
            return existingContainer
        }

        let container = TerminalViewContainer(frame: .zero)
        container.sessionID = session.id
        container.applyAppearance(appState.terminalAppearance)

        if let existing = session.terminalView {
            container.attach(existing)
        } else {
            let tv = makeTerminalView(coordinator: context.coordinator, appearance: appState.terminalAppearance)
            container.attach(tv)
            // Set terminalView synchronously — it is not @Published so this is safe.
            // NSViewRepresentable.makeNSView is called on the main thread.
            MainActor.assumeIsolated {
                session.terminalView = tv
            }
        }

        MainActor.assumeIsolated {
            session.terminalContainer = container
        }
        return container
    }

    func updateNSView(_ nsView: TerminalViewContainer, context: Context) {
        nsView.sessionID = session.id
        nsView.applyAppearance(appState.terminalAppearance)
        MainActor.assumeIsolated {
            if session.terminalContainer !== nsView {
                session.terminalContainer = nsView
            }
        }
        if let tv = session.terminalView, nsView.terminalView !== tv {
            applyAppearance(appState.terminalAppearance, to: tv)
            nsView.attach(tv)
        } else {
            if let tv = session.terminalView {
                applyAppearance(appState.terminalAppearance, to: tv)
            }
            nsView.needsLayout = true
            nsView.layoutSubtreeIfNeeded()
        }
    }

    private func makeTerminalView(coordinator: Coordinator, appearance: TerminalAppearance) -> LocalProcessTerminalView {
        let tv = SessionTerminalView(frame: .zero)
        tv.processDelegate = coordinator
        tv.session = session
        applyAppearance(appearance, to: tv)

        if session.host.isLocalClient {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            tv.startProcess(executable: shell, args: ["-l"])
        } else {
            var args: [String] = ["-o", "ServerAliveInterval=30"]
            if session.host.port != 22 { args += ["-p", "\(session.host.port)"] }
            if session.host.authMethod == .privateKey, !session.host.privateKeyPath.isEmpty {
                args += ["-i", session.host.privateKeyPath]
            }
            args.append("\(session.host.username)@\(session.host.hostname)")
            tv.startProcess(executable: "/usr/bin/ssh", args: args)
        }
        return tv
    }

    private func applyAppearance(_ appearance: TerminalAppearance, to terminalView: LocalProcessTerminalView) {
        let palette = appearance.palette
        terminalView.nativeBackgroundColor = palette.background
        terminalView.nativeForegroundColor = palette.foreground
        terminalView.font = appearance.makeFont()
        terminalView.caretColor = palette.cursor
    }

    // MARK: - Coordinator (LocalProcessTerminalViewDelegate)

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var session: SSHSession?
        init(session: SSHSession) { self.session = session }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in
                guard let session = self.session else { return }
                if session.status == .connecting, let exitCode, exitCode != 0 {
                    session.status = .failed
                } else {
                    session.status = .disconnected
                }
            }
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

// MARK: - Session cell

struct SessionCell: View {
    @ObservedObject var session: SSHSession
    @EnvironmentObject var appState: AppState
    var isFocused: Bool
    var sessionNumber: Int
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                 Circle()
                    .fill(session.status.color)
                    .frame(width: 8, height: 8)
                Text("S\(sessionNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(SwiftUI.Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .help(appState.t("拖曳可重新排序", "Drag to reorder"))
                    .onDrag {
                        dragProvider()
                    }
                Text(session.host.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(session.host.connectionLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { appState.closeSession(session) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(headerBackgroundColor)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !appState.isSessionDragModeEnabled else { return }
                focusLog("headerTap session=\(session.id.uuidString) previous=\(appState.focusedSessionId?.uuidString ?? "nil")")
                appState.focusedSessionId = session.id
                let accepted = session.focusTerminal()
                focusLog("headerTap focusResult session=\(session.id.uuidString) accepted=\(accepted)")
            }

            // Terminal — selection is handled by TerminalViewContainer.focusAndForward
            // at the AppKit level (mouseDown → set focusedSessionId → makeFirstResponder).
            TerminalSessionView(session: session)
            .id(session.id)
            .allowsHitTesting(!appState.isSessionDragModeEnabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .allowsHitTesting(!appState.isSessionDragModeEnabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(SessionFrameReporter(sessionID: session.id))
        .onDrop(of: [UTType.plainText.identifier], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .contextMenu {
            Button(appState.t("往前移", "Move Earlier")) { appState.moveSession(session, offset: -1) }
                .disabled(!appState.canMoveSession(session, offset: -1))
            Button(appState.t("往後移", "Move Later")) { appState.moveSession(session, offset: 1) }
                .disabled(!appState.canMoveSession(session, offset: 1))
            Divider()
            Button(appState.t("重新連線", "Reconnect")) { appState.reconnectSession(session) }
            Button(appState.t("關閉此 Session", "Close This Session")) { appState.closeSession(session) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            if appState.isSessionDragModeEnabled {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onDrag {
                        dragProvider()
                    }
                    .onDrop(of: [UTType.plainText.identifier], isTargeted: $isDropTarget) { providers in
                        handleDrop(providers)
                    }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    dropBorderColor,
                    lineWidth: isDropTarget ? 3 : (appState.isSessionDragModeEnabled ? 2 : (isFocused ? 2 : 1))
                )
        )
    }

    private func dragProvider() -> NSItemProvider {
        if appState.focusedSessionId != session.id {
            appState.focusedSessionId = session.id
        }
        return NSItemProvider(object: "\(sessionDragPayloadPrefix)\(session.id.uuidString)" as NSString)
    }

    private var headerBackgroundColor: SwiftUI.Color {
        if isDropTarget {
            return SwiftUI.Color.accentColor.opacity(0.35)
        }
        return isFocused ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color(NSColor.windowBackgroundColor).opacity(0.8)
    }

    private var dropBorderColor: SwiftUI.Color {
        if isDropTarget {
            return SwiftUI.Color.accentColor
        }
        if appState.isSessionDragModeEnabled {
            return SwiftUI.Color.red.opacity(0.9)
        }
        return isFocused ? SwiftUI.Color.accentColor : SwiftUI.Color.gray.opacity(0.3)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let rawString = object as? NSString else { return }
            let rawValue = String(rawString).trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawValue.hasPrefix(sessionDragPayloadPrefix) else { return }
            let sessionIDString = String(rawValue.dropFirst(sessionDragPayloadPrefix.count))
            guard let sessionID = UUID(uuidString: sessionIDString) else { return }

            Task { @MainActor in
                guard sessionID != session.id,
                      let sourceSession = appState.sessions.first(where: { $0.id == sessionID })
                else { return }
                appState.moveSession(sourceSession, to: session)
                focusLog("dropReorder source=\(sourceSession.id.uuidString) target=\(session.id.uuidString)")
                appState.focusedSessionId = sourceSession.id
                let accepted = sourceSession.focusTerminal()
                focusLog("dropReorder focusResult session=\(sourceSession.id.uuidString) accepted=\(accepted)")
            }
        }

        return true
    }
}

struct EmptySessionCell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.windowBackgroundColor).opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.15), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
