import SwiftUI

struct SessionGridView: View {
    @EnvironmentObject var appState: AppState

    private struct GridSlot: Identifiable {
        let id: String
        let session: SSHSession?
        let sessionNumber: Int?
    }

    // Sessions to display on the current view
    private var displayedSessions: [SSHSession] {
        let total = appState.sessions
        if total.count < 5 {
            return total  // 1–4: show all, no pagination
        }
        let start = appState.currentPage * 9
        let end = min(start + 9, total.count)
        return Array(total[start..<end])
    }

    // Grid dimensions based on session count
    private var gridConfig: (rows: Int, cols: Int) {
        switch displayedSessions.count {
        case 0, 1: return (1, 1)
        case 2:    return (1, 2)  // left | right
        case 3:    return (3, 1)  // stacked 3 rows
        case 4:    return (2, 2)  // 2×2
        default:   return (3, 3)
        }
    }

    private var useGrid: Bool { appState.sessions.count >= 5 }

    private var slotRows: [[GridSlot]] {
        let (rows, cols) = gridConfig
        let capacity = rows * cols
        var slots = displayedSessions.enumerated().map { index, session in
            let globalNum = (appState.sessions.firstIndex(where: { $0.id == session.id }) ?? index) + 1
            return GridSlot(
                id: session.id.uuidString,
                session: session,
                sessionNumber: globalNum
            )
        }

        if useGrid, slots.count < capacity {
            let emptySlots = (slots.count..<capacity).map { index in
                GridSlot(id: "empty-\(index)", session: nil, sessionNumber: nil)
            }
            slots.append(contentsOf: emptySlots)
        }

        return stride(from: 0, to: slots.count, by: cols).map { start in
            Array(slots[start..<min(start + cols, slots.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Array(slotRows.enumerated()), id: \.offset) { _, rowSlots in
                    HStack(spacing: 4) {
                        ForEach(rowSlots) { slot in
                            if let session = slot.session, let sessionNumber = slot.sessionNumber {
                                SessionCell(
                                    session: session,
                                    isFocused: appState.focusedSessionId == session.id,
                                    sessionNumber: sessionNumber
                                )
                            } else if useGrid {
                                EmptySessionCell()
                            } else {
                                Color.clear // no ghost cells in adaptive mode
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Page tab bar — only in grid mode
            if useGrid {
                Divider()
                TabBarView().frame(height: 36)
            }
        }
    }
}

struct TabBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<appState.pageCount, id: \.self) { page in
                let start = page * 9 + 1
                let end = min((page + 1) * 9, appState.sessions.count)
                let label = end >= start
                    ? appState.t("頁面 \(page + 1)（\(start)–\(end)）", "Page \(page + 1) (\(start)-\(end))")
                    : appState.t("頁面 \(page + 1)", "Page \(page + 1)")
                Button(label) { appState.currentPage = page }
                    .buttonStyle(TabButtonStyle(isSelected: appState.currentPage == page))
            }
            Spacer()
            Text(appState.t("\(appState.sessions.count) 個 Session", "\(appState.sessions.count) Sessions"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct TabButtonStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
