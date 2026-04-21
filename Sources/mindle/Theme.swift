import SwiftUI
import AppKit

struct ThemeColors {
    let background: Color
    let surface: Color
    let sidebar: Color
    let text: Color
    let muted: Color
    let accent: Color
    let highlight: Color      // plain highlight (no note)
    let highlightNote: Color  // highlight that has a note
    let rule: Color
    let codeBg: Color
    let selectionTint: Color
}

extension ReaderTheme {
    var colors: ThemeColors {
        switch self {
        case .light:
            return ThemeColors(
                background:    Color(red: 0.99, green: 0.99, blue: 0.99),
                surface:       Color(red: 1.00, green: 1.00, blue: 1.00),
                sidebar:       Color(red: 0.96, green: 0.96, blue: 0.97),
                text:          Color(red: 0.12, green: 0.12, blue: 0.14),
                muted:         Color(red: 0.45, green: 0.45, blue: 0.50),
                accent:        Color(red: 0.25, green: 0.47, blue: 0.87),
                highlight:     Color(red: 1.00, green: 0.88, blue: 0.40).opacity(0.55),
                highlightNote: Color(red: 1.00, green: 0.70, blue: 0.35).opacity(0.55),
                rule:          Color(red: 0.85, green: 0.85, blue: 0.87),
                codeBg:        Color(red: 0.95, green: 0.95, blue: 0.96),
                selectionTint: Color(red: 0.60, green: 0.75, blue: 1.00).opacity(0.35)
            )
        case .sepia:
            return ThemeColors(
                background:    Color(red: 0.96, green: 0.92, blue: 0.84),
                surface:       Color(red: 0.98, green: 0.95, blue: 0.87),
                sidebar:       Color(red: 0.93, green: 0.89, blue: 0.80),
                text:          Color(red: 0.24, green: 0.19, blue: 0.13),
                muted:         Color(red: 0.50, green: 0.42, blue: 0.30),
                accent:        Color(red: 0.60, green: 0.35, blue: 0.15),
                highlight:     Color(red: 0.95, green: 0.75, blue: 0.30).opacity(0.55),
                highlightNote: Color(red: 0.90, green: 0.50, blue: 0.20).opacity(0.50),
                rule:          Color(red: 0.80, green: 0.72, blue: 0.60),
                codeBg:        Color(red: 0.92, green: 0.87, blue: 0.76),
                selectionTint: Color(red: 0.60, green: 0.40, blue: 0.20).opacity(0.30)
            )
        case .dark:
            return ThemeColors(
                background:    Color(red: 0.10, green: 0.10, blue: 0.12),
                surface:       Color(red: 0.14, green: 0.14, blue: 0.17),
                sidebar:       Color(red: 0.12, green: 0.12, blue: 0.15),
                text:          Color(red: 0.90, green: 0.90, blue: 0.92),
                muted:         Color(red: 0.60, green: 0.60, blue: 0.65),
                accent:        Color(red: 0.55, green: 0.78, blue: 1.00),
                highlight:     Color(red: 0.95, green: 0.80, blue: 0.30).opacity(0.32),
                highlightNote: Color(red: 1.00, green: 0.55, blue: 0.25).opacity(0.38),
                rule:          Color(red: 0.30, green: 0.30, blue: 0.33),
                codeBg:        Color(red: 0.18, green: 0.18, blue: 0.22),
                selectionTint: Color(red: 0.45, green: 0.65, blue: 0.95).opacity(0.30)
            )
        }
    }
}

extension Color {
    var asNSColor: NSColor { NSColor(self) }
}
