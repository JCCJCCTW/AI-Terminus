import AppKit
import Foundation

enum TerminalThemePreset: String, CaseIterable, Codable, Identifiable {
    case midnight
    case solarizedDark
    case paperLight
    case matrix
    case oceanBlue
    case dracula
    case nord
    case monokai

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
        case .oceanBlue:
            return localizedAppText("海洋藍", "Ocean Blue")
        case .dracula:
            return "Dracula"
        case .nord:
            return "Nord"
        case .monokai:
            return "Monokai"
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
        case .oceanBlue:
            return localizedAppText("深藍底色搭配柔和藍字，沉穩專業。", "Deep navy with soft blue text, calm and professional.")
        case .dracula:
            return localizedAppText("經典紫色調暗色主題，色彩飽和鮮明。", "Popular purple-toned dark theme with vivid colors.")
        case .nord:
            return localizedAppText("北極冷色調，低對比護眼配色。", "Arctic cool tones with low contrast, easy on the eyes.")
        case .monokai:
            return localizedAppText("暖色調深色主題，經典編輯器配色。", "Warm dark theme inspired by the classic editor palette.")
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
        case .oceanBlue:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.18, alpha: 1),
                foreground: NSColor(calibratedRed: 0.68, green: 0.78, blue: 0.90, alpha: 1),
                cursor: NSColor(calibratedRed: 0.40, green: 0.72, blue: 0.96, alpha: 1),
                selection: NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.32, alpha: 1)
            )
        case .dracula:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.21, alpha: 1),
                foreground: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.95, alpha: 1),
                cursor: NSColor(calibratedRed: 0.74, green: 0.58, blue: 0.98, alpha: 1),
                selection: NSColor(calibratedRed: 0.27, green: 0.28, blue: 0.35, alpha: 1)
            )
        case .nord:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.25, alpha: 1),
                foreground: NSColor(calibratedRed: 0.85, green: 0.87, blue: 0.91, alpha: 1),
                cursor: NSColor(calibratedRed: 0.53, green: 0.75, blue: 0.82, alpha: 1),
                selection: NSColor(calibratedRed: 0.26, green: 0.30, blue: 0.37, alpha: 1)
            )
        case .monokai:
            return TerminalPalette(
                background: NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.13, alpha: 1),
                foreground: NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.95, alpha: 1),
                cursor: NSColor(calibratedRed: 0.90, green: 0.86, blue: 0.45, alpha: 1),
                selection: NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.25, alpha: 1)
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
