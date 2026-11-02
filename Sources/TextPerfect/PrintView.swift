import AppKit

/// One printed line: its text, already styled, and how far in from the left margin it starts.
struct PrintLine {
    var x: CGFloat
    var text: NSAttributedString
}

/// Prints pages exactly as TextPerfect lays them out on screen. Each page holds its own lines,
/// so line wrapping and both hard and soft page breaks land where the screen shows them,
/// instead of wherever AppKit would cut one long text view.
final class PrintPagesView: NSView {
    let pages: [[PrintLine]]
    let lineHeight: CGFloat
    let pageHeight: CGFloat
    let glyphOffset: CGFloat   // centres the font's line box in each line slot

    init(pages: [[PrintLine]], width: CGFloat, lineHeight: CGFloat, linesPerPage: Int, font: NSFont) {
        self.pages = pages
        self.lineHeight = lineHeight
        self.pageHeight = lineHeight * CGFloat(linesPerPage)
        self.glyphOffset = (lineHeight - (font.ascender - font.descender)) / 2
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: pageHeight * CGFloat(max(1, pages.count))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        return NSRect(x: 0, y: CGFloat(page - 1) * pageHeight, width: bounds.width, height: pageHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (p, lines) in pages.enumerated() {
            let top = CGFloat(p) * pageHeight
            guard NSRect(x: 0, y: top, width: bounds.width, height: pageHeight).intersects(dirtyRect) else { continue }
            for (n, line) in lines.enumerated() {
                line.text.draw(at: NSPoint(x: line.x, y: top + CGFloat(n) * lineHeight + glyphOffset))
            }
        }
    }
}
