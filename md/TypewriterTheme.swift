//
//  TypewriterTheme.swift
//  md
//
//  Created by nettrash on 29/06/2026.
//
//  The app's typewriter aesthetic gathered in one place: the paper-and-ink
//  palette and the typewriter fonts. This is the macOS (AppKit) sibling of
//  the iOS theme — the SwiftUI side is identical, only the platform mirrors
//  for the `NSTextView`-backed editor differ (`NSFont` / `NSColor` instead
//  of `UIFont` / `UIColor`).
//
//  The colors are keyed off the app icon's warm scheme — a light "fresh
//  paper" (warm off-white, dark sepia ink) and a dark "carbon paper"
//  (warm near-black, soft cream ink) — and live in the asset catalog
//  (`PaperBackground`, `PaperBackgroundSecondary`, `PaperInk`,
//  `AccentColor`) so AppKit and SwiftUI both get the light/dark variants
//  for free.
//
//  Prose — headings, body text and the raw editor — is set in American
//  Typewriter, the slab serif that gives the app the feel of a typed page.
//  Code spans and fenced blocks fall back to Courier New, where monospaced
//  columns matter.
//

import SwiftUI
import AppKit

enum Typewriter {

    // MARK: - Font families

    /// The slab-serif prose face the whole app is built around.
    static let prose = "American Typewriter"
    /// The monospaced face used for code, where character alignment matters.
    static let mono = "Courier New"

    // MARK: - SwiftUI fonts

    /// A prose font (American Typewriter). `relativeTo:` is kept for parity
    /// with the iOS theme and so the size still tracks the system's
    /// accessibility text-size preference on macOS.
    static func font(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(prose, size: size, relativeTo: style)
    }

    /// A monospaced font (Courier New), for code.
    static func code(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(mono, size: size, relativeTo: style)
    }

    // MARK: - AppKit font (editor)

    /// American Typewriter's PostScript name. `NSFont(name:)` wants the
    /// PostScript name, not the "American Typewriter" family name — so the
    /// editor uses this directly to avoid silently falling back to the
    /// system font.
    static let proseNSName = "AmericanTypewriter"

    /// The editor's `NSFont`: American Typewriter at a comfortable desktop
    /// reading size. Falls back to the system monospaced font only if the
    /// face is missing.
    static func editorFont(size: CGFloat = 15) -> NSFont {
        NSFont(name: proseNSName, size: size)
            ?? NSFont(name: prose, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Colors (asset-backed → adapt to light / dark automatically)

    /// The page itself: warm off-white in light mode, warm near-black in dark.
    static let paper = Color("PaperBackground")
    /// Slightly contrasting paper for code-block / table chrome.
    static let paperSecondary = Color("PaperBackgroundSecondary")
    /// The "ink" — primary text color that sits on `paper`.
    static let ink = Color("PaperInk")

    /// AppKit mirrors, for the `NSTextView`-backed editor.
    static let paperNSColor = NSColor(named: "PaperBackground") ?? .textBackgroundColor
    static let inkNSColor = NSColor(named: "PaperInk") ?? .labelColor
    static let accentNSColor = NSColor(named: "AccentColor") ?? .controlAccentColor
}
