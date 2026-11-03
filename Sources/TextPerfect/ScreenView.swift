import AppKit
import UniformTypeIdentifiers

enum KC {
    static let f1 = 122
    static let f2 = 120
    static let f3 = 99
    static let f4 = 118
    static let f5 = 96
    static let f6 = 97
    static let f7 = 98
    static let f8 = 100
    static let f9 = 101
    static let f10 = 109
    static let f11 = 103
    static let f12 = 111
    static let left = 123
    static let right = 124
    static let down = 125
    static let up = 126
    static let home = 115
    static let end = 119
    static let pageUp = 116
    static let pageDown = 121
    static let backspace = 51
    static let forwardDelete = 117
    static let ret = 36
    static let enter = 76
    static let escape = 53
    static let tab = 48
    static let insert = 114
}

enum Palette {
    static let blue = NSColor(srgbRed: 0, green: 0, blue: 0.667, alpha: 1)
    static let grey = NSColor(srgbRed: 0.667, green: 0.667, blue: 0.667, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
}

struct Snap {
    var chars: [Character]
    var cursor: Int
}

struct Prompt {
    enum Kind { case text, yesNo, choice }
    var kind: Kind
    var label: String
    var text: String
    var defaultYes: Bool
    var done: (String?) -> Void
    var fresh: Bool = false   // first typed character replaces the suggested text
    var choices = ""          // .choice: the keys that answer it, in lower case
}

/// A spell check in progress: what the checker suggests for the word on screen.
struct SpellCheck {
    var tag: Int                     // NSSpellChecker document tag; holds this check's Skip list
    var suggestions: [String] = []
    var corrections = 0
}

final class ScreenView: NSView, NSMenuItemValidation {

    // MARK: State

    var chars: [Character] = []
    var cursor = 0 {
        didSet { followCursor = true }
    }
    var anchor: Int? = nil
    var blockMode = false
    var typeover = false
    var modified = false {
        didSet { window?.isDocumentEdited = modified }
    }
    var fileURL: URL? = nil
    var savedChars: [Character] = []   // contents as last opened or saved, so Undo can tell when it's back there
    var exitConfirmed = false          // set once the user has answered Yes to Exit, so the quit isn't intercepted again
    var topRow = 0            // first screen row shown; rows are text lines plus page-break bars
    var followCursor = true   // false while the mouse wheel has scrolled the view away from the cursor
    var scrollAccum: CGFloat = 0
    var goalCol: Int? = nil
    var revealCodes = false
    var spell: SpellCheck? = nil
    /// Reveal Codes and Spell each take the bottom half of the screen.
    var splitScreen: Bool { revealCodes || spell != nil }
    var showHelp = false
    var message = ""
    var lastSearch = ""
    var lastReplace = ""
    var blinkOn = true
    var prompt: Prompt? = nil
    var undoStack: [Snap] = []
    var lastWasTyping = false
    var blinkTimer: Timer?

    // Launch splash: the app icon and version, fading out over the editor.
    let splashDuration: TimeInterval = 3.0
    /// The icon artwork itself (AppIcon_1024.png, bundled by build_app.sh as SplashIcon.png),
    /// falling back to the app's icon as macOS presents it.
    lazy var splashIcon: NSImage? = Bundle.main.url(forResource: "SplashIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
    var splashStart: Date? = nil     // set on the first frame drawn, so the window is on screen for all of the fade
    var splashTimer: Timer?          // non-nil while the launch splash is fading
    var splashShown = false
    var splashHeld = false           // F9: the splash at full strength until a key or click
    var splashShowing: Bool { splashHeld || splashTimer != nil }

    let leftMargin = 5       // screen column where text starts (5 characters in)
    let topMargin = 1        // blank rows above the text
    var leftMarginIn: Double = (UserDefaults.standard.object(forKey: "tp.leftMarginIn") as? Double) ?? 1.0 {
        didSet { UserDefaults.standard.set(leftMarginIn, forKey: "tp.leftMarginIn") }
    }
    var rightMarginIn: Double = (UserDefaults.standard.object(forKey: "tp.rightMarginIn") as? Double) ?? 0.5 {
        didSet { UserDefaults.standard.set(rightMarginIn, forKey: "tp.rightMarginIn") }
    }
    /// The left edge of the screen is the left margin, so Pos starts there.
    var posBase: Int { Int((leftMarginIn * 10).rounded()) }
    /// Characters between the margins on 8.5" paper at 10 characters per inch.
    var lineWidth: Int { max(10, min(70, Int(((8.5 - leftMarginIn - rightMarginIn) * 10).rounded()))) }
    /// Printed line spacing: 12 pt JetBrains Mono at its standard 1.2 line spacing = 14.4 pt,
    /// exactly 5 lines per inch. Its letters reach 12.3 pt top to bottom, so 6 per inch would touch.
    let linesPerInch = 5.0
    let linesPerPage = 45    // 9" of text (1" top and bottom margins) at 5 lines per inch

    func pagination(_ lines: [LineInfo]) -> Pagination {
        return Pagination(lines, linesPerPage: linesPerPage)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkOn.toggle()
            self.needsDisplay = true
        }
        registerForDraggedTypes([.fileURL])
        if window != nil && !splashShown {
            splashShown = true
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.splashAlpha() <= 0 { self.endSplash() }
                self.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)   // keep fading even while the window is being dragged
            splashTimer = t
        }
        updateTitle()
    }

    /// 1 at launch, easing to 0 over `splashDuration`; a steady 1 while F9 holds it up.
    func splashAlpha() -> CGFloat {
        if splashHeld { return 1 }
        guard splashTimer != nil else { return 0 }
        guard let start = splashStart else { return 1 }
        let t = min(1, max(0, Date().timeIntervalSince(start) / splashDuration))
        return CGFloat(1 - t * t * (3 - 2 * t))
    }

    func endSplash() {
        splashTimer?.invalidate()
        splashTimer = nil
        splashHeld = false
        needsDisplay = true
    }

    func updateTitle() {
        let name = fileURL?.lastPathComponent ?? "Untitled"
        window?.title = name + " \u{2014} TextPerfect"
        window?.representedURL = fileURL
        window?.isDocumentEdited = modified
    }

    // MARK: Layout helpers

    func normalLines() -> [LineInfo] {
        return layoutLines(chars, width: lineWidth, reveal: false)
    }

    func colWidth(from a: Int, to b: Int) -> Int {
        var w = 0
        var i = a
        while i < b && i < chars.count {
            w += Code.width(chars[i], reveal: false)
            i += 1
        }
        return w
    }

    /// Column where a line's text starts: its paragraph indent, then centering within what's left.
    func lineOffset(_ l: LineInfo) -> Int {
        guard l.centered else { return l.indent }
        var vis = 0
        var lastNonSpace = 0
        var k = l.start
        while k < l.end && k < chars.count {
            let c = chars[k]
            if Code.isVisible(c) {
                vis += 1
                if c != " " { lastNonSpace = vis }
            }
            k += 1
        }
        return l.indent + max(0, (lineWidth - l.indent - lastNonSpace) / 2)
    }

    func indexFor(_ line: LineInfo, isLast: Bool, col: Int) -> Int {
        let limit = isLast ? line.end : max(line.start, line.end - 1)
        var i = line.start
        var w = 0
        while i < limit && w < col {
            w += Code.width(chars[i], reveal: false)
            i += 1
        }
        return i
    }

    /// Clamped to the text, so an anchor left behind by an edit can never reach past the end.
    func selectionRange() -> Range<Int>? {
        guard let a = anchor else { return nil }
        let lo = min(a, cursor, chars.count)
        let hi = min(max(a, cursor), chars.count)
        return lo < hi ? lo..<hi : nil
    }

    // MARK: Cursor movement

    func moveCursor(extend: Bool, _ body: () -> Void) {
        if extend || blockMode {
            if anchor == nil { anchor = cursor }
        } else {
            anchor = nil
        }
        body()
    }

    func moveLeft() {
        if cursor == 0 { return }
        cursor -= 1
        if !revealCodes {
            while cursor > 0 && Code.isCode(chars[cursor]) { cursor -= 1 }
        }
    }

    func moveRight() {
        if cursor >= chars.count { return }
        cursor += 1
        if !revealCodes {
            while cursor < chars.count && Code.isCode(chars[cursor]) { cursor += 1 }
        }
    }

    func moveVertical(_ delta: Int) {
        let lines = normalLines()
        let li = lineIndex(of: cursor, in: lines, count: chars.count)
        let raw = li + delta
        if abs(delta) == 1 && (raw < 0 || raw >= lines.count) { return }
        let target = min(max(raw, 0), lines.count - 1)
        // Screen column, so the cursor keeps its place across indented and centered lines.
        let col = goalCol ?? lineOffset(lines[li]) + colWidth(from: lines[li].start, to: cursor)
        goalCol = col
        cursor = indexFor(lines[target], isLast: target == lines.count - 1,
                          col: max(0, col - lineOffset(lines[target])))
    }

    func cursorToLineStart() {
        let lines = normalLines()
        let li = lineIndex(of: cursor, in: lines, count: chars.count)
        var i = lines[li].start
        let limit = lines[li].end
        if !revealCodes {
            while i < limit && i < chars.count && Code.isCode(chars[i]) { i += 1 }
        }
        cursor = i
    }

    func cursorToLineEnd() {
        let lines = normalLines()
        let li = lineIndex(of: cursor, in: lines, count: chars.count)
        let l = lines[li]
        let isLast = li == lines.count - 1
        cursor = isLast ? l.end : max(l.start, l.end - 1)
    }

    func isWordChar(_ c: Character) -> Bool {
        return c.isLetter || c.isNumber
    }

    func wordRight() {
        var i = cursor
        while i < chars.count && isWordChar(chars[i]) { i += 1 }
        while i < chars.count && !isWordChar(chars[i]) { i += 1 }
        cursor = i
    }

    func wordLeft() {
        var i = cursor
        while i > 0 && !isWordChar(chars[i - 1]) { i -= 1 }
        while i > 0 && isWordChar(chars[i - 1]) { i -= 1 }
        cursor = i
    }

    // MARK: Editing

    func pushUndo() {
        undoStack.append(Snap(chars: chars, cursor: cursor))
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    func beginEdit(typing: Bool) {
        if !(typing && lastWasTyping) { pushUndo() }
        lastWasTyping = typing
    }

    @objc func undo(_ sender: Any?) {
        guard let s = undoStack.popLast() else { return }
        chars = s.chars
        cursor = min(s.cursor, chars.count)
        anchor = nil
        blockMode = false
        modified = chars != savedChars
        lastWasTyping = false
        needsDisplay = true
    }

    func deleteRange(_ r: Range<Int>) {
        beginEdit(typing: false)
        chars.removeSubrange(r)
        cursor = r.lowerBound
        anchor = nil
        blockMode = false
        modified = true
    }

    func typeChars(_ s: [Character], insertOnly: Bool = false) {
        if let r = selectionRange() {
            // Replacing a block is one undo step: the deletion and the new text undo together.
            pushUndo()
            chars.removeSubrange(r)
            cursor = r.lowerBound
            lastWasTyping = true
        }
        anchor = nil
        blockMode = false
        if let first = s.first { adjustInsertionPoint(lineEnd: Code.isLineEnd(first)) }
        beginEdit(typing: true)
        for ch in s {
            if !insertOnly && typeover && cursor < chars.count
                && Code.isVisible(chars[cursor]) {
                chars[cursor] = ch
            } else {
                chars.insert(ch, at: cursor)
            }
            cursor += 1
        }
        modified = true
    }

    /// When the cursor is among the codes that open a paragraph: a Return or page break goes in
    /// before all of them, so the paragraph moves down with its indent and centering intact;
    /// other text goes in after its indent codes, which only count while they lead the paragraph.
    /// Not in Reveal Codes, where the codes are on screen and the cursor's place among them is deliberate.
    func adjustInsertionPoint(lineEnd: Bool) {
        if revealCodes { return }
        var p = cursor
        while p > 0 && Code.isCode(chars[p - 1]) { p -= 1 }
        guard p == 0 || Code.isLineEnd(chars[p - 1]) else { return }
        if lineEnd {
            cursor = p
            return
        }
        var k = cursor
        while k < chars.count && Code.isCode(chars[k]) {
            if chars[k] == Code.indent { cursor = k + 1 }
            k += 1
        }
    }

    func removeChar(at idx: Int) {
        beginEdit(typing: false)
        let c = chars[idx]
        var removed = [idx]
        if let p = Code.partner(of: c) {
            if Code.isOpening(c) {
                var k = idx + 1
                while k < chars.count {
                    if chars[k] == p { removed.append(k); break }
                    k += 1
                }
            } else {
                var k = idx - 1
                while k >= 0 {
                    if chars[k] == p { removed.append(k); break }
                    k -= 1
                }
            }
        }
        for k in removed.sorted(by: >) {
            chars.remove(at: k)
            if k < cursor { cursor -= 1 }
        }
        modified = true
    }

    func backspace() {
        if let r = selectionRange() { deleteRange(r); return }
        if revealCodes {
            guard cursor > 0 else { return }
            removeChar(at: cursor - 1)
        } else {
            // Skips invisible codes, except an indent: Backspace at an indented paragraph's start
            // takes off one level, as it would delete a tab.
            var j = cursor - 1
            while j >= 0 && Code.isCode(chars[j]) && chars[j] != Code.indent { j -= 1 }
            guard j >= 0 else { return }
            removeChar(at: j)
        }
    }

    func deleteForward() {
        if let r = selectionRange() { deleteRange(r); return }
        var j = cursor
        if !revealCodes {
            while j < chars.count && Code.isCode(chars[j]) && chars[j] != Code.indent { j += 1 }
        }
        guard j < chars.count else { return }
        removeChar(at: j)
    }

    func deleteWordForward() {
        if let r = selectionRange() { deleteRange(r); return }
        let a = cursor
        wordRight()
        let b = cursor
        cursor = a
        if b > a { deleteRange(a..<b) }
    }

    func deleteWordBack() {
        if let r = selectionRange() { deleteRange(r); return }
        let b = cursor
        wordLeft()
        let a = cursor
        if b > a { deleteRange(a..<b) }
    }

    func deleteToLineEnd() {
        let lines = normalLines()
        let li = lineIndex(of: cursor, in: lines, count: chars.count)
        let l = lines[li]
        let isLast = li == lines.count - 1
        let target = isLast ? l.end : max(l.start, l.end - 1)
        if target > cursor { deleteRange(cursor..<target) }
    }

    func insertTab() {
        let lines = normalLines()
        let li = lineIndex(of: cursor, in: lines, count: chars.count)
        let col = posBase + lines[li].indent + colWidth(from: lines[li].start, to: cursor)
        let next = (col / 5 + 1) * 5
        typeChars(Array(repeating: " ", count: max(1, next - col)), insertOnly: true)
    }

    func toggleAttribute(on: Character, off: Character) {
        if let r = selectionRange() {
            beginEdit(typing: false)
            chars.insert(off, at: r.upperBound)
            chars.insert(on, at: r.lowerBound)
            cursor = r.upperBound + 2
            anchor = nil
            blockMode = false
            modified = true
            return
        }
        if cursor < chars.count && chars[cursor] == off {
            cursor += 1
            return
        }
        beginEdit(typing: false)
        chars.insert(contentsOf: [on, off], at: cursor)
        cursor += 1
        modified = true
    }

    func toggleCenter() {
        let lines = normalLines()
        let li = lineIndex(of: cursor, in: lines, count: chars.count)
        var p = lines[li].start
        while p > 0 && !Code.isLineEnd(chars[p - 1]) { p -= 1 }
        beginEdit(typing: false)
        if p < chars.count && chars[p] == Code.center {
            chars.remove(at: p)
            if cursor > p { cursor -= 1 }
        } else {
            chars.insert(Code.center, at: p)
            if cursor >= p { cursor += 1 }
        }
        modified = true
    }

    /// F4: indent the cursor's paragraph one more tab stop (0.5"), wrapped lines included.
    func indentParagraph() {
        let lines = normalLines()
        let li = lineIndex(of: cursor, in: lines, count: chars.count)
        var p = lines[li].start
        while p > 0 && !Code.isLineEnd(chars[p - 1]) { p -= 1 }
        if paragraphIndent(chars, from: p) + Code.indentWidth > lineWidth - 10 {
            message = "* Indent limit *"
            return
        }
        if p < chars.count && chars[p] == Code.center { p += 1 }   // [Center] has to stay first
        beginEdit(typing: false)
        chars.insert(Code.indent, at: p)
        if cursor >= p { cursor += 1 }
        modified = true
    }

    /// Shift-F5: type today's date, e.g. "November 2, 2026".
    func insertDate() {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        lastWasTyping = false
        typeChars(Array(f.string(from: Date())), insertOnly: true)
        lastWasTyping = false
    }

    func toggleBlock() {
        if blockMode {
            blockMode = false
            anchor = nil
        } else {
            blockMode = true
            anchor = cursor
        }
    }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        guard let r = selectionRange() else { return }
        // Formatting codes are dropped; a page break goes out as a form feed, plain text's page break.
        let text = String(chars[r].compactMap { c -> Character? in
            c == Code.hardPage ? "\u{0C}" : (Code.isCode(c) ? nil : c)
        })
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard let r = selectionRange() else { return }
        copy(nil)
        deleteRange(r)
        needsDisplay = true
    }

    @objc func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\t", with: "     ")
        if var p = prompt {
            // A text prompt takes the pasted text on its one line; nothing reaches the document.
            let line = String(sanitize(s.replacingOccurrences(of: "\n", with: " "), allowCodes: false))
            if p.kind == .text && !line.isEmpty {
                if p.fresh { p.text = "" }
                p.fresh = false
                p.text += line
                prompt = p
                needsDisplay = true
            }
            return
        }
        let cs = sanitize(s, allowCodes: false, pageBreaks: true)
        if cs.isEmpty { return }
        lastWasTyping = false   // a paste is its own undo step, never merged into preceding typing
        typeChars(cs, insertOnly: true)
        lastWasTyping = false
        needsDisplay = true
    }

    override func selectAll(_ sender: Any?) {
        blockMode = false
        anchor = 0
        cursor = chars.count
        needsDisplay = true
    }

    // MARK: Files

    func loadText(from url: URL) -> [Character]? {
        guard let data = try? Data(contentsOf: url) else {
            message = "* Cannot read file *"
            return nil
        }
        if data.prefix(4096).contains(0) {
            message = "* Not a plain text file *"
            return nil
        }
        var s = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: "\t", with: "     ")
        return sanitize(s, allowCodes: true, pageBreaks: true)
    }

    /// Print fonts: the screen font's family (JetBrains Mono NL, else Menlo, else the system
    /// monospaced font) sized from its measured width to exactly 10 characters per inch
    /// (7.2 pt per character), so a full line between the margins prints on one line, as it
    /// does on screen. Bold and italic faces are derived from the same family.
    static func printFonts() -> (regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont) {
        let charWidth: CGFloat = 72.0 / 10
        let reg = screenFont(size: charWidth / fontRatios.width)
        let fm = NSFontManager.shared
        let bold = fm.convert(reg, toHaveTrait: .boldFontMask)
        return (reg, bold, fm.convert(reg, toHaveTrait: .italicFontMask),
                fm.convert(bold, toHaveTrait: .italicFontMask))
    }

    /// The document as .txt: formatting codes dropped, indented and centered paragraphs padded
    /// with spaces, hard page breaks written as form feeds.
    func exportPlainText() -> String {
        var out = ""
        var i = 0
        while i <= chars.count {
            var j = i
            while j < chars.count && !Code.isLineEnd(chars[j]) { j += 1 }
            let visible = chars[i..<j].filter { !Code.isCode($0) }
            let indent = min(paragraphIndent(chars, from: i), max(0, lineWidth - 10))
            out += String(repeating: " ", count: indent)
            if i < j && chars[i] == Code.center {
                var trimmed = visible.count
                while trimmed > 0 && visible[trimmed - 1] == " " { trimmed -= 1 }
                out += String(repeating: " ", count: max(0, (lineWidth - indent - trimmed) / 2))
            }
            out += String(visible)
            if j < chars.count {
                out += chars[j] == Code.hardPage ? "\u{0C}" : "\n"
            }
            i = j + 1
        }
        return out
    }

    /// The document as printed pages, using the screen's own line layout and page breaks.
    /// A trailing page with nothing on it (document ending in a page break) is dropped.
    func printPages(fonts: (regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont),
                    charWidth: CGFloat) -> [[PrintLine]] {
        let lines = normalLines()
        let pag = pagination(lines)
        var pages: [[PrintLine]] = []
        var bold = false
        var und = false
        var ital = false
        for (li, l) in lines.enumerated() {
            if pag.lineOnPage[li] == 0 { pages.append([]) }
            let text = NSMutableAttributedString()
            var k = l.start
            while k < l.end {
                let c = chars[k]
                applyState(c, &bold, &und, &ital)
                if Code.isVisible(c) {
                    let face = bold ? (ital ? fonts.boldItalic : fonts.bold) : (ital ? fonts.italic : fonts.regular)
                    var attrs: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: NSColor.black]
                    if und { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    text.append(NSAttributedString(string: String(c), attributes: attrs))
                }
                k += 1
            }
            pages[pages.count - 1].append(PrintLine(x: CGFloat(lineOffset(l)) * charWidth, text: text))
        }
        if pages.count > 1, let last = pages.last, last.allSatisfy({ $0.text.length == 0 }) {
            pages.removeLast()
        }
        return pages
    }

    func write(to url: URL) -> Bool {
        let text: String
        if url.pathExtension.lowercased() == "txt" {
            text = exportPlainText()
        } else {
            text = String(chars)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "TextPerfect could not save the file"
            alert.informativeText = url.path + "\n\n" + error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            message = "* Save failed *"
            needsDisplay = true
            return false
        }
        fileURL = url
        savedChars = chars
        modified = false
        updateTitle()
        message = "Saved " + url.lastPathComponent
        needsDisplay = true
        return true
    }

    func save(_ completion: ((Bool) -> Void)? = nil) {
        if let u = fileURL {
            let ok = write(to: u)
            completion?(ok)
        } else {
            saveAs(completion)
        }
    }

    func saveAs(_ completion: ((Bool) -> Void)? = nil) {
        let p = NSSavePanel()
        p.allowedContentTypes = ["lp", "txt"].compactMap { UTType(filenameExtension: $0) }
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        p.nameFieldStringValue = base + ".lp"
        if p.runModal() == .OK, let u = p.url {
            let ok = write(to: u)
            completion?(ok)
        } else {
            completion?(false)
        }
    }

    func chooseFile() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }

    func confirmDiscard(_ then: @escaping () -> Void) {
        guard modified else { then(); return }
        ask("Save document? Yes (No)", kind: .yesNo, defaultYes: true) { [weak self] ans in
            guard let self = self, let ans = ans else { return }
            if ans == "y" {
                self.save { ok in if ok { then() } }
            } else {
                then()
            }
        }
    }

    /// Replaces the document wholesale (New, Close, Open) with a clean undo history.
    func loadDocument(_ text: [Character], url: URL?) {
        chars = text
        savedChars = text
        cursor = 0
        anchor = nil
        blockMode = false
        topRow = 0
        fileURL = url
        modified = false
        undoStack = []
        lastWasTyping = false
        updateTitle()
        needsDisplay = true
    }

    func clearDocument() {
        loadDocument([], url: nil)
    }

    func newDocument() {
        confirmDiscard { [weak self] in self?.clearDocument() }
    }

    /// Closes the document but leaves TextPerfect running with a blank screen.
    func closeDocument() {
        let name = fileURL?.lastPathComponent
        confirmDiscard { [weak self] in
            guard let self = self else { return }
            self.clearDocument()
            if let name = name { self.message = "Closed " + name }
        }
    }

    func openFile() {
        confirmDiscard { [weak self] in
            guard let self = self else { return }
            if let url = self.chooseFile(), let text = self.loadText(from: url) {
                self.loadDocument(text, url: url)
            }
            self.needsDisplay = true
        }
    }

    func retrieveFile() {
        if let url = chooseFile(), let text = loadText(from: url) {
            lastWasTyping = false
            typeChars(text, insertOnly: true)
            lastWasTyping = false
        }
        needsDisplay = true
    }

    func printDocument() {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = CGFloat(leftMarginIn * 72)
        info.rightMargin = CGFloat(rightMarginIn * 72)
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let width = info.paperSize.width - CGFloat((leftMarginIn + rightMarginIn) * 72)
        let charWidth: CGFloat = 72.0 / 10
        let fonts = ScreenView.printFonts()
        let view = PrintPagesView(pages: printPages(fonts: fonts, charWidth: charWidth), width: width,
                                  lineHeight: CGFloat(72.0 / linesPerInch), linesPerPage: linesPerPage,
                                  font: fonts.regular)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.run()
    }

    /// WordPerfect's Ctrl-Enter: end the page here, whatever line it's on.
    func insertPageBreak() {
        lastWasTyping = false
        typeChars([Code.hardPage], insertOnly: true)
        lastWasTyping = false
    }

    func requestExit() {
        if spell != nil {
            prompt = nil
            finishSpell()
        }
        confirmDiscard { [weak self] in
            self?.ask("Exit TextPerfect? No (Yes)", kind: .yesNo, defaultYes: false) { [weak self] ans in
                guard ans == "y" else { return }
                self?.exitConfirmed = true
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Search

    func startSearch(forward: Bool) {
        ask(forward ? "\u{2192} Srch:" : "\u{2190} Srch:", kind: .text, text: lastSearch, fresh: true) { [weak self] ans in
            guard let self = self, let term = ans, !term.isEmpty else { return }
            self.lastSearch = term
            self.search(term, forward: forward)
        }
    }

    /// The text folded to lower case, one character per document character, for matching.
    func foldedText() -> [Character] {
        return chars.map { $0.lowercased().first ?? $0 }
    }

    func matches(_ needle: [Character], in hay: [Character], at i: Int) -> Bool {
        guard i >= 0 && i + needle.count <= hay.count else { return false }
        var k = 0
        while k < needle.count {
            if hay[i + k] != needle[k] { return false }
            k += 1
        }
        return true
    }

    /// Start of the next match at or after `from`, or the last one starting before it.
    func find(_ needle: [Character], in hay: [Character], from: Int, forward: Bool) -> Int? {
        let n = needle.count
        guard n > 0, hay.count >= n else { return nil }
        if forward {
            var i = max(0, from)
            while i <= hay.count - n {
                if matches(needle, in: hay, at: i) { return i }
                i += 1
            }
        } else {
            var i = min(from - 1, hay.count - n)
            while i >= 0 {
                if matches(needle, in: hay, at: i) { return i }
                i -= 1
            }
        }
        return nil
    }

    func search(_ term: String, forward: Bool) {
        let needle: [Character] = Array(term.lowercased())
        if let found = find(needle, in: foldedText(), from: cursor, forward: forward) {
            anchor = nil
            blockMode = false
            cursor = forward ? found + needle.count : found
        } else {
            message = "* Not found *"
        }
        needsDisplay = true
    }

    // MARK: Replace

    /// Opt-F2, WordPerfect's Replace: confirm each change or not, then the search text and the
    /// replacement. Works forward from the cursor to the end of the document, as WordPerfect's did.
    func startReplace() {
        ask("w/Confirm? No (Yes)", kind: .yesNo, defaultYes: false) { [weak self] confirm in
            guard let self = self, let confirm = confirm else { return }
            self.ask("\u{2192} Srch:", kind: .text, text: self.lastSearch, fresh: true) { [weak self] ans in
                guard let self = self, let term = ans, !term.isEmpty else { return }
                self.lastSearch = term
                self.ask("Replace with:", kind: .text, text: self.lastReplace, fresh: true) { [weak self] rep in
                    guard let self = self, let rep = rep else { return }
                    self.lastReplace = rep
                    let needle: [Character] = Array(term.lowercased())
                    if confirm == "y" {
                        self.confirmReplace(needle, with: Array(rep), from: self.cursor, done: 0)
                    } else {
                        self.replaceAll(needle, with: Array(rep))
                    }
                }
            }
        }
    }

    /// Replaces every match from the cursor on, in one pass; F1 undoes the lot.
    func replaceAll(_ needle: [Character], with rep: [Character]) {
        let hay = foldedText()
        var out = Array(chars[0..<cursor])
        var i = cursor
        var done = 0
        var lastEnd = cursor
        while i < chars.count {
            if matches(needle, in: hay, at: i) {
                out += rep
                i += needle.count
                done += 1
                lastEnd = out.count
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        if done > 0 {
            lastWasTyping = false
            pushUndo()
            chars = out
            cursor = lastEnd
            modified = true
        }
        finishReplace(done)
    }

    /// Highlights each match in turn and asks. Yes replaces it, No skips it, Esc stops.
    /// The first replacement takes the undo snapshot, so F1 undoes the whole Replace.
    func confirmReplace(_ needle: [Character], with rep: [Character], from: Int, done: Int) {
        guard let i = find(needle, in: foldedText(), from: from, forward: true) else {
            finishReplace(done)
            return
        }
        blockMode = false
        anchor = i
        cursor = i + needle.count
        ask("Confirm? No (Yes)", kind: .yesNo, defaultYes: false) { [weak self] ans in
            guard let self = self else { return }
            guard let ans = ans else { self.finishReplace(done); return }
            self.anchor = nil
            if ans == "y" {
                if done == 0 {
                    self.lastWasTyping = false
                    self.pushUndo()
                }
                self.chars.replaceSubrange(i..<(i + needle.count), with: rep)
                self.cursor = i + rep.count
                self.modified = true
                self.confirmReplace(needle, with: rep, from: i + rep.count, done: done + 1)
            } else {
                self.confirmReplace(needle, with: rep, from: i + needle.count, done: done)
            }
        }
    }

    func finishReplace(_ done: Int) {
        anchor = nil
        blockMode = false
        lastWasTyping = false
        message = done == 0 ? "* Not found *" : (done == 1 ? "1 replacement" : "\(done) replacements")
        needsDisplay = true
    }

    // MARK: Spell

    /// Opt-F1, LetterPerfect's Spell: works through the document from the top, stopping at each
    /// word macOS's spelling dictionary doesn't know.
    func startSpell() {
        anchor = nil
        blockMode = false
        spell = SpellCheck(tag: NSSpellChecker.uniqueSpellDocumentTag())
        nextMisspelling(from: 0)
    }

    /// The document as the spell checker reads it, without formatting codes (so a code inside a
    /// word doesn't split it), and the document index behind each of its UTF-16 units.
    func spellText() -> (String, [Int]) {
        var text = ""
        var map: [Int] = []
        for (i, c) in chars.enumerated() where !Code.isCode(c) {
            let ch: Character = c == Code.hardPage ? "\n" : c
            text.append(ch)
            map += Array(repeating: i, count: ch.utf16.count)
        }
        return (text, map)
    }

    /// Highlights the next unknown word at or after `start`, lists suggestions in the bottom half
    /// of the screen, and asks what to do: Skip Once, Skip (for the rest of this check), Add (to
    /// the macOS dictionary), Edit, or a suggestion's letter to use it. Esc stops.
    func nextMisspelling(from start: Int) {
        guard var sp = spell else { return }
        let (text, map) = spellText()
        let offset = map.firstIndex(where: { $0 >= start }) ?? map.count
        let checker = NSSpellChecker.shared
        let r = checker.checkSpelling(of: text, startingAt: offset, language: nil, wrap: false,
                                      inSpellDocumentWithTag: sp.tag, wordCount: nil)
        guard r.location != NSNotFound, r.length > 0, r.location + r.length <= map.count else {
            finishSpell()
            return
        }
        let a = map[r.location]
        let b = map[r.location + r.length - 1] + 1
        let word = (text as NSString).substring(with: r)
        sp.suggestions = Array((checker.guesses(forWordRange: r, in: text, language: nil,
                                                inSpellDocumentWithTag: sp.tag) ?? []).prefix(24))
        spell = sp
        anchor = a
        cursor = b
        let letters = Array("abcdefghijklmnopqrstuvwx".prefix(sp.suggestions.count))
        ask("Not Found: 1 Skip Once; 2 Skip; 3 Add; 4 Edit", kind: .choice,
            choices: "1234" + String(letters)) { [weak self] ans in
            guard let self = self else { return }
            guard let ans = ans else { self.finishSpell(); return }
            switch ans {
            case "1":
                self.nextMisspelling(from: b)
            case "2":
                checker.ignoreWord(word, inSpellDocumentWithTag: sp.tag)
                self.nextMisspelling(from: b)
            case "3":
                checker.learnWord(word)
                self.nextMisspelling(from: b)
            case "4":
                self.ask("Replace with:", kind: .text, text: word) { [weak self] typed in
                    guard let self = self else { return }
                    if let typed = typed, !typed.isEmpty {
                        self.spellReplace(a..<b, with: typed)
                    } else {
                        self.nextMisspelling(from: a)   // Esc: back to the same word
                    }
                }
            default:
                if let k = letters.firstIndex(of: Character(ans)) {
                    self.spellReplace(a..<b, with: sp.suggestions[k])
                }
            }
        }
    }

    /// Puts `rep` in place of the word, keeping any formatting codes that were inside it, and
    /// carries on after it. The first correction takes the undo snapshot, so F1 undoes them all.
    func spellReplace(_ r: Range<Int>, with rep: String) {
        guard var sp = spell else { return }
        if sp.corrections == 0 {
            lastWasTyping = false
            pushUndo()
        }
        let new = sanitize(rep, allowCodes: false) + chars[r].filter { Code.isCode($0) }
        chars.replaceSubrange(r, with: new)
        sp.corrections += 1
        spell = sp
        modified = true
        nextMisspelling(from: r.lowerBound + new.count)
    }

    func finishSpell() {
        guard let sp = spell else { return }
        NSSpellChecker.shared.closeSpellDocument(withTag: sp.tag)
        spell = nil
        anchor = nil
        lastWasTyping = false
        // Ends with the document's word count, as LetterPerfect's Spell did.
        let n = sp.corrections
        let words = NSSpellChecker.shared.countWords(in: spellText().0, language: nil)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let count = (f.string(from: NSNumber(value: max(0, words))) ?? "\(words)") + (words == 1 ? " word" : " words")
        let fixes = n == 0 ? "" : "\(n) correction" + (n == 1 ? "" : "s") + ", "
        message = "Spell check done: " + fixes + count
        needsDisplay = true
    }

    // MARK: Margins

    func marginText(_ v: Double) -> String {
        return String(inchString(v).dropLast())
    }

    func parseInches(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        let t = s.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), v >= 0, v <= 7.5 else {
            message = "* Invalid margin *"
            needsDisplay = true
            return nil
        }
        return v
    }

    func startMarginPrompt() {
        ask("Left margin (inches):", kind: .text, text: marginText(leftMarginIn), fresh: true) { [weak self] ans in
            guard let self = self, let l = self.parseInches(ans) else { return }
            self.ask("Right margin (inches):", kind: .text, text: self.marginText(self.rightMarginIn),
                     fresh: true) { [weak self] ans2 in
                guard let self = self, let r = self.parseInches(ans2) else { return }
                self.applyMargins(left: l, right: r)
            }
        }
    }

    func applyMargins(left: Double, right: Double) {
        let cols = (8.5 - left - right) * 10
        guard cols >= 10 && cols <= 70 else {
            message = "* Margins must leave 1\" to 7\" of text *"
            needsDisplay = true
            return
        }
        leftMarginIn = left
        rightMarginIn = right
        goalCol = nil
        needsDisplay = true
    }

    // MARK: Prompts

    func ask(_ label: String, kind: Prompt.Kind, text: String = "", defaultYes: Bool = false,
             fresh: Bool = false, choices: String = "", done: @escaping (String?) -> Void) {
        prompt = Prompt(kind: kind, label: label, text: text, defaultYes: defaultYes,
                        done: done, fresh: fresh, choices: choices)
        needsDisplay = true
    }

    func finishPrompt(_ answer: String?) {
        let done = prompt?.done
        prompt = nil
        needsDisplay = true
        done?(answer)
    }

    func handlePromptKey(_ event: NSEvent, _ current: Prompt) {
        var p = current
        let kc = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd-keys whose menu item is disabled fall through to here; Cmd-N must not answer "No".
        if flags.contains(.command) { return }
        switch p.kind {
        case .yesNo:
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if kc == KC.escape || kc == KC.f1 {
                finishPrompt(nil)
            } else if ch == "y" {
                finishPrompt("y")
            } else if ch == "n" {
                finishPrompt("n")
            } else if kc == KC.ret || kc == KC.enter {
                finishPrompt(p.defaultYes ? "y" : "n")
            }
        case .choice:
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if kc == KC.escape || kc == KC.f1 {
                finishPrompt(nil)
            } else if ch.count == 1 && p.choices.contains(ch) {
                finishPrompt(ch)
            }
        case .text:
            if kc == KC.escape || kc == KC.f1 {
                finishPrompt(nil)
            } else if kc == KC.ret || kc == KC.enter {
                finishPrompt(p.text)
            } else if kc == KC.backspace {
                p.fresh = false
                if !p.text.isEmpty { p.text.removeLast() }
                prompt = p
            } else if !flags.contains(.command), let s = event.characters {
                let typedText = String(sanitize(s, allowCodes: false))
                if !typedText.isEmpty {
                    if p.fresh { p.text = "" }
                    p.fresh = false
                    p.text += typedText
                    prompt = p
                }
            }
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        blinkOn = true
        if splashShowing {          // a key on the splash just dismisses it; it isn't typed
            endSplash()
            return
        }
        if showHelp {
            showHelp = false
            needsDisplay = true
            return
        }
        if let p = prompt {
            handlePromptKey(event, p)
            needsDisplay = true
            return
        }
        message = ""
        followCursor = true
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        let opt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        let cmd = flags.contains(.command)
        let kc = Int(event.keyCode)
        var keepGoal = false
        var typed = false

        switch kc {
        case KC.f1:
            if opt { startSpell() } else { undo(nil) }
        case KC.f2:
            // Ctrl-F2 is LetterPerfect's Spell key, but macOS keeps it unless its shortcut is turned off.
            if ctrl { startSpell() } else if opt { startReplace() } else { startSearch(forward: !shift) }
        case KC.f3:
            if opt { revealCodes.toggle() } else { showHelp = true }
        case KC.f4:
            if opt { toggleBlock() } else { indentParagraph() }
        case KC.f5:
            if shift { insertDate() } else { openFile() }
        case KC.f6:
            if shift { toggleCenter() } else { toggleAttribute(on: Code.boldOn, off: Code.boldOff) }
        case KC.f7:
            if shift { printDocument() } else { requestExit() }
        case KC.f8:
            if shift {
                startMarginPrompt()
            } else if opt {
                toggleAttribute(on: Code.italOn, off: Code.italOff)
            } else {
                toggleAttribute(on: Code.undOn, off: Code.undOff)
            }
        case KC.f9:
            splashHeld = true
        case KC.f10:
            if shift { retrieveFile() } else { save() }
        case KC.f11:
            revealCodes.toggle()
        case KC.f12:
            toggleBlock()
        case KC.insert:
            typeover.toggle()
        case KC.left:
            if opt || ctrl {
                moveCursor(extend: shift) { wordLeft() }
            } else if cmd {
                moveCursor(extend: shift) { cursorToLineStart() }
            } else {
                moveCursor(extend: shift) { moveLeft() }
            }
        case KC.right:
            if opt || ctrl {
                moveCursor(extend: shift) { wordRight() }
            } else if cmd {
                moveCursor(extend: shift) { cursorToLineEnd() }
            } else {
                moveCursor(extend: shift) { moveRight() }
            }
        case KC.up:
            if cmd {
                moveCursor(extend: shift) { cursor = 0 }
            } else {
                keepGoal = true
                moveCursor(extend: shift) { moveVertical(-1) }
            }
        case KC.down:
            if cmd {
                moveCursor(extend: shift) { cursor = chars.count }
            } else {
                keepGoal = true
                moveCursor(extend: shift) { moveVertical(1) }
            }
        case KC.home:
            if cmd || ctrl {
                moveCursor(extend: shift) { cursor = 0 }
            } else {
                moveCursor(extend: shift) { cursorToLineStart() }
            }
        case KC.end:
            if ctrl && !cmd {
                deleteToLineEnd()
            } else if cmd {
                moveCursor(extend: shift) { cursor = chars.count }
            } else {
                moveCursor(extend: shift) { cursorToLineEnd() }
            }
        case KC.pageUp:
            keepGoal = true
            moveCursor(extend: shift) { moveVertical(-22) }
        case KC.pageDown:
            keepGoal = true
            moveCursor(extend: shift) { moveVertical(22) }
        case KC.backspace:
            if opt || ctrl { deleteWordBack() } else { backspace() }
        case KC.forwardDelete:
            if opt || ctrl { deleteWordForward() } else { deleteForward() }
        case KC.ret, KC.enter:
            if ctrl {
                insertPageBreak()
            } else {
                // Inserted even in Typeover, as in WordPerfect: Return never overwrites a character.
                typeChars(["\n"], insertOnly: true)
                typed = true
            }
        case KC.tab:
            insertTab()
        case KC.escape:
            anchor = nil
            blockMode = false
        default:
            if !cmd && !ctrl, let s = event.characters {
                let cs = sanitize(s, allowCodes: false)
                if !cs.isEmpty {
                    typeChars(cs)
                    typed = true
                }
            }
        }

        if !keepGoal { goalCol = nil }
        if !typed { lastWasTyping = false }
        needsDisplay = true
    }

    // MARK: Mouse

    func indexAt(_ point: NSPoint) -> Int? {
        let cw = bounds.width / 80
        let ch = bounds.height / 25
        let row = Int(point.y / ch)
        let col = Int(point.x / cw)
        let textRows = (splitScreen ? 11 : 24) - topMargin
        let textRow = row - topMargin
        guard textRow >= 0 && textRow < textRows else { return nil }
        let lines = normalLines()
        let pag = pagination(lines)
        // A click on a page-break bar lands on the first line of the page below it.
        var r = min(topRow + textRow, pag.rows.count - 1)
        if case .pageBreak = pag.rows[r] { r += 1 }
        guard case .line(let li) = pag.rows[r] else { return nil }
        let l = lines[li]
        let rel = max(0, col - leftMargin - lineOffset(l))
        return indexFor(l, isLast: li == lines.count - 1, col: rel)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if splashShowing { endSplash(); return }
        if showHelp { showHelp = false; needsDisplay = true; return }
        if prompt != nil { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = indexAt(p) {
            blockMode = false
            cursor = i
            anchor = i
            goalCol = nil
            lastWasTyping = false
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if showHelp || prompt != nil { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = indexAt(p) {
            cursor = i
            needsDisplay = true
        }
    }

    /// A click that didn't drag selects nothing, so it mustn't leave an anchor behind: an edit
    /// that moves the cursor (Backspace, Center, Indent) would turn it into a stray block.
    override func mouseUp(with event: NSEvent) {
        if !blockMode && anchor == cursor { anchor = nil }
    }

    override func scrollWheel(with event: NSEvent) {
        if showHelp || prompt != nil { return }
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            dy /= bounds.height / 25      // trackpad / Magic Mouse: points -> rows
        } else {
            dy *= 3                       // wheel mouse: 3 lines per notch
        }
        scrollAccum += dy
        let rows = Int(scrollAccum)
        if rows == 0 { return }
        scrollAccum -= CGFloat(rows)
        let screenRows = pagination(normalLines()).rows.count
        let textRows = (splitScreen ? 11 : 24) - topMargin
        let maxTop = max(0, screenRows - textRows)
        let newTop = min(max(0, topRow - rows), maxTop)
        if newTop == topRow { return }
        topRow = newTop
        followCursor = false
        needsDisplay = true
    }

    // MARK: Drag and drop

    /// The one file being dragged in, if it's a single regular file.
    func droppedFile(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls = urls, urls.count == 1, !urls[0].hasDirectoryPath else { return nil }
        return urls[0]
    }

    /// A file dropped on the window opens it, as File > Open does; held with Option it goes into
    /// the document where it's dropped, as Retrieve does. Not while a prompt, help or the splash is up.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if prompt != nil || showHelp || splashShowing || droppedFile(sender) == nil { return [] }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard prompt == nil, !showHelp, !splashShowing, let url = droppedFile(sender) else { return false }
        // Come to the front, so typing (or answering the Save prompt) goes here, not back to Finder.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        if NSEvent.modifierFlags.contains(.option) {
            guard let text = loadText(from: url) else { needsDisplay = true; return true }
            if let i = indexAt(convert(sender.draggingLocation, from: nil)) {
                blockMode = false
                anchor = nil
                cursor = i
            }
            lastWasTyping = false
            typeChars(text, insertOnly: true)
            lastWasTyping = false
            needsDisplay = true
        } else {
            // Run after the drop returns, so Finder isn't left waiting on the Save prompt.
            DispatchQueue.main.async { [weak self] in self?.openDroppedFile(url) }
        }
        return true
    }

    /// Opens a file dropped on the window or the Dock icon (or opened from Finder), replacing
    /// the document after the usual Save prompt. Refused, with a beep, while a prompt is waiting.
    func openDroppedFile(_ url: URL) {
        if prompt != nil { NSSound.beep(); return }
        showHelp = false
        confirmDiscard { [weak self] in
            guard let self = self else { return }
            if let text = self.loadText(from: url) { self.loadDocument(text, url: url) }
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    // MARK: Menu actions

    /// While a status-line prompt, the help screen or the splash is up, the document is off limits:
    /// every menu item aimed at it is disabled, except Paste into a text prompt. A disabled item's
    /// Cmd-key falls through to keyDown, so on the help screen or splash it simply dismisses them.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if showHelp || splashShowing { return false }
        if let p = prompt { return item.action == #selector(paste(_:)) && p.kind == .text }
        return true
    }

    @objc func menuNew(_ sender: Any?) { newDocument() }
    @objc func menuOpen(_ sender: Any?) { openFile() }
    @objc func menuClose(_ sender: Any?) { closeDocument() }
    @objc func menuRetrieve(_ sender: Any?) { retrieveFile() }
    @objc func menuSave(_ sender: Any?) { save() }
    @objc func menuSaveAs(_ sender: Any?) { saveAs() }
    @objc func menuPrint(_ sender: Any?) { printDocument() }
    @objc func menuFind(_ sender: Any?) { startSearch(forward: true) }
    @objc func menuReplace(_ sender: Any?) { startReplace() }
    @objc func menuSpell(_ sender: Any?) { startSpell() }
    @objc func menuIndent(_ sender: Any?) { indentParagraph(); needsDisplay = true }
    @objc func menuDate(_ sender: Any?) { insertDate(); needsDisplay = true }
    @objc func menuFindNext(_ sender: Any?) {
        if lastSearch.isEmpty { startSearch(forward: true) } else { search(lastSearch, forward: true) }
    }
    @objc func menuBold(_ sender: Any?) {
        toggleAttribute(on: Code.boldOn, off: Code.boldOff); needsDisplay = true
    }
    @objc func menuUnderline(_ sender: Any?) {
        toggleAttribute(on: Code.undOn, off: Code.undOff); needsDisplay = true
    }
    @objc func menuItalic(_ sender: Any?) {
        toggleAttribute(on: Code.italOn, off: Code.italOff); needsDisplay = true
    }
    @objc func menuCenter(_ sender: Any?) { toggleCenter(); needsDisplay = true }
    @objc func menuPageBreak(_ sender: Any?) { insertPageBreak(); needsDisplay = true }
    @objc func menuReveal(_ sender: Any?) { revealCodes.toggle(); needsDisplay = true }
    @objc func menuBlock(_ sender: Any?) { toggleBlock(); needsDisplay = true }
    @objc func menuTypeover(_ sender: Any?) { typeover.toggle(); needsDisplay = true }
    @objc func menuHelp(_ sender: Any?) { showHelp = true; needsDisplay = true }
    @objc func menuMargins(_ sender: Any?) { startMarginPrompt() }

    // MARK: Drawing

    /// Screen font, in order of preference. JetBrains Mono NL is the no-ligature cut, so
    /// `<>` and `:=` always show as typed. Any monospaced font works here: sizing below is
    /// measured from whichever one loads, never hard-coded.
    static func screenFont(size: CGFloat) -> NSFont {
        return NSFont(name: "JetBrainsMonoNL-Regular", size: size)
            ?? NSFont(name: "Menlo-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Character width and line height per point of font size, measured once from the font.
    static let fontRatios: (width: CGFloat, height: CGFloat) = {
        let f = screenFont(size: 100)
        let w = ("M" as NSString).size(withAttributes: [.font: f]).width
        return (w / 100, (f.ascender - f.descender) / 100)
    }()

    static let helpText: [String] = [
        " TextPerfect key reference                      (press any key to return)",
        "",
        " F1        Undo                         Shift-F6    Center line on/off",
        " Opt-F1    Spell check                  F7          Exit",
        " F2        Search forward               Shift-F7    Print",
        " Shift-F2  Search backward              F8          Underline on/off",
        " Opt-F2    Replace                      Opt-F8      Italic on/off",
        " F3        Help                         Shift-F8    Margins",
        " Opt-F3    Reveal Codes                 F9          Splash screen",
        " F4        Indent paragraph             F10         Save",
        " Opt-F4    Block on/off                 Shift-F10   Retrieve file at cursor",
        " F5        Open file                    F11         Reveal Codes",
        " Shift-F5  Insert date                  F12         Block on/off",
        " F6        Bold on/off                  Insert      Typeover on/off",
        "",
        " Pages:    Ctrl-Return hard page break [HPg].  Pages also break every 45 lines.",
        " Clipboard: Cmd-C copy, Cmd-X cut, Cmd-V paste, Cmd-A select all.",
        " Cursor:   Opt-Left/Right word, Home/End line, Cmd-Up/Down document ends,",
        "           PgUp/PgDn screen.",
        " Files:    Save as .lp keeps all formatting.  .txt is plain text.",
        " Margins:  Shift-F8 sets left/right margins in inches (default 1\" and 0.5\").",
        "",
        " Menus: Cmd-N new, Cmd-O open, Cmd-W close, Cmd-S save, Cmd-P print, Cmd-F find,",
        " Cmd-G find next, Cmd-B bold, Cmd-I italic, Cmd-U underline, Cmd-E center,",
        " Cmd-R reveal codes, Opt-Cmd-F replace, Cmd-; spell check."
    ]

    override func draw(_ dirtyRect: NSRect) {
        let cols = 80
        let rows = 25
        let cw = bounds.width / CGFloat(cols)
        let ch = bounds.height / CGFloat(rows)
        Palette.blue.setFill()
        bounds.fill()

        // Largest size whose characters fit the cell both across and down.
        let ratios = ScreenView.fontRatios
        let fsize = max(6, min(cw / ratios.width, ch / ratios.height))
        let font = ScreenView.screenFont(size: fsize)
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let glyphW = ("M" as NSString).size(withAttributes: [.font: font]).width
        let glyphH = font.ascender - font.descender

        // Bold shows as bright white rather than a heavier face; italic uses the italic face.
        func put(_ r: Int, _ c: Int, _ s: String, _ fg: NSColor,
                 bg: NSColor? = nil, under: Bool = false, italic: Bool = false) {
            if c < 0 || c >= cols || r < 0 || r >= rows { return }
            let x = CGFloat(c) * cw
            let y = CGFloat(r) * ch
            if let bg = bg {
                bg.setFill()
                NSRect(x: x, y: y, width: cw, height: ch).fill()
            }
            if s != " " {
                (s as NSString).draw(
                    at: NSPoint(x: x + (cw - glyphW) / 2, y: y + (ch - glyphH) / 2),
                    withAttributes: [.font: italic ? italicFont : font, .foregroundColor: fg])
            }
            if under {
                fg.setFill()
                let th = max(1, ch * 0.08)
                NSRect(x: x, y: y + ch - th - ch * 0.06, width: cw, height: th).fill()
            }
        }

        func putString(_ r: Int, _ c: Int, _ s: String, _ fg: NSColor) {
            var col = c
            for chh in s {
                put(r, col, String(chh), fg)
                col += 1
            }
        }

        // Launch splash: the app icon in the middle of the screen with the version lines beneath it,
        // like WordPerfect's copyright notice. Drawn over everything and faded as one layer, so the
        // editor shows through evenly as it goes.
        func drawSplash() {
            if splashTimer != nil && splashStart == nil { splashStart = Date() }
            let alpha = splashAlpha()
            guard alpha > 0, let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            cg.setAlpha(alpha)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            Palette.blue.setFill()
            bounds.fill()
            let side = ch * 10     // rows 5-14
            if let icon = splashIcon {
                icon.draw(in: NSRect(x: (bounds.width - side) / 2, y: ch * 5, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            let title = "TextPerfect v" + version
            let tagline = "write something cool!"
            putString(16, (cols - title.count) / 2, title, Palette.white)
            putString(18, (cols - tagline.count) / 2, tagline, Palette.grey)
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        defer { drawSplash() }

        if showHelp {
            for (n, line) in ScreenView.helpText.enumerated() {
                putString(n, 0, line, n == 0 ? Palette.white : Palette.grey)
            }
            return
        }

        let lines = normalLines()
        let pag = pagination(lines)
        let textRows = (splitScreen ? 11 : 24) - topMargin
        let curLine = lineIndex(of: cursor, in: lines, count: chars.count)
        let curRow = pag.rowOfLine[curLine]
        if followCursor {
            if curRow < topRow { topRow = curRow }
            if curRow >= topRow + textRows { topRow = curRow - textRows + 1 }
        }
        topRow = max(0, min(topRow, pag.rows.count - 1))

        // State carried into the first visible line.
        var bold = false
        var und = false
        var ital = false
        var k = 0
        var startIdx = chars.count
        for r in pag.rows[topRow...] {
            if case .line(let li) = r { startIdx = lines[li].start; break }
        }
        while k < startIdx {
            applyState(chars[k], &bold, &und, &ital)
            k += 1
        }

        let sel = selectionRange()

        for row in 0..<textRows {
            if topRow + row >= pag.rows.count { break }
            let li: Int
            switch pag.rows[topRow + row] {
            case .pageBreak(let hard):
                // WordPerfect's page-break bars: dashes for a soft break, double line for [HPg].
                putString(row + topMargin, 0, String(repeating: hard ? "=" : "-", count: cols), Palette.grey)
                continue
            case .line(let n):
                li = n
            }
            let l = lines[li]
            var col = leftMargin + lineOffset(l)
            var i = l.start
            while i < l.end {
                let c = chars[i]
                applyState(c, &bold, &und, &ital)
                if Code.isVisible(c) {
                    let selected = sel?.contains(i) ?? false
                    let fg = selected ? Palette.blue : (bold ? Palette.white : Palette.grey)
                    put(row + topMargin, col, String(c), fg, bg: selected ? Palette.grey : nil,
                        under: und, italic: ital)
                    col += 1
                }
                i += 1
            }
        }

        // Cursor
        let cl = lines[curLine]
        let cursorCol = leftMargin + lineOffset(cl) + colWidth(from: cl.start, to: cursor)
        let cursorRow = curRow - topRow
        if blinkOn && prompt == nil && cursorRow >= 0 && cursorRow < textRows
            && cursorCol >= 0 && cursorCol < cols {
            if typeover {
                var under: Character = " "
                if cursor < chars.count && Code.isVisible(chars[cursor]) {
                    under = chars[cursor]
                }
                put(cursorRow + topMargin, cursorCol, String(under), Palette.blue, bg: Palette.grey)
            } else {
                Palette.grey.setFill()
                let x = CGFloat(cursorCol) * cw
                let y = CGFloat(cursorRow + topMargin) * ch
                NSRect(x: x, y: y + ch * 0.82, width: cw, height: ch * 0.12).fill()
            }
        }

        // Spell pane: lettered suggestions for the highlighted word, three columns of eight
        if let sp = spell {
            for c in 0..<cols { put(11, c, "-", Palette.blue, bg: Palette.grey) }
            if sp.suggestions.isEmpty {
                putString(13, leftMargin, "(no suggestions)", Palette.grey)
            }
            for (n, word) in sp.suggestions.enumerated() {
                let r = 13 + n % 8
                let c = leftMargin + (n / 8) * 25
                let letter = String(Array("ABCDEFGHIJKLMNOPQRSTUVWX")[n])
                putString(r, c, letter + ".", Palette.white)
                putString(r, c + 3, String(word.prefix(21)), Palette.grey)
            }
        } else if revealCodes {      // Reveal Codes pane
            for c in 0..<cols {
                var s = "-"
                if c == leftMargin {
                    s = "{"
                } else if c == leftMargin + lineWidth - 1 {
                    s = "}"
                } else if c > leftMargin && c < leftMargin + lineWidth - 1 && (c - leftMargin) % 5 == 0 {
                    s = "|"
                }
                put(11, c, s, Palette.blue, bg: Palette.grey)
            }
            let rl = layoutLines(chars, width: cols, reveal: true)
            let rc = lineIndex(of: cursor, in: rl, count: chars.count)
            let paneRows = 12
            let rs = max(0, rc - 1)
            for r in 0..<paneRows {
                let li = rs + r
                if li >= rl.count { break }
                var col = 0
                var i = rl[li].start
                while i < rl[li].end {
                    let c = chars[i]
                    let isCursor = (i == cursor)
                    let isCode = !Code.isVisible(c)
                    for chh in Code.label(c) {
                        put(12 + r, col, String(chh),
                            isCursor ? Palette.blue : (isCode ? Palette.white : Palette.grey),
                            bg: isCursor ? Palette.grey : nil)
                        col += 1
                    }
                    i += 1
                }
                if li == rl.count - 1 && cursor == chars.count {
                    put(12 + r, col, " ", Palette.blue, bg: Palette.grey)
                }
            }
        }

        // Status line
        if let p = prompt {
            var text = p.label
            if p.kind == .text { text += " " + p.text }
            if p.kind == .yesNo {
                // The answer keys stand out: after the question, the Y of "Yes" and the N of "No"
                // stay bright and the rest of each word is dimmed.
                let cs = Array(text)
                var afterQuestion = false
                var dim = 0
                for (i, c) in cs.enumerated() {
                    var fg = Palette.white
                    if dim > 0 {
                        fg = Palette.grey
                        dim -= 1
                    } else if afterQuestion && c == "Y" && String(cs[i...].prefix(3)) == "Yes" {
                        dim = 2
                    } else if afterQuestion && c == "N" && String(cs[i...].prefix(2)) == "No" {
                        dim = 1
                    }
                    if c == "?" { afterQuestion = true }
                    put(24, i, String(c), fg)
                }
            } else {
                putString(24, 0, text, Palette.white)
            }
            if blinkOn && p.kind == .text {
                Palette.grey.setFill()
                let x = CGFloat(text.count) * cw
                NSRect(x: x, y: CGFloat(24) * ch + ch * 0.82, width: cw, height: ch * 0.12).fill()
            }
        } else {
            var left = message
            if left.isEmpty {
                if blockMode { left = "Block on" } else if typeover { left = "Typeover" }
            }
            if left.isEmpty {
                putString(24, 0, "F3 = Help", Palette.grey)   // a quiet hint whenever there's nothing to report
            } else {
                putString(24, 0, left, Palette.white)
            }

            var bAt = false
            var uAt = false
            var iAt = false
            var q = 0
            while q < cursor && q < chars.count {
                applyState(chars[q], &bAt, &uAt, &iAt)
                q += 1
            }
            let pg = pag.page[curLine]
            let ln = 1.0 + Double(pag.lineOnPage[curLine]) / linesPerInch
            let pos = Double(cursorCol - leftMargin + posBase) / 10.0
            let head = "Doc 1 Pg \(pg) Ln \(inchString(ln)) "
            let posText = "Pos " + inchString(pos)
            let startCol = cols - (head.count + posText.count) - 1
            putString(24, startCol, head, Palette.grey)
            var col = startCol + head.count
            for chh in posText {
                put(24, col, String(chh), bAt ? Palette.white : Palette.grey, under: uAt, italic: iAt)
                col += 1
            }
        }
    }
}
