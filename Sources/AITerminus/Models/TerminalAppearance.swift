import AppKit
import Foundation

enum TerminalThemePreset: String, CaseIterable, Codable, Identifiable {
    case midnight
    case solarizedDark
    case paperLight
    case matrix

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .midnight:
            return localizedAppText("午夜", "Midnight")
        case .solarizedDark:
            return "Solarized Dark"
        case .paperLight:
            return localizedAppText("紙張淺色", "Paper Light")
        case .matrix:
            return "Matrix"
        }
    }

    var localizedDescription: String {
        switch self {
        case .midnight:
            return localizedAppText("深色、高對比，適合長時間 SSH。", "Dark, high-contrast, and comfortable for long SSH sessions.")
        case .solarizedDark:
            return localizedAppText("低刺激經典配色，適合程式與文字混合輸出。", "A classic low-glare palette for mixed code and text output.")
        case .paperLight:
            return localizedAppText("淺底深字，適合白天與文件導向工作。", "Light background with dark text for daytime and document-heavy work.")
        case .matrix:
            return localizedAppText("黑底綠字，偏向監控與操作感。", "Black-and-green styling with a more tactical feel.")
        }
    }

    var appearance: TerminalPalette {
        switch self {
        case .midnight:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1),
                foreground: NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1),
                cursor: NSColor(calibratedRed: 0.48, green: 0.75, blue: 1.00, alpha: 1),
                selection: NSColor(calibratedRed: 0.23, green: 0.30, blue: 0.41, alpha: 1)
            )
        case .solarizedDark:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.00, green: 0.17, blue: 0.21, alpha: 1),
                foreground: NSColor(calibratedRed: 0.51, green: 0.58, blue: 0.59, alpha: 1),
                cursor: NSColor(calibratedRed: 0.71, green: 0.54, blue: 0.00, alpha: 1),
                selection: NSColor(calibratedRed: 0.03, green: 0.21, blue: 0.26, alpha: 1)
            )
        case .paperLight:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1),
                foreground: NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.23, alpha: 1),
                cursor: NSColor(calibratedRed: 0.18, green: 0.34, blue: 0.72, alpha: 1),
                selection: NSColor(calibratedRed: 0.83, green: 0.88, blue: 0.96, alpha: 1)
            )
        case .matrix:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.01, green: 0.04, blue: 0.02, alpha: 1),
                foreground: NSColor(calibratedRed: 0.45, green: 1.00, blue: 0.54, alpha: 1),
                cursor: NSColor(calibratedRed: 0.74, green: 1.00, blue: 0.76, alpha: 1),
                selection: NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.10, alpha: 1)
            )
        }
    }
}

struct TerminalPalette: Equatable {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
}

enum TerminalFontPreset: String, CaseIterable, Codable, Identifiable {
    case menlo
    case sfMono
    case monaco
    case courierPrime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .menlo:
            return "Menlo"
        case .sfMono:
            return "SF Mono"
        case .monaco:
            return "Monaco"
        case .courierPrime:
            return "Courier New"
        }
    }

    var fontNames: [String] {
        switch self {
        case .menlo:
            return ["Menlo-Regular", "Menlo"]
        case .sfMono:
            return ["SFMono-Regular", ".SFNSMono-Regular", "SF Mono"]
        case .monaco:
            return ["Monaco"]
        case .courierPrime:
            return ["CourierNewPSMT", "Courier New", "Courier"]
        }
    }
}

struct TerminalAppearance: Codable, Equatable {
    var themePreset: TerminalThemePreset = .midnight
    var fontPreset: TerminalFontPreset = .menlo
    var fontSize: Double = 13

    var palette: TerminalPalette {
        themePreset.appearance
    }

    func makeFont() -> NSFont {
        let size = min(max(fontSize, 10), 28)
        for fontName in fontPreset.fontNames {
            if let font = NSFont(name: fontName, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
