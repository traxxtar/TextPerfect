import Foundation

/// Formatting codes live inside the text as private-use characters.
enum Code {
    static let boldOn: Character = "\u{E000}"
    static let boldOff: Character = "\u{E001}"
    static let undOn: Character = "\u{E002}"
    static let undOff: Character = "\u{E003}"
    static let center: Character = "\u{E004}"
    static let italOn: Character = "\u{E005}"
    static let italOff: Character = "\u{E006}"
    /// Hard page break. Not an invisible formatting code: like a newline it ends the line,
    /// the cursor can sit either side of it, and Backspace deletes it.
    static let hardPage: Character = "\u{E007}"
    /// One level of paragraph indent (one tab stop). Indent codes sit at the start of a
    /// paragraph and move every line of it, wrapped lines included, in by 5 columns each.
    static let indent: Character = "\u{E008}"
    static let indentWidth = 5

    /// Invisible formatting codes (not newlines or page breaks).
    static func isCode(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (v >= 0xE000 && v <= 0xE006) || v == 0xE008
    }

    static func isLineEnd(_ c: Character) -> Bool {
        return c == "\n" || c == hardPage
    }

    /// True for characters that occupy a column in normal view.
    static func isVisible(_ c: Character) -> Bool {
        return !isLineEnd(c) && !isCode(c)
    }

    static func label(_ c: Character) -> String {
        switch c {
        case boldOn: return "[Bold]"
        case boldOff: return "[bold]"
        case undOn: return "[Undrln]"
        case undOff: return "[undrln]"
        case italOn: return "[Italc]"
        case italOff: return "[italc]"
        case center: return "[Center]"
        case "\n": return "[HRt]"
        case hardPage: return "[HPg]"
        case indent: return "[\u{2192}Indent]"
        default: return String(c)
        }
    }

    static func partner(of c: Character) -> Character? {
        switch c {
        case boldOn: return boldOff
        case boldOff: return boldOn
        case undOn: return undOff
        case undOff: return undOn
        case italOn: return italOff
        case italOff: return italOn
        default: return nil
        }
    }

    static func isOpening(_ c: Character) -> Bool {
        return c == boldOn || c == undOn || c == italOn
    }

    /// Screen width of a character. Codes are invisible in normal view
    /// and shown as bracketed tokens in Reveal Codes view.
    static func width(_ c: Character, reveal: Bool) -> Int {
        if isLineEnd(c) || isCode(c) { return reveal ? label(c).count : 0 }
        return 1
    }
}

struct LineInfo {
    var start: Int
    var end: Int        // exclusive; a hard line includes its newline or page break
    var centered: Bool
    var endsPage = false   // the line ends with a hard page break
    var indent = 0         // columns the paragraph's indent codes move this line in
}

/// Indent, in columns, of the paragraph starting at `start`: one tab stop for each indent
/// code among the codes before its first visible character.
func paragraphIndent(_ chars: [Character], from start: Int) -> Int {
    var n = 0
    var k = start
    while k < chars.count && Code.isCode(chars[k]) {
        if chars[k] == Code.indent { n += 1 }
        k += 1
    }
    return n * Code.indentWidth
}

func layoutLines(_ chars: [Character], width: Int, reveal: Bool) -> [LineInfo] {
    var lines: [LineInfo] = []
    var start = 0
    var w = 0
    var lastBreak = -1
    var paraStart = 0
    var centered = false
    var indent = 0          // normal view only; Reveal Codes shows the codes themselves instead
    var avail = width       // columns left for text once the paragraph's indent is taken out
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if i == paraStart {
            centered = (c == Code.center)
            indent = reveal ? 0 : min(paragraphIndent(chars, from: i), max(0, width - 10))
            avail = width - indent
        }
        if Code.isLineEnd(c) {
            let nw = Code.width(c, reveal: reveal)
            if w > 0 && w + nw > avail {
                lines.append(LineInfo(start: start, end: i, centered: centered, indent: indent))
                start = i
            }
            lines.append(LineInfo(start: start, end: i + 1, centered: centered,
                                  endsPage: c == Code.hardPage, indent: indent))
            start = i + 1
            w = 0
            lastBreak = -1
            paraStart = i + 1
            i += 1
            continue
        }
        let cw = Code.width(c, reveal: reveal)
        if c != " " && w > 0 && w + cw > avail {
            if lastBreak > start {
                lines.append(LineInfo(start: start, end: lastBreak, centered: centered, indent: indent))
                start = lastBreak
                w = 0
                var k = start
                while k < i {
                    w += Code.width(chars[k], reveal: reveal)
                    k += 1
                }
            } else {
                lines.append(LineInfo(start: start, end: i, centered: centered, indent: indent))
                start = i
                w = 0
            }
            lastBreak = -1
        }
        w += cw
        if c == " " { lastBreak = i + 1 }
        i += 1
    }
    let empty = start == chars.count
    lines.append(LineInfo(start: start, end: chars.count,
                          centered: empty ? false : centered, indent: empty ? 0 : indent))
    return lines
}

func lineIndex(of idx: Int, in lines: [LineInfo], count: Int) -> Int {
    if idx >= count { return lines.count - 1 }
    var lo = 0
    var hi = lines.count - 1
    while lo < hi {
        let mid = (lo + hi) / 2
        if idx < lines[mid].end { hi = mid } else { lo = mid + 1 }
    }
    return lo
}

/// What one screen row shows: a line of text, or the bar marking a page break.
enum ScreenRow {
    case line(Int)
    case pageBreak(hard: Bool)
}

/// Splits laid-out lines into pages. A page ends after `linesPerPage` lines (a soft break)
/// or after a line ending in a hard page break, whichever comes first.
struct Pagination {
    var page: [Int] = []          // 1-based page number of each line
    var lineOnPage: [Int] = []    // 0-based position of each line within its page
    var rows: [ScreenRow] = []    // screen rows: every line, with a bar wherever a page ends
    var rowOfLine: [Int] = []     // index into `rows` for each line

    init(_ lines: [LineInfo], linesPerPage: Int) {
        var pg = 1
        var onPage = 0
        for (i, l) in lines.enumerated() {
            if onPage == linesPerPage {
                rows.append(.pageBreak(hard: false))
                pg += 1
                onPage = 0
            }
            page.append(pg)
            lineOnPage.append(onPage)
            rowOfLine.append(rows.count)
            rows.append(.line(i))
            onPage += 1
            if l.endsPage && i < lines.count - 1 {
                rows.append(.pageBreak(hard: true))
                pg += 1
                onPage = 0
            }
        }
    }
}

func applyState(_ c: Character, _ bold: inout Bool, _ und: inout Bool, _ ital: inout Bool) {
    switch c {
    case Code.boldOn: bold = true
    case Code.boldOff: bold = false
    case Code.undOn: und = true
    case Code.undOff: und = false
    case Code.italOn: ital = true
    case Code.italOff: ital = false
    default: break
    }
}

/// Drops control characters and Mac function-key private-use characters.
/// Input must already have \r\n and \r normalized to \n.
/// `pageBreaks` keeps hard page breaks, and turns form feeds (the plain-text page break) into them.
func sanitize(_ s: String, allowCodes: Bool, pageBreaks: Bool = false) -> [Character] {
    var out: [Character] = []
    for c in s {
        if c == "\n" { out.append(c); continue }
        if c == "\u{0C}" {
            if pageBreaks { out.append(Code.hardPage) }
            continue
        }
        guard let v = c.unicodeScalars.first?.value else { continue }
        if v < 32 || v == 127 { continue }
        if v >= 0xF700 && v <= 0xF8FF { continue }
        if v >= 0xE000 && v <= 0xE0FF {
            if (allowCodes && Code.isCode(c)) || (pageBreaks && c == Code.hardPage) { out.append(c) }
            continue
        }
        out.append(c)
    }
    return out
}

func inchString(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s + "\""
}
