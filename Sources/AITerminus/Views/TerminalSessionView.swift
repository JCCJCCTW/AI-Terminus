import SwiftUI
import SwiftTerm
import AppKit
import UniformTypeIdentifiers

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
}

// Container NSView — hosts the terminal view and survives page switches.
// Uses layout() override to keep the terminal filling the container even
// when the container starts with frame .zero (autoresizingMask math breaks
// at zero size because 0/0 is undefined).
class TerminalViewContainer: NSView {
    private(set) var terminalView: LocalProcessTerminalView?
    var onFocused: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        if let tv = terminalView {
            if tv.window === window {
                window?.makeFirstResponder(tv)
            }
            tv.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    // Called whenever the container is resized — keeps the terminal filling bounds.
    override func layout() {
        super.layout()
        refreshTerminalLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        // Give the terminal keyboard focus once it's on screen.
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self, let tv, tv.window === self.window, let window = self.window else { return }
            window.makeFirstResponder(tv)
        }
    }

    func focusTerminal() {
        guard let tv = terminalView, tv.window === window else { return }
        window?.makeFirstResponder(tv)
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
    @ObservedObject var session: SSHSession
    var isFocused: Bool = false
    var onFocused: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalViewContainer {
        if let existingContainer = session.terminalContainer {
            existingContainer.onFocused = onFocused
            if let terminalView = session.terminalView, existingContainer.terminalView !== terminalView {
                existingContainer.attach(terminalView)
            }
            return existingContainer
        }

        let container = TerminalViewContainer(frame: .zero)
        container.onFocused = onFocused

        if let existing = session.terminalView {
            container.attach(existing)
        } else {
            let tv = makeTerminalView(coordinator: context.coordinator)
            container.attach(tv)
            // Set terminalView synchronously — it is not @Published so this is safe.
            // NSViewRepresentable.makeNSView is called on the main thread.
            MainActor.assumeIsolated {
                session.terminalView = tv
            }
            // Defer the @Published status change to the next runloop pass to avoid
            // "Publishing changes from within view updates" warnings.
            Task { @MainActor in
                session.status = .connected
            }
        }

        MainActor.assumeIsolated {
            session.terminalContainer = container
        }
        return container
    }

    func updateNSView(_ nsView: TerminalViewContainer, context: Context) {
        nsView.onFocused = onFocused
        if let tv = session.terminalView, nsView.terminalView !== tv {
            nsView.attach(tv)
        } else {
            nsView.needsLayout = true
            nsView.layoutSubtreeIfNeeded()
        }
        // When this session becomes focused, give the terminal keyboard focus.
        if isFocused, !context.coordinator.wasFocused {
            DispatchQueue.main.async {
                nsView.focusTerminal()
            }
        }
        context.coordinator.wasFocused = isFocused
    }

    private func makeTerminalView(coordinator: Coordinator) -> LocalProcessTerminalView {
        let tv = SessionTerminalView(frame: .zero)
        tv.nativeBackgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        tv.nativeForegroundColor = NSColor(calibratedRed: 0.9,  green: 0.9,  blue: 0.9,  alpha: 1)
        tv.processDelegate = coordinator
        tv.session = session

        var args: [String] = ["-o", "ServerAliveInterval=30"]
        if session.host.port != 22 { args += ["-p", "\(session.host.port)"] }
        if session.host.authMethod == .privateKey, !session.host.privateKeyPath.isEmpty {
            args += ["-i", session.host.privateKeyPath]
        }
        args.append("\(session.host.username)@\(session.host.hostname)")
        tv.startProcess(executable: "/usr/bin/ssh", args: args)
        return tv
    }

    // MARK: - Coordinator (LocalProcessTerminalViewDelegate)

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var session: SSHSession?
        var wasFocused = false
        init(session: SSHSession) { self.session = session }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in self.session?.status = .disconnected }
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
            // Header — SwiftUI tap gesture only here
            HStack(spacing: 6) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 8, height: 8)
                Text("S\(sessionNumber)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(session.host.displayTitle)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(session.host.connectionLabel)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { appState.closeSession(session) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(headerBackgroundColor)
            .contentShape(Rectangle())
            .onTapGesture { appState.focusedSessionId = session.id }
            .onDrag {
                if appState.focusedSessionId != session.id {
                    appState.focusedSessionId = session.id
                }
                return NSItemProvider(object: session.id.uuidString as NSString)
            }

            // Terminal — no SwiftUI gesture; AppKit handles clicks via TerminalViewContainer.mouseDown
            TerminalSessionView(session: session, isFocused: isFocused) {
                appState.focusedSessionId = session.id
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { appState.focusedSessionId = session.id }
        .onDrop(of: [UTType.text.identifier], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(dropBorderColor, lineWidth: isDropTarget ? 3 : (isFocused ? 2 : 1))
        )
    }

    private var headerBackgroundColor: SwiftUI.Color {
        if isDropTarget {
            return SwiftUI.Color.accentColor.opacity(0.35)
        }
        return isFocused ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color(NSColor.windowBackgroundColor).opacity(0.8)
    }

    private var dropBorderColor: SwiftUI.Color {
        isDropTarget ? SwiftUI.Color.accentColor : (isFocused ? SwiftUI.Color.accentColor : SwiftUI.Color.gray.opacity(0.3))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let rawString = object as? NSString else { return }
            let rawValue = String(rawString).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sessionID = UUID(uuidString: rawValue) else { return }

            Task { @MainActor in
                guard let sourceSession = appState.sessions.first(where: { $0.id == sessionID }) else { return }
                appState.moveSession(sourceSession, to: session)
                appState.focusedSessionId = sourceSession.id
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
