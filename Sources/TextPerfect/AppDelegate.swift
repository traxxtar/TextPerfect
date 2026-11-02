import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var screen: ScreenView!
    var pendingOpen: URL?   // a file opened before the window existed (TextPerfect launched by the drop)

    func applicationDidFinishLaunching(_ notification: Notification) {
        screen = ScreenView(frame: NSRect(x: 0, y: 0, width: 960, height: 600))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentView = screen
        window.title = "TextPerfect"
        window.delegate = self
        window.contentAspectRatio = NSSize(width: 960, height: 600)
        window.contentMinSize = NSSize(width: 640, height: 400)
        // Open in the exact center of the screen. (NSWindow.center() sits it a little above center.)
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        } else {
            window.center()
        }
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(screen)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let url = pendingOpen {
            pendingOpen = nil
            screen.openDroppedFile(url)
        }
    }

    /// Files dropped on the Dock icon, or opened with TextPerfect from Finder. Only one document
    /// is open at a time, so of several files only the first is opened.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL && !$0.hasDirectoryPath }) else { return }
        if screen == nil {
            pendingOpen = url
            return
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        screen.openDroppedFile(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Dock Quit, logout and restart arrive here without going through quit(_:).
    /// Stop them while there are unsaved changes and run the normal Exit prompts instead.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if screen.exitConfirmed || !screen.modified { return .terminateNow }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        screen.requestExit()
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        screen.requestExit()
        return false
    }

    @objc func quit(_ sender: Any?) {
        screen.requestExit()
    }

    func buildMenu() {
        let main = NSMenu()

        func addItem(_ menu: NSMenu, _ title: String, _ action: String, _ key: String,
                     mods: NSEvent.ModifierFlags = [.command], target: AnyObject) {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            menu.addItem(item)
        }

        func addMenu(_ title: String) -> NSMenu {
            let holder = NSMenuItem()
            main.addItem(holder)
            let menu = NSMenu(title: title)
            holder.submenu = menu
            return menu
        }

        let app = addMenu("TextPerfect")
        addItem(app, "About TextPerfect", "orderFrontStandardAboutPanel:", "", target: NSApp)
        app.addItem(NSMenuItem.separator())
        addItem(app, "Hide TextPerfect", "hide:", "h", target: NSApp)
        app.addItem(NSMenuItem.separator())
        addItem(app, "Quit TextPerfect", "quit:", "q", target: self)

        let file = addMenu("File")
        addItem(file, "New", "menuNew:", "n", target: screen)
        addItem(file, "Open\u{2026}", "menuOpen:", "o", target: screen)
        addItem(file, "Retrieve Into Document\u{2026}", "menuRetrieve:", "o",
                mods: [.command, .shift], target: screen)
        file.addItem(NSMenuItem.separator())
        addItem(file, "Close", "menuClose:", "w", target: screen)
        addItem(file, "Save", "menuSave:", "s", target: screen)
        addItem(file, "Save As\u{2026}", "menuSaveAs:", "s", mods: [.command, .shift], target: screen)
        file.addItem(NSMenuItem.separator())
        addItem(file, "Print\u{2026}", "menuPrint:", "p", target: screen)

        let edit = addMenu("Edit")
        addItem(edit, "Undo", "undo:", "z", target: screen)
        edit.addItem(NSMenuItem.separator())
        addItem(edit, "Cut", "cut:", "x", target: screen)
        addItem(edit, "Copy", "copy:", "c", target: screen)
        addItem(edit, "Paste", "paste:", "v", target: screen)
        addItem(edit, "Select All", "selectAll:", "a", target: screen)
        edit.addItem(NSMenuItem.separator())
        addItem(edit, "Find\u{2026}", "menuFind:", "f", target: screen)
        addItem(edit, "Find Next", "menuFindNext:", "g", target: screen)
        addItem(edit, "Replace\u{2026}", "menuReplace:", "f", mods: [.command, .option], target: screen)
        edit.addItem(NSMenuItem.separator())
        addItem(edit, "Insert Date", "menuDate:", "", target: screen)

        let format = addMenu("Format")
        addItem(format, "Bold", "menuBold:", "b", target: screen)
        addItem(format, "Italic", "menuItalic:", "i", target: screen)
        addItem(format, "Underline", "menuUnderline:", "u", target: screen)
        addItem(format, "Center Line", "menuCenter:", "e", target: screen)
        addItem(format, "Indent", "menuIndent:", "", target: screen)
        addItem(format, "Hard Page Break", "menuPageBreak:", "\r", mods: [.control], target: screen)
        addItem(format, "Margins\u{2026}", "menuMargins:", "m", mods: [.command, .shift], target: screen)
        format.addItem(NSMenuItem.separator())
        addItem(format, "Reveal Codes", "menuReveal:", "r", target: screen)
        addItem(format, "Block On/Off", "menuBlock:", "k", target: screen)
        addItem(format, "Typeover On/Off", "menuTypeover:", "t", target: screen)

        let help = addMenu("Help")
        addItem(help, "Key Reference", "menuHelp:", "", target: screen)

        NSApp.mainMenu = main
    }
}
