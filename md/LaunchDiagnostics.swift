//
//  LaunchDiagnostics.swift
//  md
//
//  A DEBUG-only harness for observing the running app from the outside —
//  the macOS sibling of the iOS app's file of the same name.
//
//  Why it exists: this app has no UI-test target, and what a release check
//  needs to *see* — the menu bar as AppKit really built it, which window is
//  key and what its first responder is, the text an editor holds after a
//  run of real keystrokes (is there a U+2028 in it?), the pid of the web
//  content process behind a preview so that it can be killed on purpose —
//  is invisible from a shell and unreadable off a screenshot. So the app
//  can be asked, from the command line, to dump those things:
//
//      md.app/Contents/MacOS/md -mdDiagCommands /tmp/md-diag
//
//  With that argument the app polls the named file four times a second.
//  Whenever it appears it is read, deleted, and each of its lines run as
//  one command:
//
//      menu             the whole main menu, one line per item, with chords
//      windows          every window: title, key/main, document, panes, bar
//      responders       the key window's responder chain, first to last
//      text             the key window's editor text (Swift-escaped) + caret
//      findbar          whether the key window's find bar is up, and its fields
//      doc              the key window's NSDocument: file, edited, undo state
//      webpid           pid of the web content process behind the key window
//      js <script>      evaluate <script> in the key window's preview
//      focus X          first responder ← editor | preview | window
//      insert <text>    type <text> into the editor at the caret (insertText);
//                       `insert type:<keys>` types key by key, `\n` = Return
//      press <title>    click the window's button with that title
//      appearance X     force the app's appearance: dark, light or system
//      menuitem A > B   perform a main-menu item by its title path
//                       (`menuitem File > Examples > Diagrams`, `menuitem View > Split`)
//      frame W H        size the key window to W × H points, near the top left
//      activate         bring the app forward and make the newest document
//                       window key (a harness launched from a shell is not)
//      openfile <path>  open a document, as File ▸ Open… would (a path the
//                       sandbox can already read: the app's own container)
//      findstring <s>   put <s> on the find pasteboard, as ⌘E does, so the
//                       next find bar opens searching for it
//      examplebook      unpack the example book into the app's own container
//                       and remember it — File ▸ Examples ▸ Example Book…
//                       minus its save panel, which a script cannot answer;
//                       refuses to run outside a sandbox container
//      discard          mark every document clean (a harness exit, not a save)
//      closeall         close every document and window (after discard)
//      quit             terminate the app
//
//  A command may name the window it acts on with `@<number>` (`text@9910`,
//  `js@9910 …`), the number being the one `windows` prints; without it the
//  key window is used, or the frontmost document window when the app has
//  none.
//
//  Every line of output goes to os_log (subsystem `me.nettrash.md`,
//  category `diag`, public) and is appended to `<file>.out`; each command
//  ends with a `-- end <command>` line so a script can wait for it.
//
//      log stream --predicate 'subsystem == "me.nettrash.md"'
//
//  Every command only *reads* — except `focus`, `insert` and `press` (a
//  click's or a keystroke's worth of input) and `appearance`, `discard`,
//  `closeall` and `quit`, which are how a scripted run stays short and
//  leaves nothing behind. All
//  of it goes through public AppKit / WebKit API, save the one private
//  property `webpid` asks for, guarded by `responds(to:)`.
//
//  The whole file is `#if DEBUG`: nothing here is compiled into a Release
//  build, and the single call site in `mdApp.init` is guarded the same way.
//

#if DEBUG

import AppKit
import SwiftUI
import WebKit
import os

@MainActor
enum LaunchDiagnostics {

    static let log = Logger(subsystem: "me.nettrash.md", category: "diag")

    // MARK: - Arguments

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// The word after `flag`, when there is one.
    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        let next = arguments[i + 1]
        return next.hasPrefix("-") ? nil : next
    }

    private static var commandFile: URL?
    private static var timer: Timer?

    /// Called once from `mdApp.init`. Does nothing at all — no timer, no
    /// log line — unless `-mdDiagCommands <file>` was given.
    static func install() {
        guard let path = value(after: "-mdDiagCommands") else { return }
        commandFile = URL(fileURLWithPath: path)
        log.notice("diag: installed, watching \(path, privacy: .public)")
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        // `.common` so the poll keeps running under a modal panel (a save
        // panel, the print panel) — that is exactly when a dump is wanted.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func poll() {
        guard let file = commandFile,
              let data = try? Data(contentsOf: file),
              let contents = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        for line in contents.split(separator: "\n") {
            let command = line.trimmingCharacters(in: .whitespaces)
            if !command.isEmpty { run(command) }
        }
    }

    // MARK: - Output

    private static func emit(_ line: String) {
        log.notice("\(line, privacy: .public)")
        guard let file = commandFile else { return }
        let out = URL(fileURLWithPath: file.path + ".out")
        let bytes = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: out) {
            handle.seekToEndOfFile()
            handle.write(bytes)
            try? handle.close()
        } else {
            try? bytes.write(to: out)
        }
    }

    private static func end(_ command: String) { emit("-- end \(command)") }

    // MARK: - Commands

    private static func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        var command = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        emit("== \(line)")
        // `text@9910` — aim a command at one window by its number instead of
        // at the key window, so a run does not depend on which app is
        // frontmost on the desktop at that moment.
        targetWindow = nil
        if let at = command.firstIndex(of: "@") {
            let number = Int(command[command.index(after: at)...]) ?? 0
            command = String(command[..<at])
            targetWindow = NSApp.windows.first { $0.windowNumber == number }
            if targetWindow == nil { emit("no window #\(number)") }
        }
        switch command {
        case "menu": dumpMenu()
        case "windows": dumpWindows()
        case "responders": dumpResponders()
        case "text": dumpText()
        case "findbar": dumpFindBar()
        case "doc": dumpDocument()
        case "webpid": dumpWebProcess()
        case "js": evaluate(argument); return          // ends itself, asynchronously
        case "focus": focus(argument)
        case "insert": insert(argument)
        case "press": press(argument)
        case "appearance": setAppearance(argument)
        case "menuitem": performMenuItem(argument)
        case "frame": setFrame(argument)
        case "examplebook": installExampleBook()
        case "openfile": openFile(argument)
        case "activate": activate()
        case "findstring": setFindString(argument)
        case "discard": discardAll()
        case "closeall": closeAll()
        case "quit":
            end(command)
            NSApp.terminate(nil)
            return
        default: emit("unknown command: \(command)")
        }
        end(command)
    }

    // MARK: menu

    private static func dumpMenu() {
        guard let main = NSApp.mainMenu else { emit("no main menu"); return }
        let titles = main.items.map(\.title)
        emit("top-level (\(titles.count)): " + titles.joined(separator: " | "))
        let duplicates = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        emit("top-level duplicates: \(duplicates.isEmpty ? "none" : duplicates.joined(separator: ", "))")
        for item in main.items {
            if let submenu = item.submenu { dump(menu: submenu, path: item.title, depth: 1) }
        }
    }

    private static func dump(menu: NSMenu, path: String, depth: Int) {
        var titles: [String] = []
        for item in menu.items {
            if item.isSeparatorItem { emit("\(String(repeating: "  ", count: depth))---"); continue }
            titles.append(item.title)
            let chord = describe(item)
            emit("\(String(repeating: "  ", count: depth))\(item.title)\(chord)")
            if let submenu = item.submenu {
                dump(menu: submenu, path: path + " > " + item.title, depth: depth + 1)
            }
        }
        let duplicates = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        if !duplicates.isEmpty {
            emit("\(String(repeating: "  ", count: depth))!! duplicate rows in \(path): \(duplicates.joined(separator: ", "))")
        }
    }

    /// ` [⌥⌘F] on/off ✓` — the chord, the enabled state, the tick.
    private static func describe(_ item: NSMenuItem) -> String {
        var out = ""
        if !item.keyEquivalent.isEmpty {
            let mods = item.keyEquivalentModifierMask
            var chord = ""
            if mods.contains(.control) { chord += "⌃" }
            if mods.contains(.option) { chord += "⌥" }
            if mods.contains(.shift) { chord += "⇧" }
            if mods.contains(.command) { chord += "⌘" }
            let key: String
            switch item.keyEquivalent {
            case "\r": key = "↩"
            case "\u{F700}": key = "↑"
            case "\u{F701}": key = "↓"
            case "\u{F702}": key = "←"
            case "\u{F703}": key = "→"
            default: key = item.keyEquivalent.uppercased()
            }
            out += " [\(chord)\(key)]"
        }
        out += item.isEnabled ? " on" : " off"
        if item.state == .on { out += " ✓" }
        return out
    }

    // MARK: windows

    private static func dumpWindows() {
        let windows = NSApp.windows
        emit("windows: \(windows.count); key=\(NSApp.keyWindow.map { String($0.windowNumber) } ?? "none") main=\(NSApp.mainWindow.map { String($0.windowNumber) } ?? "none")")
        for window in windows {
            emit(describe(window))
        }
        emit("documents: \(NSDocumentController.shared.documents.count)")
        for document in NSDocumentController.shared.documents {
            emit("  document \(document.displayName ?? "?") file=\(document.fileURL?.path ?? "nil") type=\(document.fileType ?? "nil") edited=\(document.isDocumentEdited)")
        }
    }

    private static func describe(_ window: NSWindow) -> String {
        var flags: [String] = []
        if window.isVisible { flags.append("visible") }
        if window.isKeyWindow { flags.append("key") }
        if window.isMainWindow { flags.append("main") }
        if window.styleMask.contains(.fullScreen) { flags.append("fullscreen") }
        if window.isSheet { flags.append("sheet") }
        if window.attachedSheet != nil { flags.append("has-sheet") }
        if window.isMiniaturized { flags.append("mini") }
        if window.level != .normal { flags.append("level=\(window.level.rawValue)") }
        let editor = DocumentCommands.firstEditor(in: window.contentView)
        let web = firstWebView(in: window.contentView)
        var panes: [String] = []
        if editor != nil { panes.append("editor") }
        if web != nil { panes.append("preview") }
        let bar = editor?.enclosingScrollView?.isFindBarVisible == true ? " findbar" : ""
        let document = NSDocumentController.shared.document(for: window)
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "  #\(window.windowNumber) \(String(describing: type(of: window))) '\(window.title)' [\(flags.joined(separator: ","))] panes=\(panes.joined(separator: "+"))\(bar) doc=\(document?.fileURL?.lastPathComponent ?? (document == nil ? "none" : "untitled")) edited=\(document?.isDocumentEdited ?? false) firstResponder=\(responder) frame=\(NSStringFromRect(window.frame))"
    }

    static func firstWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let web = view as? WKWebView { return web }
        for subview in view.subviews {
            if let found = firstWebView(in: subview) { return found }
        }
        return nil
    }

    /// The window a `@N` suffix named for the current command, if any.
    private static var targetWindow: NSWindow?

    /// The window a command acts on: the one named with `@N`, else the key
    /// window, else — when the app is not active and has no key window at
    /// all — the frontmost visible document or book window.
    private static var keyWindow: NSWindow? {
        if let targetWindow { return targetWindow }
        if let key = NSApp.keyWindow ?? NSApp.mainWindow { return key }
        return NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil
            && (DocumentCommands.firstEditor(in: $0.contentView) != nil || firstWebView(in: $0.contentView) != nil) }
    }

    // MARK: responders

    private static func dumpResponders() {
        guard let window = keyWindow else { emit("no key window"); return }
        emit("key window #\(window.windowNumber) '\(window.title)'")
        var responder: NSResponder? = window.firstResponder
        var chain: [String] = []
        while let current = responder, chain.count < 60 {
            chain.append(String(describing: type(of: current)))
            responder = current.nextResponder
        }
        emit("chain: " + chain.joined(separator: " → "))
    }

    // MARK: text

    private static func dumpText() {
        guard let window = keyWindow else { emit("no key window"); return }
        guard let editor = DocumentCommands.firstEditor(in: window.contentView) else {
            emit("window #\(window.windowNumber) has no editor"); return
        }
        let text = editor.string
        emit("length=\(text.utf16.count) selection=\(NSStringFromRange(editor.selectedRange())) u2028=\(text.contains("\u{2028}")) u2029=\(text.contains("\u{2029}")) firstResponder=\(window.firstResponder === editor)")
        emit("text=" + String(reflecting: text))
    }

    // MARK: findbar

    private static func dumpFindBar() {
        guard let window = keyWindow else { emit("no key window"); return }
        guard let editor = DocumentCommands.firstEditor(in: window.contentView),
              let scroll = editor.enclosingScrollView else {
            emit("window #\(window.windowNumber) has no editor"); return
        }
        emit("findBarVisible=\(scroll.isFindBarVisible)")
        if let bar = scroll.findBarView {
            var fields: [String] = []
            collectFields(in: bar, into: &fields)
            emit("fields: " + fields.joined(separator: " | "))
        }
        emit("selection=\(NSStringFromRange(editor.selectedRange())) selected=" + String(reflecting: (editor.string as NSString).substring(with: editor.selectedRange())))
    }

    private static func collectFields(in view: NSView, into out: inout [String]) {
        if let field = view as? NSTextField {
            let kind = field is NSSearchField ? "search" : (field.isEditable ? "field" : "label")
            out.append("\(kind)=\(String(reflecting: field.stringValue))")
        } else if let button = view as? NSButton, !button.title.isEmpty {
            out.append("button=\(String(reflecting: button.title))\(button.isEnabled ? "" : "(off)")")
        } else if let popup = view as? NSPopUpButton {
            out.append("popup=\(String(reflecting: popup.titleOfSelectedItem ?? ""))")
        }
        for sub in view.subviews { collectFields(in: sub, into: &out) }
    }

    // MARK: doc

    private static func dumpDocument() {
        guard let window = keyWindow else { emit("no key window"); return }
        guard let document = NSDocumentController.shared.document(for: window) else {
            emit("window #\(window.windowNumber) has no document"); return
        }
        let undo = window.undoManager
        emit("document '\(document.displayName ?? "")' file=\(document.fileURL?.path ?? "nil") type=\(document.fileType ?? "nil") edited=\(document.isDocumentEdited) title='\(window.title)'")
        emit("undo: canUndo=\(undo?.canUndo ?? false) '\(undo?.undoActionName ?? "")' canRedo=\(undo?.canRedo ?? false) '\(undo?.redoActionName ?? "")'")
    }

    // MARK: webpid

    private static func dumpWebProcess() {
        guard let window = keyWindow else { emit("no key window"); return }
        guard let web = firstWebView(in: window.contentView) else {
            emit("window #\(window.windowNumber) has no preview"); return
        }
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard web.responds(to: selector) else { emit("webpid unavailable"); return }
        let pid = (web.value(forKey: "_webProcessIdentifier") as? Int) ?? 0
        emit("webpid=\(pid) url=\(web.url?.absoluteString ?? "nil") loading=\(web.isLoading)")
    }

    // MARK: js

    private static func evaluate(_ script: String) {
        guard let window = keyWindow else { emit("no key window"); end("js"); return }
        guard let web = firstWebView(in: window.contentView) else {
            emit("window #\(window.windowNumber) has no preview"); end("js"); return
        }
        web.evaluateJavaScript(script) { value, error in
            MainActor.assumeIsolated {
                if let error { emit("js error: \(error.localizedDescription)") }
                emit("js=" + String(reflecting: value.map { String(describing: $0) } ?? "nil"))
                end("js")
            }
        }
    }

    // MARK: focus / press

    /// `focus editor|preview|window` — make that view the first responder,
    /// which is what a click in it does. How a run gets the keyboard into
    /// the preview pane without a screen click.
    private static func focus(_ what: String) {
        guard let window = keyWindow else { emit("no key window"); return }
        let ok: Bool
        switch what {
        case "editor": ok = window.makeFirstResponder(DocumentCommands.firstEditor(in: window.contentView))
        case "preview": ok = window.makeFirstResponder(firstWebView(in: window.contentView))
        default: ok = window.makeFirstResponder(nil)
        }
        emit("focus \(what): \(ok) firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
    }

    /// `insert <text>` — type `text` into the window's editor at the caret,
    /// through the same `insertText` a key press reaches. For runs that
    /// need an edit while no key event may be posted (a locked screen).
    private static func insert(_ text: String) {
        guard let window = keyWindow else { emit("no key window"); return }
        guard let editor = DocumentCommands.firstEditor(in: window.contentView) else {
            emit("window #\(window.windowNumber) has no editor"); return
        }
        // `type:` — one character per insertText, and `\n` as the Return key
        // (insertNewline, where smart typing's list continuation lives), the
        // way a keyboard delivers them. Without the prefix, one insertText.
        if text.hasPrefix("type:") {
            let keys = String(text.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\n")
            for ch in keys {
                if ch == "\n" { editor.insertNewline(nil) }
                else { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
            }
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        emit("inserted \(text.utf16.count) units; length=\((editor.string as NSString).length)")
    }

    /// A main-menu item by its title path, performed the way a click does —
    /// validated first, so a disabled row reports itself and does nothing.
    private static func performMenuItem(_ path: String) {
        let titles = path.components(separatedBy: " > ")
        var menu = NSApp.mainMenu
        for (i, title) in titles.enumerated() {
            guard let current = menu else { emit("menuitem: no menu for '\(title)'"); return }
            // What AppKit does just before showing a menu: SwiftUI fills a
            // dynamic submenu (Go ▸ Contents) only when it is about to open.
            current.delegate?.menuNeedsUpdate?(current)
            current.delegate?.menuWillOpen?(current)
            current.update()
            guard let item = current.items.first(where: { $0.title == title }) else {
                emit("menuitem: no item '\(title)' in \(current.items.map(\.title))"); return
            }
            if i < titles.count - 1 {
                menu = item.submenu
            } else {
                guard item.isEnabled else { emit("menuitem: '\(path)' is disabled"); return }
                current.performActionForItem(at: current.index(of: item))
                emit("menuitem: performed '\(path)'")
            }
        }
    }

    /// Size the key window (or `@window`) to exactly W × H points, so a
    /// window capture on a 2× display is exactly 2W × 2H pixels.
    private static func setFrame(_ argument: String) {
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 2, let window = targetWindow ?? keyWindow, let screen = window.screen ?? NSScreen.main else {
            emit("frame: needs W H and a window"); return
        }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.minX + 60, y: visible.maxY - numbers[1] - 40, width: numbers[0], height: numbers[1])
        window.setFrame(frame, display: true, animate: false)
        emit("frame: #\(window.windowNumber) \(Int(window.frame.width))x\(Int(window.frame.height))")
    }

    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        let window = targetWindow ?? NSApp.windows.last { $0.isVisible && $0.canBecomeKey && !$0.isSheet }
        window?.makeKeyAndOrderFront(nil)
        emit("activate: active=\(NSApp.isActive) key=\(NSApp.keyWindow.map { String($0.windowNumber) } ?? "none")")
    }

    private static func openFile(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            MainActor.assumeIsolated {
                emit(error.map { "openfile: \($0.localizedDescription)" } ?? "openfile: \(url.lastPathComponent)")
            }
        }
    }

    private static func setFindString(_ string: String) {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        emit("findstring: \(string)")
    }

    /// The example book, unpacked where the sandbox lets the app write, and
    /// remembered under the key `BookLibrary` reads.
    private static func installExampleBook() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard documents.path.contains("/Library/Containers/") else {
            emit("examplebook: refused — not sandboxed (\(documents.path))"); return
        }
        guard let source = Bundle.main.url(forResource: "Example Book", withExtension: nil, subdirectory: "Examples") else {
            emit("examplebook: missing from the bundle"); return
        }
        let destination = documents.appendingPathComponent("Example Book", isDirectory: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            do { try FileManager.default.copyItem(at: source, to: destination) } catch {
                emit("examplebook: copy failed \(error.localizedDescription)"); return
            }
        }
        guard let data = try? destination.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) else {
            emit("examplebook: bookmark failed"); return
        }
        UserDefaults.standard.set(data.base64EncodedString(), forKey: BookLibrary.bookmarkKey)
        emit("examplebook: \(destination.path)")
    }

    /// `press <title>` — click the button with that title in the window
    /// (the find bar's Replace / Replace All / Done), as a mouse would.
    private static func press(_ title: String) {
        guard let window = keyWindow else { emit("no key window"); return }
        guard let button = firstButton(titled: title, in: window.contentView) else {
            emit("no button '\(title)'"); return
        }
        button.performClick(nil)
        emit("pressed '\(title)' enabled=\(button.isEnabled)")
    }

    private static func firstButton(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for sub in view.subviews {
            if let found = firstButton(titled: title, in: sub) { return found }
        }
        return nil
    }

    // MARK: appearance

    private static func setAppearance(_ name: String) {
        switch name {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
        emit("appearance=\(NSApp.effectiveAppearance.name.rawValue)")
    }

    // MARK: discard / closeall / quit

    private static func discardAll() {
        for document in NSDocumentController.shared.documents {
            document.updateChangeCount(.changeCleared)
        }
        emit("discarded edits in \(NSDocumentController.shared.documents.count) documents")
    }

    /// `closeall` — close every document (after `discard`, so nothing asks
    /// to save) and every other visible window, so that quitting leaves no
    /// window for state restoration to bring back at the next launch.
    private static func closeAll() {
        let documents = NSDocumentController.shared.documents
        for document in documents { document.close() }
        var others = 0
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            window.close(); others += 1
        }
        emit("closed \(documents.count) documents and \(others) other windows")
    }
}

#endif
