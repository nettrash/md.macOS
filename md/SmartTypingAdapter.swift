//
//  SmartTypingAdapter.swift
//  md
//
//  Created by nettrash on 22/09/2026.
//
//  The platform-neutral half of the editor's typing adapter — everything a
//  text view has to decide *around* the two pure functions in
//  `SmartTyping.swift` before it may call them, kept out of the view so it
//  can be unit-tested without a text view and read against the
//  specification's §3 side by side:
//
//  * `TypingSettings` — the two user toggles (`md.continueLists`,
//    `md.capitalizeSentences`), read live so a menu flip reaches every open
//    editor at once (§3.1).
//  * `SmartTypingAdapter.wordInsertionLeadLength` — the **word-insertion
//    reduction** (§3.3, first paragraph): the test that turns whatever the
//    system hands `insertText` (a key, a dead-key commit, a predicted word,
//    a dictated phrase, a pasted URL) into either "one scalar for
//    `capitalize`" or "insert as typed".
//  * `CapitalOverride` — the **tracked-capital state machine** (§3.4): it
//    follows the last capital md produced through every edit to the text,
//    and when an edit removes it, arms the override where that edit began
//    — the delete-and-retype gesture that lets `md`, `iOS` and `npm` start
//    a sentence without a fight.
//  * `SmartTypingAdapter.capital` — the rest of the decision for one
//    insertion, in the order the specification tests it: word insertion,
//    select-and-retype, then `SmartTyping.capitalize`.
//
//  The rules of `SmartTyping.swift` apply here too: offsets are UTF-16
//  units, whitespace is WS19 and nothing else, classes are
//  `Unicode.Scalar.Properties.generalCategory`, the uppercase mapping is
//  §0.7's guarded one-scalar mapping, and there is no regular expression and
//  no Foundation string search anywhere. `SmartTextView.swift` (macOS) is
//  the thin AppKit shell around this file.
//

import Foundation

// MARK: - Settings (§3.1)

/// The two typing preferences, both `true` by default. The keys are shared
/// by name with the iOS, Android and Windows editions; the menu's toggles
/// (`mdApp.swift`) bind to them through `@AppStorage`, and the editor asks
/// `UserDefaults` at every keystroke — there is no cached copy to go stale,
/// which is what lets a menu flip take effect in every open window at once.
enum TypingSettings {
    /// Return continues lists, tasks, quotes and tables (§1).
    static let continueListsKey = "md.continueLists"
    /// The first letter of a line and of a sentence is capitalized (§2).
    static let capitalizeSentencesKey = "md.capitalizeSentences"

    static func continueLists(in defaults: UserDefaults = .standard) -> Bool {
        isOn(continueListsKey, in: defaults)
    }

    static func capitalizeSentences(in defaults: UserDefaults = .standard) -> Bool {
        isOn(capitalizeSentencesKey, in: defaults)
    }

    /// Absent means on: a fresh install has neither key, and `bool(forKey:)`
    /// alone would read that absence as off.
    private static func isOn(_ key: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}

// MARK: - The override gesture (§3.4)

/// The tracked-capital state machine behind the delete-and-retype gesture
/// (§3.4, amended). It follows the **last** capital md produced — one
/// scalar, `capital`, at UTF-16 offset `p` — through every edit to the
/// text until an edit removes it; that edit **arms** the override at its
/// own start offset `q`, and the next word insertion (§3.3) that starts
/// exactly at `q` goes in as typed. In detail:
///
/// * `produced(at:capital:)` — md made a capital at `p`: it is the tracked
///   one from now on (the previous one is forgotten, not armed) and nothing
///   is armed.
/// * `edit(replacing:insertedLength:textAfter:)` — **every** edit to the
///   text, reported after it happened. With a capital tracked at `p`: an
///   edit whose range lies before `p` (an insertion at `p` itself included)
///   shifts `p` by the edit's length delta; an edit that removes the
///   capital scalar — a deletion or a replacement whose range covers it,
///   unless the inserted text puts that same scalar back at the same
///   offset (Redo does) — forgets it and arms the override at the edit's
///   start; an edit after `p` changes nothing. While armed at `q`: a
///   deletion before `q` shifts `q`, a deletion covering `q` moves `q` to
///   its start, an insertion anywhere other than `q` clears the override,
///   and an insertion at `q` leaves it armed — the retype itself is spent
///   by `insertion(…)` before the edit, so what reaches here at `q` is a
///   bracket, a space, a newline, a paste.
/// * `insertion(at:selectionLength:wordInsertion:)` — asked by the view
///   *before* it applies an insertion: true iff the insertion must go in
///   as typed because of the override, which is then spent. That is a word
///   insertion starting at `q` while armed — or a word insertion replacing
///   a selection the writer made that covers the tracked capital: the edit
///   removes the capital and arms the override at the selection's start,
///   exactly where the word lands, so the word is the retype (select the
///   word md capitalized and retype it, and it stays as typed). Any other
///   insertion while armed clears the override unless it starts at `q`.
/// * `clear()` — an external replacement of the whole text (open, revert,
///   reload, article switch).
///
/// Undo needs nothing of its own: the edit that restores the lowercase
/// letter is an edit that removed the capital, and arms the override at
/// `p`. The single-letter select-and-retype rule (§3.4's independent
/// rule, `SmartTypingAdapter.retypesOwnCapital`) is decided by the view
/// without asking here; its edit is then observed like any other, which
/// is what arms the override after it.
///
/// A tracked capital and an armed override never coexist: arming forgets
/// the capital, producing one clears the override. Pure value semantics;
/// every offset is a UTF-16 unit offset into the view's text.
struct CapitalOverride: Equatable {
    /// `p`, the offset of the tracked capital; nil when none is tracked.
    private(set) var capitalOffset: Int?
    /// The tracked capital's units — one scalar, one or two units; empty
    /// when none is tracked.
    private(set) var capital: [UInt16] = []
    /// `q`, the offset the override is armed at; nil when disarmed.
    private(set) var armedAt: Int?

    init() {}

    var isArmed: Bool { armedAt != nil }

    /// True when the override is armed at `offset`.
    func isArmed(at offset: Int) -> Bool { armedAt == offset }

    var tracksCapital: Bool { capitalOffset != nil }

    /// True when the tracked capital stands at `offset`.
    func tracksCapital(at offset: Int) -> Bool { capitalOffset == offset }

    /// md produced `capital` at `offset` (or Redo put it back).
    mutating func produced(at offset: Int, capital: [UInt16]) {
        capitalOffset = offset
        self.capital = capital
        armedAt = nil
    }

    /// An external replacement of the whole text.
    mutating func clear() {
        capitalOffset = nil
        capital = []
        armedAt = nil
    }

    /// The transition for an insertion the view is about to apply over
    /// `[start, start + selectionLength)`, where `selectionLength` is the
    /// length of a selection *the writer made* (0 for a collapsed caret,
    /// and 0 for a range the system chose — a dead-key commit, the accent
    /// popover's pick, a completion — which is judged by the edit alone).
    /// `wordInsertion` says whether the insertion is a word insertion
    /// (§3.3), the kind the override exists for. Returns true iff the
    /// insertion must go in as typed because of the override, which is
    /// then spent.
    mutating func insertion(at start: Int, selectionLength: Int, wordInsertion: Bool) -> Bool {
        if let q = armedAt {
            if start != q {
                armedAt = nil                   // an insertion elsewhere clears
                return false
            }
            guard wordInsertion else { return false }   // a bracket, a space, a newline at q: still armed
            armedAt = nil
            return true
        }
        // A selection the writer made that covers the tracked capital: the
        // edit removes the capital and arms the override at the selection's
        // start — where this very word lands. It is the retype.
        if let p = capitalOffset, wordInsertion, selectionLength > 0,
           start <= p, p < start + selectionLength {
            capitalOffset = nil
            capital = []
            return true
        }
        return false
    }

    /// The transition for an edit that replaced `range` of the text as it
    /// was with `insertedLength` units, `textAfter` being the text as it
    /// now is (read only where the tracked capital may have been put back).
    /// Every edit, whoever made it — a keystroke, Backspace, forward
    /// delete, Cut, Paste, a drop, Undo, Redo, the Return edit — goes
    /// through here, after it happened.
    mutating func edit(replacing range: NSRange, insertedLength: Int, textAfter: NSString) {
        let start = range.location
        let end = range.location + range.length
        if let p = capitalOffset {
            if end <= p {
                // Before the capital (an insertion at `p` included): it
                // moves with the text.
                capitalOffset = p + insertedLength - range.length
            } else if start < p + capital.count {
                // The range overlaps the capital scalar: removed — unless
                // the inserted text put the same scalar back at `p`.
                let putBack = insertedLength > 0 && start <= p
                    && p + capital.count <= start + insertedLength
                    && stands(in: textAfter, at: p)
                if !putBack {
                    capitalOffset = nil
                    capital = []
                    armedAt = start
                }
            }
            // After the capital: nothing.
        } else if let q = armedAt {
            if insertedLength == 0 {
                // A deletion never clears; it keeps `q` on the slot.
                if end <= q {
                    armedAt = q - range.length
                } else if start < q {
                    armedAt = start
                }
            } else if start != q {
                armedAt = nil                   // an insertion elsewhere clears
            }
        }
    }

    /// Whether `text` carries the tracked capital at `offset`, unit for unit.
    private func stands(in text: NSString, at offset: Int) -> Bool {
        guard !capital.isEmpty, offset >= 0, offset + capital.count <= text.length else { return false }
        for (i, unit) in capital.enumerated() where text.character(at: offset + i) != unit {
            return false
        }
        return true
    }
}

// MARK: - The adapter's decisions (§3.3)

enum SmartTypingAdapter {

    /// What the text view does with one insertion when `capital` says yes:
    /// insert the text as typed, then replace its first scalar (`leadLength`
    /// UTF-16 units at the insertion's start) with `capital`, as a separate
    /// undo step (§3.5).
    struct Decision: Equatable {
        let leadLength: Int
        let capital: String
    }

    /// §3.3, first paragraph — the **word-insertion reduction**. An
    /// insertion is a word insertion iff it contains no line terminator and
    /// no WS19 unit except at most one trailing SP, its first scalar is a
    /// Lowercase letter (`Ll`), and it contains none of `://`, `www.`, `@`,
    /// `/` (§2.1f applied to the insertion itself: a predicted or pasted
    /// `https://a.b`, `~/Documents/x` or `@nettrash` goes in unchanged — the
    /// pure function sees only the first scalar and could not tell).
    ///
    /// Returns the UTF-16 length of that first scalar (1, or 2 for a
    /// supplementary-plane letter such as Deseret), or nil when the
    /// insertion is not a word insertion.
    static func wordInsertionLeadLength(_ insertion: String) -> Int? {
        let units = Array(insertion.utf16)
        guard let (lead, length) = firstScalar(of: units, at: 0),
              lead.properties.generalCategory == .lowercaseLetter else { return nil }
        var i = 0
        while i < units.count {
            let u = units[i]
            if u == 0x0A || u == 0x0D { return nil }                 // a line terminator
            if isWS19(u) && !(u == 0x20 && i == units.count - 1) { return nil }
            if u == 0x40 || u == 0x2F { return nil }                   // `@`, `/` (which covers `://`)
            if u == 0x77, i + 3 < units.count,                        // `www.`
               units[i + 1] == 0x77, units[i + 2] == 0x77, units[i + 3] == 0x2E { return nil }
            i += 1
        }
        return length
    }

    /// The whole decision for one insertion into `text` over the selection
    /// `[selectionStart, selectionEnd)` (either order), in the order the
    /// specification tests it — after the caller has asked its
    /// `CapitalOverride` (§3.4) and been told the insertion is not a retype:
    ///
    /// 1. not a word insertion → as typed;
    /// 2. a single lowercase letter typed over a one-scalar selection whose
    ///    scalar is that letter's `upper` → as typed (§3.4, independent of
    ///    the override: the select-and-retype gesture);
    /// 3. `SmartTyping.capitalize` with the first scalar as `typed`.
    static func capital(text: String, selectionStart: Int, selectionEnd: Int,
                        insertion: String) -> Decision? {
        guard let lead = wordInsertionLeadLength(insertion) else { return nil }
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)

        let insertionUnits = Array(insertion.utf16)
        let typed = String(decoding: insertionUnits[0..<lead], as: UTF16.self)
        // Select-and-retype: `H` selected, `h` typed → `h`.
        if retypesOwnCapital(text: text, selectionStart: start, selectionEnd: end, insertion: insertion) {
            return nil
        }
        guard let capital = SmartTyping.capitalize(text, selectionStart: start, selectionEnd: end,
                                                   typed: typed) else { return nil }
        return Decision(leadLength: lead, capital: capital)
    }

    /// §3.4's independent rule: true iff `insertion` is a single lowercase
    /// letter (one scalar of category `Ll`) and `[selectionStart,
    /// selectionEnd)` (either order) of `text` is exactly one scalar, that
    /// letter's `upper` (§0.7). Such a letter is always inserted as typed,
    /// override or no override — and when the scalar it replaces is the
    /// capital md is tracking, the edit removes it and arms the override
    /// (`CapitalOverride.edit`), so a further delete-and-retype at the
    /// same slot stays lowercase too.
    static func retypesOwnCapital(text: String, selectionStart: Int, selectionEnd: Int,
                                  insertion: String) -> Bool {
        let insertionUnits = Array(insertion.utf16)
        guard let (typedScalar, length) = firstScalar(of: insertionUnits, at: 0),
              length == insertionUnits.count,
              typedScalar.properties.generalCategory == .lowercaseLetter else { return false }
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)
        guard let selected = singleScalar(of: Array(text.utf16), from: start, to: end),
              let upper = upper(typedScalar) else { return false }
        return selected == upper
    }

    /// §3.3, macOS — the press-and-hold accent popover. The popover always
    /// follows a key: the letter is inserted first (and capitalized by md
    /// where the rule applies), then the pick replaces that one scalar
    /// over an explicit range. When the scalar it replaces is a Lowercase
    /// letter, the letter stands lowercase on purpose — the rule declined
    /// it (`Cafe` → `Café`), or the override was honoured (`e` → `E`,
    /// Backspace, `e`, then `é`) — and the pick keeps it. Over a capital
    /// (the `E` md just made) the pick goes through `capitalize` instead
    /// and `école` at a sentence start becomes `École`.
    ///
    /// True iff `insertion` is exactly one scalar and `[selectionStart,
    /// selectionEnd)` (either order) of `text` is exactly one scalar of
    /// category `Ll`. The caller applies it to explicit-range insertions
    /// only; a selection the writer made is the select-and-retype rule's.
    static func replacesOneLowercaseScalar(text: String, selectionStart: Int, selectionEnd: Int,
                                           insertion: String) -> Bool {
        let insertionUnits = Array(insertion.utf16)
        guard let (_, length) = firstScalar(of: insertionUnits, at: 0),
              length == insertionUnits.count else { return false }
        let start = min(selectionStart, selectionEnd)
        let end = max(selectionStart, selectionEnd)
        guard let replaced = singleScalar(of: Array(text.utf16), from: start, to: end) else { return false }
        return replaced.properties.generalCategory == .lowercaseLetter
    }

    // MARK: Scalars

    /// §0.3 — the 19 whitespace units, and nothing else.
    static func isWS19(_ u: UInt16) -> Bool {
        switch u {
        case 0x09, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x200B, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// §0.7 — the simple, one-to-one, locale-independent uppercase mapping,
    /// or nil where the specification leaves `upper` undefined: a mapping
    /// that is not exactly one scalar, one that equals the scalar itself,
    /// Georgian, the Greek ypogegrammeni letters and MICRO SIGN.
    static func upper(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let v = scalar.value
        if (0x10D0...0x10FF).contains(v) || (0x2D00...0x2D2F).contains(v)
            || (0x1F80...0x1FAF).contains(v) || v == 0x1FB3 || v == 0x1FC3 || v == 0x1FF3
            || v == 0xB5 {
            return nil
        }
        let mapped = scalar.properties.uppercaseMapping.unicodeScalars
        guard mapped.count == 1, let result = mapped.first, result != scalar else { return nil }
        return result
    }

    /// The scalar starting at unit `index`, with its UTF-16 length; nil at
    /// the end, and nil for a lone surrogate half (a scalar of category
    /// `Cs`, which belongs to no class the rules use).
    static func firstScalar(of units: [UInt16], at index: Int) -> (Unicode.Scalar, Int)? {
        guard index >= 0, index < units.count else { return nil }
        let u = units[index]
        if u >= 0xD800 && u <= 0xDBFF {
            guard index + 1 < units.count else { return nil }
            let low = units[index + 1]
            guard low >= 0xDC00 && low <= 0xDFFF else { return nil }
            let value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
            guard let scalar = Unicode.Scalar(value) else { return nil }
            return (scalar, 2)
        }
        if u >= 0xDC00 && u <= 0xDFFF { return nil }
        guard let scalar = Unicode.Scalar(u) else { return nil }
        return (scalar, 1)
    }

    /// `units[from..<to]` when that range is exactly one scalar; else nil.
    private static func singleScalar(of units: [UInt16], from: Int, to: Int) -> Unicode.Scalar? {
        guard from >= 0, to <= units.count, to > from,
              let (scalar, length) = firstScalar(of: units, at: from),
              from + length == to else { return nil }
        return scalar
    }
}
