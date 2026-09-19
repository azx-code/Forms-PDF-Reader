import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Shortcut Store

class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    private let ud = UserDefaults.standard

    @Published var cursor: String        { didSet { ud.set(cursor,        forKey: "sc_cursor") } }
    @Published var highlight: String     { didSet { ud.set(highlight,     forKey: "sc_highlight") } }
    @Published var strikethrough: String { didSet { ud.set(strikethrough, forKey: "sc_strikethrough") } }
    @Published var textBox: String       { didSet { ud.set(textBox,       forKey: "sc_textBox") } }
    @Published var switchTab: String     { didSet { ud.set(switchTab,     forKey: "sc_switchTab") } }
    @Published var openQuiz: String      { didSet { ud.set(openQuiz,      forKey: "sc_quiz") } }
    @Published var questionCount: Int    { didSet { ud.set(questionCount, forKey: "sc_questionCount") } }

    init() {
        cursor        = ud.string(forKey: "sc_cursor")        ?? "a"
        highlight     = ud.string(forKey: "sc_highlight")     ?? "s"
        strikethrough = ud.string(forKey: "sc_strikethrough") ?? "d"
        textBox       = ud.string(forKey: "sc_textBox")       ?? "t"
        switchTab     = ud.string(forKey: "sc_switchTab")     ?? "f"
        openQuiz      = ud.string(forKey: "sc_quiz")          ?? ""
        let stored    = ud.integer(forKey: "sc_questionCount")
        questionCount = stored > 0 ? stored : 50
    }
}

// MARK: - App

@main
struct PDFReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 750, minHeight: 550)
                .environmentObject(appDelegate)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(before: .windowArrangement) {
                Button("Close Tab") { appDelegate.closeCurrentTabAction?() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var hasUnsavedChanges: (() -> Bool)?
    var performSave: (() -> Void)?
    var allHosts: (() -> [PDFViewHost]) = { [] }
    var closeCurrentTabAction: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = allHosts().filter { $0.hasUnsavedChanges || $0.hasUnsavedQuizData }
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save PDF before closing?"
        alert.informativeText = "Your annotations will be lost if you don't save."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let count = dirty.count
        alert.messageText = count > 1
            ? "Save \(count) PDFs before closing?"
            : "Save PDF before closing?"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            dirty.forEach { $0.save() }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Window Close Interceptor
// Hooks into NSWindowDelegate.windowShouldClose so the red close button also
// triggers the save prompt (applicationShouldTerminate only catches Cmd+Q).

struct WindowCloseInterceptor: NSViewRepresentable {
    let getAllHosts: () -> [PDFViewHost]

    func makeCoordinator() -> Coordinator { Coordinator(getAllHosts: getAllHosts) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.delegate = context.coordinator }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.getAllHosts = getAllHosts
        DispatchQueue.main.async {
            if v.window?.delegate == nil { v.window?.delegate = context.coordinator }
        }
    }

    class Coordinator: NSObject, NSWindowDelegate {
        var getAllHosts: () -> [PDFViewHost]
        init(getAllHosts: @escaping () -> [PDFViewHost]) { self.getAllHosts = getAllHosts }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let dirty = getAllHosts().filter { $0.hasUnsavedChanges || $0.hasUnsavedQuizData }
            guard !dirty.isEmpty else { return true }
            let alert = NSAlert()
            let count = dirty.count
            alert.messageText = count > 1 ? "Save \(count) PDFs before closing?" : "Save PDF before closing?"
            alert.informativeText = "Your annotations will be lost if you don't save."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn: dirty.forEach { $0.save() }; return true
            case .alertSecondButtonReturn: dirty.forEach { $0.discardChanges() }; return true
            default: return false
            }
        }
    }
}

// MARK: - Tool Mode

enum AnnotationTool: CaseIterable {
    case cursor, highlight, strikethrough

    var icon: String {
        switch self {
        case .cursor:        return "cursorarrow"
        case .highlight:     return "highlighter"
        case .strikethrough: return "strikethrough"
        }
    }

    var label: String {
        switch self {
        case .cursor:        return "Cursor"
        case .highlight:     return "Highlight"
        case .strikethrough: return "Strikethrough"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .cursor:        return "j"
        case .highlight:     return "k"
        case .strikethrough: return "l"
        }
    }
}

// MARK: - Annotating PDFView subclass

class AnnotatingPDFView: PDFView {
    var onSelectionReleased: (() -> Void)?
    var onLeftClick: ((PDFPage, CGPoint) -> Void)?
    var onRightClick: ((PDFPage, CGPoint) -> Void)?
    var onAnnotationMoved: ((PDFAnnotation, PDFPage, CGRect, CGRect) -> Void)?
    var onAnnotationSelected: ((PDFAnnotation?, PDFPage?) -> Void)?
    var suppressContextMenu = false
    var cursorModeActive = false

    override func menu(for event: NSEvent) -> NSMenu? {
        suppressContextMenu ? nil : super.menu(for: event)
    }

    private var mouseDownLocation: CGPoint = .zero
    private var dragAnnotation: PDFAnnotation?
    private var dragPage: PDFPage?
    private var dragOriginalBounds: CGRect = .zero
    private var dragStartPagePt: CGPoint = .zero
    private var isResizingAnnotation = false
    private let resizeHandleRadius: CGFloat = 14

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        if cursorModeActive, let (ann, page, pagePt) = freeTextAt(event.locationInWindow) {
            dragAnnotation = ann
            dragPage = page
            dragOriginalBounds = ann.bounds
            dragStartPagePt = pagePt
            // Bottom-right corner (maxX, minY) in page coords → check in view coords
            let viewClickPt = convert(event.locationInWindow, from: nil)
            let cornerViewPt = convert(CGPoint(x: ann.bounds.maxX, y: ann.bounds.minY), from: page)
            let cdx = viewClickPt.x - cornerViewPt.x
            let cdy = viewClickPt.y - cornerViewPt.y
            isResizingAnnotation = (cdx * cdx + cdy * cdy < resizeHandleRadius * resizeHandleRadius)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let ann = dragAnnotation, let page = dragPage else {
            super.mouseDragged(with: event)
            return
        }
        let viewPt = convert(event.locationInWindow, from: nil)
        let pagePt = convert(viewPt, to: page)
        let dx = pagePt.x - dragStartPagePt.x
        let dy = pagePt.y - dragStartPagePt.y
        var nb = dragOriginalBounds
        if isResizingAnnotation {
            let w = max(40, dragOriginalBounds.width + dx)
            let h = max(20, dragOriginalBounds.height - dy)
            nb = CGRect(x: dragOriginalBounds.minX, y: dragOriginalBounds.maxY - h, width: w, height: h)
        } else {
            nb.origin.x += dx
            nb.origin.y += dy
        }
        ann.bounds = nb
    }

    override func mouseUp(with event: NSEvent) {
        if let ann = dragAnnotation, let page = dragPage {
            let finalBounds = ann.bounds
            if finalBounds != dragOriginalBounds {
                onAnnotationMoved?(ann, page, dragOriginalBounds, finalBounds)
                onAnnotationSelected?(nil, nil)
            } else {
                // No movement — treat as a selection click
                onAnnotationSelected?(ann, page)
            }
            dragAnnotation = nil; dragPage = nil; isResizingAnnotation = false
            return
        }
        // Clicking empty space deselects
        if cursorModeActive { onAnnotationSelected?(nil, nil) }
        super.mouseUp(with: event)
        let loc = event.locationInWindow
        let dx = loc.x - mouseDownLocation.x
        let dy = loc.y - mouseDownLocation.y
        if dx * dx + dy * dy < 25 {
            fireClick(at: loc, handler: \.onLeftClick)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.onSelectionReleased?()
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        fireClick(at: event.locationInWindow, handler: \.onRightClick)
    }

    private func freeTextAt(_ windowPoint: CGPoint) -> (PDFAnnotation, PDFPage, CGPoint)? {
        let viewPt = convert(windowPoint, from: nil)
        guard let page = self.page(for: viewPt, nearest: true) else { return nil }
        let pagePt = convert(viewPt, to: page)
        let hit = CGRect(x: pagePt.x - 4, y: pagePt.y - 4, width: 8, height: 8)
        if let ann = page.annotations.first(where: { $0.type == "FreeText" && $0.bounds.intersects(hit) }) {
            return (ann, page, pagePt)
        }
        return nil
    }

    private func fireClick(at windowPoint: CGPoint, handler: KeyPath<AnnotatingPDFView, ((PDFPage, CGPoint) -> Void)?>) {
        let viewPoint = convert(windowPoint, from: nil)
        guard let page = self.page(for: viewPoint, nearest: true) else { return }
        let pagePoint = convert(viewPoint, to: page)
        self[keyPath: handler]?(page, pagePoint)
    }
}

// MARK: - PDFViewHost

private enum UndoEntry {
    case added([(PDFAnnotation, PDFPage)])
    case removed([(PDFAnnotation, PDFPage)])
    case moved(PDFAnnotation, PDFPage, CGRect, CGRect)    // ann, page, oldBounds, newBounds
    case edited(PDFAnnotation, PDFPage, String, String)   // ann, page, oldContents, newContents
}

class PDFViewHost: ObservableObject {
    weak var pdfView: AnnotatingPDFView?
    weak var quizModel: QuizModel?

    @Published var hasUnsavedQuizData = false
    @Published var currentScale: CGFloat = 1.0
    @Published var activeTool: AnnotationTool = .highlight {
        didSet {
            pdfView?.suppressContextMenu = (activeTool == .highlight)
            pdfView?.cursorModeActive = (activeTool == .cursor)
            if activeTool != .cursor { selectedAnnotation = nil; selectedPage = nil }
        }
    }
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var selectedPage: PDFPage?
    @Published var highlightColor: Color = Color(red: 1.0, green: 1.0, blue: 0.0)
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasUnsavedChanges = false
    @Published var textBoxMode = false
    @Published var textEditorActive = false
    @Published var textBoxFontSize: CGFloat = 9
    @Published var textBoxFontColor: Color = .red
    @Published var findResults: [PDFSelection] = []
    @Published var findIndex: Int = -1
    @Published var isFinding = false
    var focusSearch: (() -> Void)?  // set by ToolbarSearchField NSViewRepresentable
    private var undoHistory: [UndoEntry] = []
    private var redoHistory: [UndoEntry] = []
    private var scaleObserver: NSKeyValueObservation?
    private let strikethroughTag = "__strikethrough__"

    private func isStrikethrough(_ ann: PDFAnnotation) -> Bool {
        ann.type == "StrikeOut" ||
        (ann.type == "Square" && ann.contents == strikethroughTag)
    }

    private func makeStrikeAnnotation(for bounds: CGRect) -> PDFAnnotation {
        let thickness = max(3.0, bounds.height * 0.13)
        let strikeBounds = CGRect(
            x: bounds.minX,
            y: bounds.midY - thickness / 2,
            width: bounds.width,
            height: thickness
        )
        let ann = PDFAnnotation(bounds: strikeBounds, forType: .square, withProperties: nil)
        ann.interiorColor = NSColor.red.withAlphaComponent(0.85)
        ann.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        ann.border = border
        ann.contents = strikethroughTag
        return ann
    }

    func attach(_ view: AnnotatingPDFView) {
        pdfView = view
        view.suppressContextMenu = (activeTool == .highlight)
        view.cursorModeActive = (activeTool == .cursor)
        scaleObserver = view.observe(\.scaleFactor, options: [.new]) { [weak self] _, change in
            if let s = change.newValue {
                DispatchQueue.main.async { self?.currentScale = s }
            }
        }
        view.onSelectionReleased = { [weak self] in self?.handleSelectionReleased() }
        view.onLeftClick = { [weak self] page, pt in self?.handleLeftClick(page: page, pagePoint: pt) }
        view.onRightClick = { [weak self] page, pt in self?.handleRightClick(page: page, pagePoint: pt) }
        view.onAnnotationMoved = { [weak self] ann, page, old, new in
            self?.pushUndo(.moved(ann, page, old, new))
        }
        view.onAnnotationSelected = { [weak self] ann, page in
            if let ann = ann, let page = page {
                self?.reopenEditor(for: ann, page: page)
            }
        }
    }

    func reopenEditor(for ann: PDFAnnotation, page: PDFPage) {
        guard let pdfView = pdfView else { return }
        let pageTopLeft  = CGPoint(x: ann.bounds.minX, y: ann.bounds.maxY)
        let pageBotRight = CGPoint(x: ann.bounds.maxX, y: ann.bounds.minY)
        let viewTL = pdfView.convert(pageTopLeft,  from: page)
        let viewBR = pdfView.convert(pageBotRight, from: page)
        let editorW = max(200, abs(viewBR.x - viewTL.x))
        let editorH = max(60,  abs(viewBR.y - viewTL.y))
        let editorOriginY: CGFloat = pdfView.isFlipped ? viewTL.y : viewTL.y - editorH
        let editorFrame = CGRect(x: viewTL.x, y: editorOriginY, width: editorW, height: editorH)

        let pdfFont     = ann.font      ?? NSFont.systemFont(ofSize: textBoxFontSize)
        let displayFont = NSFont.systemFont(ofSize: pdfFont.pointSize * pdfView.scaleFactor)
        let color       = ann.fontColor ?? NSColor(textBoxFontColor)

        // Hide annotation while editing so there's no ghost text underneath
        page.removeAnnotation(ann)

        let editor = TextBoxEditor(frame: editorFrame, font: displayFont, color: color)
        editor.textView.string = ann.contents ?? ""
        textEditorActive = true
        let oldContents = ann.contents ?? ""
        editor.onCommit = { [weak self] newText in
            self?.textEditorActive = false
            if newText.isEmpty {
                self?.pushUndo(.removed([(ann, page)]))
                return
            }
            ann.contents = newText
            page.addAnnotation(ann)
            if newText != oldContents {
                self?.pushUndo(.edited(ann, page, oldContents, newText))
            }
        }
        editor.onCancel = { [weak self] in
            self?.textEditorActive = false
            page.addAnnotation(ann)
        }
        pdfView.addSubview(editor)
        editor.textView.window?.makeFirstResponder(editor.textView)
    }

    func deleteSelectedAnnotation() {
        guard let ann = selectedAnnotation, let page = selectedPage else { return }
        page.removeAnnotation(ann)
        pushUndo(.removed([(ann, page)]))
        selectedAnnotation = nil
        selectedPage = nil
    }

    // Auto-apply current tool when the user finishes a drag-selection.
    private func handleSelectionReleased() {
        if textBoxMode { return }
        switch activeTool {
        case .cursor: break
        case .highlight:
            applyAnnotation(subtype: .highlight, color: NSColor(highlightColor))
        case .strikethrough:
            applyAnnotation(subtype: .strikeOut, color: NSColor.red.withAlphaComponent(0.85))
        }
    }

    // Left-click: remove annotation under cursor, or place text box.
    private func handleLeftClick(page: PDFPage, pagePoint: CGPoint) {
        if textBoxMode {
            // Clicking an existing freeText annotation switches to cursor+select instead of spawning a new editor
            let hit = CGRect(x: pagePoint.x - 4, y: pagePoint.y - 4, width: 8, height: 8)
            if let existing = page.annotations.first(where: { $0.type == "FreeText" && $0.bounds.intersects(hit) }) {
                textBoxMode = false
                activeTool = .cursor
                reopenEditor(for: existing, page: page)
                return
            }
            addTextBox(page: page, pagePoint: pagePoint)
            return
        }
        guard let hit = page.annotations.first(where: {
            ($0.type == "Highlight" || isStrikethrough($0)) && $0.bounds.contains(pagePoint)
        }) else { return }
        page.removeAnnotation(hit)
        pushUndo(.removed([(hit, page)]))
    }

    private func addTextBox(page: PDFPage, pagePoint: CGPoint) {
        guard let pdfView = pdfView else { return }

        let viewPt = pdfView.convert(pagePoint, from: page)
        let editorW: CGFloat = 380
        let editorH: CGFloat = 140

        let editorOriginY: CGFloat = pdfView.isFlipped ? viewPt.y : viewPt.y - editorH
        let editorFrame = CGRect(x: viewPt.x, y: editorOriginY, width: editorW, height: editorH)

        let pdfFont     = NSFont.systemFont(ofSize: textBoxFontSize)
        let displayFont = NSFont.systemFont(ofSize: textBoxFontSize * pdfView.scaleFactor)
        let color       = NSColor(textBoxFontColor)

        let editor = TextBoxEditor(frame: editorFrame, font: displayFont, color: color)
        textEditorActive = true
        editor.onCommit = { [weak self, weak pdfView] text in
            self?.textEditorActive = false
            guard let self = self, let pdfView = pdfView, !text.isEmpty else { return }
            let topY    = pdfView.isFlipped ? editorFrame.minY : editorFrame.maxY
            let bottomY = pdfView.isFlipped ? editorFrame.maxY : editorFrame.minY
            let tlPage = pdfView.convert(CGPoint(x: editorFrame.minX, y: topY),    to: page)
            let brPage = pdfView.convert(CGPoint(x: editorFrame.maxX, y: bottomY), to: page)
            let annBounds = CGRect(
                x: min(tlPage.x, brPage.x), y: min(tlPage.y, brPage.y),
                width: abs(brPage.x - tlPage.x), height: abs(tlPage.y - brPage.y)
            )
            let ann = PDFAnnotation(bounds: annBounds, forType: .freeText, withProperties: nil)
            ann.font      = pdfFont   // unscaled — PDF renders at correct size
            ann.fontColor = color
            ann.color     = .clear
            ann.contents  = text
            let border    = PDFBorder(); border.lineWidth = 0; ann.border = border
            page.addAnnotation(ann)
            self.pushUndo(.added([(ann, page)]))
        }
        editor.onCancel = { [weak self] in self?.textEditorActive = false }

        pdfView.addSubview(editor)
        editor.textView.window?.makeFirstResponder(editor.textView)
    }

    // MARK: – Find
    func search(_ query: String) {
        findResults = []
        findIndex = -1
        pdfView?.clearSelection()
        guard !query.isEmpty, let doc = pdfView?.document else { return }
        isFinding = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = doc.findString(query, withOptions: .caseInsensitive)
            DispatchQueue.main.async {
                self?.findResults = results
                self?.isFinding = false
                if !results.isEmpty {
                    self?.findIndex = 0
                    self?.pdfView?.setCurrentSelection(results[0], animate: true)
                    self?.pdfView?.scrollSelectionToVisible(nil)
                }
            }
        }
    }

    func findNext() {
        guard !findResults.isEmpty else { return }
        findIndex = (findIndex + 1) % findResults.count
        pdfView?.setCurrentSelection(findResults[findIndex], animate: true)
        pdfView?.scrollSelectionToVisible(nil)
    }

    func findPrev() {
        guard !findResults.isEmpty else { return }
        findIndex = (findIndex - 1 + findResults.count) % findResults.count
        pdfView?.setCurrentSelection(findResults[findIndex], animate: true)
        pdfView?.scrollSelectionToVisible(nil)
    }

    func clearFind() {
        findResults = []
        findIndex = -1
        isFinding = false
        pdfView?.clearSelection()
    }

    // Right-click in highlight mode: strikethrough the line under the cursor.
    private func handleRightClick(page: PDFPage, pagePoint: CGPoint) {
        guard activeTool == .highlight else { return }
        guard let selection = page.selectionForLine(at: pagePoint),
              let str = selection.string, !str.isEmpty else { return }
        let bounds = selection.bounds(for: page)
        guard bounds.width > 1, bounds.height > 1 else { return }

        // Toggle: right-clicking an already-struck line removes it.
        let existing = page.annotations.filter { isStrikethrough($0) && $0.bounds.intersects(bounds) }
        if !existing.isEmpty {
            existing.forEach { page.removeAnnotation($0) }
            pushUndo(.removed(existing.map { ($0, page) }))
            return
        }

        let ann = makeStrikeAnnotation(for: bounds)
        page.addAnnotation(ann)
        pushUndo(.added([(ann, page)]))
    }

    func discardChanges() { hasUnsavedChanges = false; hasUnsavedQuizData = false }

    func undo() {
        guard let entry = undoHistory.popLast() else { return }
        switch entry {
        case .added(let items):              items.forEach { $0.1.removeAnnotation($0.0) }
        case .removed(let items):            items.forEach { $0.1.addAnnotation($0.0) }
        case .moved(let ann, _, let old, _): ann.bounds = old
        case .edited(let ann, _, let old, _): ann.contents = old
        }
        redoHistory.append(entry)
        canUndo = !undoHistory.isEmpty
        canRedo = true
    }

    func redo() {
        guard let entry = redoHistory.popLast() else { return }
        switch entry {
        case .added(let items):               items.forEach { $0.1.addAnnotation($0.0) }
        case .removed(let items):             items.forEach { $0.1.removeAnnotation($0.0) }
        case .moved(let ann, _, _, let new):  ann.bounds = new
        case .edited(let ann, _, _, let new): ann.contents = new
        }
        undoHistory.append(entry)
        canUndo = true
        canRedo = !redoHistory.isEmpty
        hasUnsavedChanges = true
    }

    private func pushUndo(_ entry: UndoEntry) {
        undoHistory.append(entry)
        redoHistory.removeAll()
        canUndo = true
        canRedo = false
        hasUnsavedChanges = true
    }

    func save() {
        guard let document = pdfView?.document else { return }
        if let qm = quizModel { embedQuizData(qm, in: document) }
        if let url = document.documentURL {
            document.write(to: url)
            hasUnsavedChanges = false
            hasUnsavedQuizData = false
        } else {
            saveAs()
        }
    }

    func saveAs() {
        guard let document = pdfView?.document else { return }
        if let qm = quizModel { embedQuizData(qm, in: document) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.documentURL?.lastPathComponent ?? "document.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.write(to: url)
        hasUnsavedChanges = false
        hasUnsavedQuizData = false
    }

    func applyHighlight() {
        applyAnnotation(subtype: .highlight, color: NSColor(highlightColor))
    }

    func applyStrikethrough() {
        applyAnnotation(subtype: .strikeOut, color: NSColor.red.withAlphaComponent(0.85))
    }

    private func applyAnnotation(subtype: PDFAnnotationSubtype, color: NSColor) {
        guard let pdfView, let selection = pdfView.currentSelection else { return }
        var added: [(PDFAnnotation, PDFPage)] = []
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let bounds = line.bounds(for: page)
            let ann: PDFAnnotation
            if subtype == .strikeOut {
                ann = makeStrikeAnnotation(for: bounds)
            } else {
                ann = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                ann.color = color
            }
            page.addAnnotation(ann)
            added.append((ann, page))
        }
        if !added.isEmpty { pushUndo(.added(added)) }
        pdfView.clearSelection()
    }

    func zoomIn() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(4.0, pdfView.scaleFactor * 1.25)
    }

    func zoomOut() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.1, pdfView.scaleFactor / 1.25)
    }

    func setZoom(_ scale: CGFloat) {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.1, min(4.0, scale))
    }

    func resetZoom() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit
    }
}

// MARK: - In-Page Text Box Editor

private class TextBoxEditor: NSView {
    let textView: NSTextView
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var mouseMonitor: Any?
    private var moveMonitor: Any?
    private var keyMonitor: Any?

    private enum DragMode { case none, resizeE, resizeS, resizeSE, move }
    private var dragMode: DragMode = .none
    private var dragStartScreen = CGPoint.zero
    private var dragStartFrame  = NSRect.zero

    private let kVis: CGFloat    = 18
    private let kHit: CGFloat    = 24
    private let kBorder: CGFloat = 10

    private let hSE = CATextLayer()
    private let hE  = CATextLayer()
    private let hS  = CATextLayer()

    init(frame: NSRect, font: NSFont, color: NSColor) {
        let tv = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
        tv.isEditable              = true
        tv.isSelectable            = true
        tv.isRichText              = false
        tv.drawsBackground         = false
        tv.font                    = font
        tv.textColor               = color
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask        = [.width, .height]
        tv.textContainerInset      = NSSize(width: 6, height: 6)
        self.textView = tv
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 3
        addSubview(tv)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for (l, sym) in [(hSE, "⤡"), (hE, "↔"), (hS, "↕")] {
            l.string = sym
            l.fontSize = 15
            l.alignmentMode = .center
            l.foregroundColor = NSColor.controlAccentColor.cgColor
            l.backgroundColor = CGColor.clear
            l.contentsScale = scale
            layer?.addSublayer(l)
        }
        repositionHandles()
        setupMonitors()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var seRect: NSRect { NSRect(x: bounds.maxX - kHit, y: bounds.maxY - kHit, width: kHit, height: kHit) }
    private var eRect:  NSRect { NSRect(x: bounds.maxX - kHit, y: kHit, width: kHit, height: bounds.height - 2*kHit) }
    private var sRect:  NSRect { NSRect(x: kHit, y: bounds.maxY - kHit, width: bounds.width - 2*kHit, height: kHit) }

    private func isBorder(_ pt: NSPoint) -> Bool {
        guard bounds.contains(pt) else { return false }
        let nearEdge = pt.x < kBorder || pt.x > bounds.maxX - kBorder ||
                       pt.y < kBorder || pt.y > bounds.maxY - kBorder
        return nearEdge && !seRect.contains(pt) && !eRect.contains(pt) && !sRect.contains(pt)
    }

    private func repositionHandles() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hSE.frame = CGRect(x: bounds.maxX - kVis, y: bounds.maxY - kVis, width: kVis, height: kVis)
        hE.frame  = CGRect(x: bounds.maxX - kVis, y: (bounds.height - kVis) / 2, width: kVis, height: kVis)
        hS.frame  = CGRect(x: (bounds.width - kVis) / 2, y: bounds.maxY - kVis, width: kVis, height: kVis)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        repositionHandles()
        textView.frame = bounds
    }

    private func setupMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouse(event) ?? event
        }

        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            let pt = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(pt) { self.updateCursor(at: pt) }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { self.cancel(); return nil }
            return event
        }
    }

    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        let pt = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            if !bounds.contains(pt) { commit(); return event }
            if seRect.contains(pt) {
                dragMode = .resizeSE
            } else if eRect.contains(pt) {
                dragMode = .resizeE
            } else if sRect.contains(pt) {
                dragMode = .resizeS
            } else if isBorder(pt) {
                dragMode = .move
            } else {
                dragMode = .none
                return event
            }
            dragStartScreen = NSEvent.mouseLocation
            dragStartFrame  = frame
            updateCursor(at: pt)
            return nil

        case .leftMouseDragged:
            guard dragMode != .none else { return event }
            let cur = NSEvent.mouseLocation
            let dx = cur.x - dragStartScreen.x
            let dy = cur.y - dragStartScreen.y
            var f = dragStartFrame
            switch dragMode {
            case .resizeE:  f.size.width  = max(80, f.size.width  + dx)
            case .resizeS:  f.size.height = max(40, f.size.height - dy)
            case .resizeSE: f.size.width  = max(80, f.size.width  + dx); f.size.height = max(40, f.size.height - dy)
            case .move:     f.origin.x += dx; f.origin.y += dy
            case .none: break
            }
            frame = f
            dragStartScreen = cur
            dragStartFrame  = frame
            return nil

        case .leftMouseUp:
            if dragMode != .none { dragMode = .none; return nil }
            return event

        default:
            return event
        }
    }

    private func updateCursor(at pt: NSPoint) {
        if seRect.contains(pt) { NSCursor.crosshair.set() }
        else if eRect.contains(pt) { NSCursor.resizeLeftRight.set() }
        else if sRect.contains(pt) { NSCursor.resizeUpDown.set() }
        else if isBorder(pt) { NSCursor.openHand.set() }
        else { NSCursor.iBeam.set() }
    }

    func commit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup(); onCommit?(text); removeFromSuperview()
    }

    func cancel() { cleanup(); onCancel?(); removeFromSuperview() }

    private func cleanup() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let m = moveMonitor  { NSEvent.removeMonitor(m); moveMonitor  = nil }
        if let m = keyMonitor   { NSEvent.removeMonitor(m); keyMonitor   = nil }
    }

    deinit { cleanup() }
}

// MARK: - Calculator

class CalculatorModel: ObservableObject {
    @Published var display = "0"
    @Published var expression = ""
    @Published var showingResult = false  // true after "=" — result on main, expression on mini

    private var accumulator: Double = 0
    private var pendingOp: String? = nil
    private var shouldReset = false
    private var lastWasOp = false
    private var lhsStr = ""

    func press(_ key: String) {
        switch key {
        case "0"..."9":
            if shouldReset || display == "0" { display = key; shouldReset = false }
            else if display.count < 10 { display += key }
            lastWasOp = false; showingResult = false; updateExpr()
        case ".":
            if shouldReset { display = "0"; shouldReset = false }
            if !display.contains(".") { display += "." }
            lastWasOp = false; showingResult = false; updateExpr()
        case "C":
            display = "0"; accumulator = 0; pendingOp = nil
            shouldReset = false; lastWasOp = false; lhsStr = ""; expression = ""; showingResult = false
        case "±":
            if let v = Double(display) { display = fmt(-v) }
            if pendingOp == nil { lhsStr = display }
            showingResult = false; updateExpr()
        case "%":
            if let v = Double(display) { display = fmt(v / 100) }
            if pendingOp == nil { lhsStr = display }
            showingResult = false; updateExpr()
        case "+", "−", "×", "÷":
            if let v = Double(display) {
                if let op = pendingOp, !lastWasOp {
                    accumulator = calc(accumulator, op, v)
                    display = fmt(accumulator)
                } else {
                    accumulator = v
                }
                lhsStr = display
            }
            pendingOp = key; shouldReset = true; lastWasOp = true; showingResult = false
            expression = "\(lhsStr) \(key) "
        case "=":
            if let op = pendingOp, let v = Double(display) {
                expression = "\(lhsStr) \(op) \(display) ="
                accumulator = calc(accumulator, op, v)
                display = fmt(accumulator)
                pendingOp = nil; shouldReset = true; lastWasOp = false; lhsStr = ""
                showingResult = true
            }
        default: break
        }
    }

    private func updateExpr() {
        if let op = pendingOp { expression = "\(lhsStr) \(op) \(display)" }
        else { expression = display == "0" ? "" : display }
    }

    private func calc(_ a: Double, _ op: String, _ b: Double) -> Double {
        switch op {
        case "+": return a + b
        case "−": return a - b
        case "×": return a * b
        case "÷": return b == 0 ? 0 : a / b
        default: return b
        }
    }

    private func fmt(_ v: Double) -> String {
        guard !v.isNaN, !v.isInfinite else { return "Error" }
        if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e10 { return String(Int64(v)) }
        return String(format: "%.6g", v)
    }
}

private struct CalcKey: View {
    let key: String
    let model: CalculatorModel
    var wide = false

    private var bg: Color {
        switch key {
        case "C", "±", "%": return Color(white: 0.45)
        case "÷", "×", "−", "+", "=": return .orange
        default: return Color(white: 0.28)
        }
    }

    var body: some View {
        Button { model.press(key) } label: {
            Text(key)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.white)
                .frame(maxWidth: wide ? .infinity : nil)
                .frame(width: wide ? nil : 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(bg)
        .frame(maxWidth: wide ? .infinity : 54)
    }
}

private struct CalculatorView: View {
    @ObservedObject var model: CalculatorModel

    private let rows: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"]
    ]

    var body: some View {
        VStack(spacing: 1) {
            VStack(spacing: 2) {
                // Mini display: shows expression after "=", empty otherwise
                HStack {
                    Spacer()
                    Text(model.showingResult ? model.expression : " ")
                        .font(.system(size: 13, weight: .light, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                // Main display: shows expression while building, result after "="
                HStack {
                    Spacer()
                    Text(model.showingResult ? model.display : (model.expression.isEmpty ? model.display : model.expression))
                        .font(model.showingResult
                            ? .system(size: 36, weight: .light, design: .monospaced)
                            : .system(size: 26, weight: .regular))
                        .foregroundColor(.white)
                        .lineLimit(1).minimumScaleFactor(0.25)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
            .background(Color(white: 0.1))

            ForEach(rows, id: \.self) { row in
                HStack(spacing: 1) {
                    ForEach(row, id: \.self) { key in CalcKey(key: key, model: model) }
                }
            }
            HStack(spacing: 1) {
                CalcKey(key: "0", model: model, wide: true)
                CalcKey(key: ".", model: model)
                CalcKey(key: "=", model: model)
            }
        }
        .background(Color(white: 0.15))
    }
}

class CalculatorPanel: ObservableObject {
    @Published var isVisible = false
    private var panel: NSPanel?
    private var keyMonitor: Any?
    let model = CalculatorModel()

    func toggle() {
        if let p = panel {
            if p.isVisible { hide() } else { show(p) }
        } else {
            let p = build(); panel = p; show(p)
        }
    }

    private func show(_ p: NSPanel) {
        p.makeKeyAndOrderFront(nil)
        isVisible = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak p] event in
            guard let self = self, p?.isKeyWindow == true else { return event }
            let ch = event.charactersIgnoringModifiers ?? ""
            switch ch {
            case "0"..."9", ".": self.model.press(ch)
            case "+":            self.model.press("+")
            case "-":            self.model.press("−")
            case "*":            self.model.press("×")
            case "/":            self.model.press("÷")
            case "=", "\r":      self.model.press("=")
            case "\u{7F}", "\u{1B}": self.model.press("C")
            default: return event
            }
            return nil
        }
    }

    private func hide() {
        panel?.orderOut(nil); isVisible = false
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func build() -> NSPanel {
        let w: CGFloat = 217, h: CGFloat = 360
        var origin = NSPoint(x: 800, y: 60)
        if let win = NSApp.mainWindow {
            origin = NSPoint(x: win.frame.maxX - w - 16, y: win.frame.minY + 16)
        }
        let p = NSPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        p.title = "Calculator"
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: CalculatorView(model: model).preferredColorScheme(.dark))
        p.contentView = hosting
        p.setContentSize(NSSize(width: w, height: h))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            self?.isVisible = false
            if let m = self?.keyMonitor { NSEvent.removeMonitor(m); self?.keyMonitor = nil }
        }
        return p
    }

    deinit { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
}

// MARK: - Root

struct DocEntry: Identifiable {
    let id = UUID()
    let doc: PDFDocument
    let title: String
    let quizModel = QuizModel()
    let host = PDFViewHost()
    let calcPanel = CalculatorPanel()
    var showQuiz = false
    var currentPage = 0
}

struct ContentView: View {
    @State private var docs: [DocEntry] = []
    @State private var activeIndex = 0
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            if docs.count > 1 {
                DocTabBar(docs: $docs, activeIndex: $activeIndex)
                Divider()
            }
            if docs.isEmpty {
                WelcomeView(onOpen: openFile)
            } else {
                PDFReaderView(
                    document: docs[activeIndex].doc,
                    host: docs[activeIndex].host,
                    quizModel: docs[activeIndex].quizModel,
                    calcPanel: docs[activeIndex].calcPanel,
                    showQuiz: Binding(
                        get: { docs[activeIndex].showQuiz },
                        set: { docs[activeIndex].showQuiz = $0 }
                    ),
                    currentPage: Binding(
                        get: { docs[activeIndex].currentPage },
                        set: { docs[activeIndex].currentPage = $0 }
                    ),
                    onSwitchTab: switchTab,
                    onCloseTab: closeCurrentTab
                )
                .id(docs[activeIndex].id)
            }
        }
        .onAppear {
            if docs.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { openFile() } }
            appDelegate.allHosts = { docs.map { $0.host } }
            appDelegate.closeCurrentTabAction = { closeCurrentTab() }
        }
        .onChange(of: docs.count) { _, _ in
            appDelegate.allHosts = { docs.map { $0.host } }
            appDelegate.closeCurrentTabAction = { closeCurrentTab() }
        }
        .navigationTitle(docs.isEmpty ? "Forms PDF Reader" : docs[activeIndex].title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Open…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let doc = PDFDocument(url: url) {
                    let title = url.deletingPathExtension().lastPathComponent
                    docs.append(DocEntry(doc: doc, title: title))
                }
            }
            if !docs.isEmpty { activeIndex = docs.count - 1 }
        }
    }

    func switchTab() {
        guard docs.count > 1 else { return }
        activeIndex = (activeIndex + 1) % docs.count
    }

    func closeCurrentTab() {
        guard !docs.isEmpty else { return }
        let currentHost = docs[activeIndex].host
        let title = docs[activeIndex].title
        if currentHost.hasUnsavedChanges || currentHost.hasUnsavedQuizData {
            let alert = NSAlert()
            alert.messageText = "Save \"\(title)\" before closing?"
            alert.informativeText = "Your annotations will be lost if you don't save."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn: currentHost.save()
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        docs.remove(at: activeIndex)
        activeIndex = docs.isEmpty ? 0 : min(activeIndex, docs.count - 1)
    }
}

struct DocTabBar: View {
    @Binding var docs: [DocEntry]
    @Binding var activeIndex: Int
    @State private var draggingIndex: Int? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(docs.indices, id: \.self) { i in
                    Button { activeIndex = i } label: {
                        Text(docs[i].title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == activeIndex ? Color.primary : Color.secondary)
                    .background(i == activeIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                    .opacity(draggingIndex == i ? 0.4 : 1.0)
                    .overlay(alignment: .bottom) {
                        if i == activeIndex {
                            Rectangle().frame(height: 2).foregroundStyle(Color.accentColor)
                        }
                    }
                    .onDrag {
                        draggingIndex = i
                        return NSItemProvider(object: "\(i)" as NSString)
                    }
                    .onDrop(of: [.plainText], delegate: TabDropDelegate(
                        docs: $docs,
                        activeIndex: $activeIndex,
                        draggingIndex: $draggingIndex,
                        dropIndex: i
                    ))
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(height: 32)
    }
}

struct TabDropDelegate: DropDelegate {
    @Binding var docs: [DocEntry]
    @Binding var activeIndex: Int
    @Binding var draggingIndex: Int?
    let dropIndex: Int

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let from = draggingIndex, from != dropIndex else {
            draggingIndex = nil
            return false
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            let item = docs.remove(at: from)
            docs.insert(item, at: dropIndex)
            if activeIndex == from {
                activeIndex = dropIndex
            } else if from < activeIndex && dropIndex >= activeIndex {
                activeIndex -= 1
            } else if from > activeIndex && dropIndex <= activeIndex {
                activeIndex += 1
            }
        }
        draggingIndex = nil
        return true
    }
}

// MARK: - PDF Viewer

struct PDFReaderView: View {
    let document: PDFDocument
    @ObservedObject var host: PDFViewHost
    @ObservedObject var quizModel: QuizModel
    @ObservedObject var calcPanel: CalculatorPanel
    @Binding var showQuiz: Bool
    @Binding var currentPage: Int
    let onSwitchTab: () -> Void
    let onCloseTab: () -> Void
    @State private var totalPages: Int
    @State private var keyMonitor: Any?
    @State private var showColorPicker = false
    @State private var savedFeedback = false
    @State private var findQuery = ""
    @State private var showLabValues = false
    @State private var quizDataRestored = false
    @EnvironmentObject var appDelegate: AppDelegate

    init(document: PDFDocument, host: PDFViewHost, quizModel: QuizModel, calcPanel: CalculatorPanel, showQuiz: Binding<Bool>, currentPage: Binding<Int>, onSwitchTab: @escaping () -> Void = {}, onCloseTab: @escaping () -> Void = {}) {
        self.document = document
        self.host = host
        self.quizModel = quizModel
        self.calcPanel = calcPanel
        self._showQuiz = showQuiz
        self._currentPage = currentPage
        self.onSwitchTab = onSwitchTab
        self.onCloseTab = onCloseTab
        _totalPages = State(initialValue: document.pageCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowCloseInterceptor(getAllHosts: appDelegate.allHosts).frame(width: 0, height: 0)
            HStack(spacing: 0) {
                PDFKitRepresentable(document: document, currentPage: $currentPage, host: host)
                if showLabValues {
                    Divider()
                    LabValuesPanel()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showLabValues)

            Divider()

            HStack(spacing: 10) {
                // Page navigation
                Button { currentPage -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(currentPage == 0)

                PageTextField(currentPage: $currentPage, totalPages: totalPages)

                Button { currentPage += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(currentPage >= totalPages - 1)

                Divider().frame(height: 20)

                // Tool buttons
                toolButton(.cursor)
                toolButton(.highlight)
                toolButton(.strikethrough)

                // Text box button
                Button {
                    host.textBoxMode.toggle()
                } label: {
                    Image(systemName: "text.cursor")
                }
                .buttonStyle(.bordered)
                .foregroundStyle(host.textBoxMode ? Color.accentColor : Color.primary)
                .background(
                    host.textBoxMode ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .help("Text Box")

                // Font controls — visible in text box mode or when a text box is selected
                if host.textBoxMode || host.selectedAnnotation != nil {
                    Divider().frame(height: 20)

                    HStack(spacing: 3) {
                        Text("Size").font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("", value: $host.textBoxFontSize, formatter: {
                            let f = NumberFormatter()
                            f.minimum = 6; f.maximum = 144
                            return f
                        }())
                        .frame(width: 36)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12))
                        .onChange(of: host.textBoxFontSize) { _, size in
                            host.selectedAnnotation?.font = NSFont.systemFont(ofSize: size)
                        }
                    }

                    ColorPicker("", selection: $host.textBoxFontColor)
                        .frame(width: 28)
                        .help("Text color")
                        .onChange(of: host.textBoxFontColor) { _, color in
                            host.selectedAnnotation?.fontColor = NSColor(color)
                        }
                }

                if host.activeTool == .highlight {
                    Button { showColorPicker.toggle() } label: {
                        Circle()
                            .fill(host.highlightColor)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .help("Highlight color")
                    .transition(.scale.combined(with: .opacity))
                    .popover(isPresented: $showColorPicker) {
                        ColorPicker("Highlight Color", selection: $host.highlightColor)
                            .padding(16)
                    }
                }

                Button { host.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!host.canUndo)
                    .help("Undo (⌘Z)")

                Button { host.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!host.canRedo)
                    .help("Redo (⌘⇧Z)")

                Spacer()

                Button { showQuiz.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checklist")
                        Text("Track my answers").font(.system(size: 12))
                    }
                }
                .foregroundStyle(showQuiz ? Color.accentColor : Color.primary)
                .help("Quiz Checker")

                Divider().frame(height: 20)

                // Zoom
                Button { host.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)

                ZoomTextField(host: host)

                Button { host.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)

                Button { host.resetZoom() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Fit page (⌘0)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            .animation(.easeInOut(duration: 0.25), value: savedFeedback)

            if showQuiz {
                Divider()
                QuizPanel(model: quizModel, currentPage: $currentPage, totalPages: totalPages)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showQuiz)
        .animation(.easeInOut(duration: 0.15), value: host.activeTool == .highlight)
        .onChange(of: host.hasUnsavedChanges) { _, newValue in
            NSApp.keyWindow?.isDocumentEdited = newValue
        }
        .onChange(of: quizModel.results.count) { _, _ in
            if quizModel.phase != .modeSelect { host.hasUnsavedQuizData = true }
        }
        .onChange(of: quizModel.notes) { _, _ in
            if quizModel.phase != .modeSelect { host.hasUnsavedQuizData = true }
        }
        .onChange(of: quizModel.flags) { _, _ in
            if quizModel.phase != .modeSelect { host.hasUnsavedQuizData = true }
        }
        .onChange(of: quizModel.phase) { _, newPhase in
            if newPhase == .modeSelect { host.hasUnsavedQuizData = false }
            else if newPhase != .modeSelect { host.hasUnsavedQuizData = true }
        }
        .onAppear {
            host.quizModel = quizModel
            if !quizDataRestored {
                quizDataRestored = true
                if let json = extractQuizJSON(from: document) {
                    quizModel.restore(from: json)
                }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Pass all keys through while a text box editor is open
                if host.textEditorActive { return event }

                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let noMods = mods.isEmpty
                let cmdOnly = mods == .command

                // Spacebar switches tabs — but not when a text field is focused
                if noMods, event.charactersIgnoringModifiers == " ",
                   !(NSApp.keyWindow?.firstResponder is NSText) {
                    onSwitchTab(); return nil
                }
                // Escape clears search bar
                if noMods, event.keyCode == 53, !findQuery.isEmpty {
                    findQuery = ""; host.clearFind(); return nil
                }
                // Cmd+F — focus the search bar in toolbar
                if cmdOnly, event.charactersIgnoringModifiers == "f" {
                    host.focusSearch?(); return nil
                }
                // Cmd+W — close current tab
                if cmdOnly, event.charactersIgnoringModifiers == "w" {
                    onCloseTab(); return nil
                }
                // Delete/Backspace removes a selected text box annotation
                if noMods, (event.keyCode == 51 || event.keyCode == 117),
                   !(NSApp.keyWindow?.firstResponder is NSText),
                   host.selectedAnnotation != nil {
                    host.deleteSelectedAnnotation(); return nil
                }
                // Arrow keys from quiz input → page navigation (left/up = prev, right/down = next)
                if noMods, quizModel.inputFocused {
                    let kc = event.keyCode
                    if kc == 123 || kc == 126 { currentPage = max(0, currentPage - 1); return nil }
                    if kc == 124 || kc == 125 { currentPage = min(totalPages - 1, currentPage + 1); return nil }
                }
                let textIsFocused = (NSApp.keyWindow?.firstResponder is NSText) || quizModel.inputFocused
                guard noMods, !textIsFocused else { return event }
                // Arrow keys — page navigation (blocked when any other text field is focused)
                if event.keyCode == 123 { currentPage = max(0, currentPage - 1); return nil }
                if event.keyCode == 124 { currentPage = min(totalPages - 1, currentPage + 1); return nil }
                let key = event.charactersIgnoringModifiers ?? ""
                guard !key.isEmpty else { return event }
                let sc = ShortcutStore.shared
                if !sc.cursor.isEmpty        && key == sc.cursor        { host.activeTool = .cursor;        host.textBoxMode = false; return nil }
                if !sc.highlight.isEmpty     && key == sc.highlight     { host.activeTool = .highlight;     host.textBoxMode = false; return nil }
                if !sc.strikethrough.isEmpty && key == sc.strikethrough { host.activeTool = .strikethrough; host.textBoxMode = false; return nil }
                if !sc.textBox.isEmpty       && key == sc.textBox       { host.textBoxMode.toggle(); return nil }
                if !sc.switchTab.isEmpty     && key == sc.switchTab     { onSwitchTab(); return nil }
                if !sc.openQuiz.isEmpty      && key == sc.openQuiz      { showQuiz.toggle(); return nil }
                return event
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    saveWithFeedback()
                } label: {
                    if savedFeedback {
                        Label("Saved", systemImage: "checkmark")
                            .foregroundStyle(Color.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!host.hasUnsavedChanges && !host.hasUnsavedQuizData && !savedFeedback)
                .help("Save (⌘S)")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    calcPanel.toggle()
                } label: {
                    Label("Calculator", systemImage: "minus.forwardslash.plus")
                        .labelStyle(.titleAndIcon)
                }
                .foregroundStyle(calcPanel.isVisible ? Color.accentColor : Color.primary)
                .help("Calculator")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showLabValues.toggle()
                } label: {
                    Label("NBME Lab Values", systemImage: "testtube.2")
                        .labelStyle(.titleAndIcon)
                }
                .foregroundStyle(showLabValues ? Color.accentColor : Color.primary)
                .help("NBME Lab Values reference")
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    ToolbarSearchField(text: $findQuery, host: host)
                        .frame(minWidth: 160, maxWidth: 240)
                    if !findQuery.isEmpty {
                        if host.isFinding {
                            ProgressView().scaleEffect(0.55).frame(width: 14, height: 14)
                        } else if host.findResults.isEmpty {
                            Text("No results").font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text("\(host.findIndex + 1)/\(host.findResults.count)")
                                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Button { host.findPrev() } label: {
                            Image(systemName: "chevron.up").font(.system(size: 10))
                        }
                        .disabled(host.findResults.isEmpty)
                        Button { host.findNext() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 10))
                        }
                        .disabled(host.findResults.isEmpty)
                    }
                }
            }
        }
    }

    private func saveWithFeedback() {
        host.save()
        savedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedFeedback = false }
    }

    @ViewBuilder
    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isActive = host.activeTool == tool && !host.textBoxMode
        Button {
            host.activeTool = tool
            host.textBoxMode = false
        } label: {
            Image(systemName: tool.icon)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .background(
            isActive ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .help(tool.label)
    }
}

// MARK: - Editable Zoom Field

struct ZoomTextField: View {
    @ObservedObject var host: PDFViewHost
    @State private var text = "100"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 1) {
            TextField("", text: $text)
                .frame(width: 36)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { DispatchQueue.main.async { commit() } }
                }
            Text("%").foregroundStyle(.secondary)
        }
        .onChange(of: host.currentScale) { _, scale in
            if !focused { text = "\(Int(scale * 100))" }
        }
        .onAppear {
            text = "\(Int(host.currentScale * 100))"
        }
    }

    private func commit() {
        if let val = Double(text), val >= 10, val <= 800 {
            host.setZoom(CGFloat(val) / 100.0)
        }
        DispatchQueue.main.async { text = "\(Int(host.currentScale * 100))" }
    }
}

// MARK: - Page Number Field

struct PageTextField: View {
    @Binding var currentPage: Int
    let totalPages: Int
    @State private var text = "1"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("Page").foregroundStyle(.secondary)
            TextField("", text: $text)
                .frame(width: 36)
                .multilineTextAlignment(.center)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { DispatchQueue.main.async { commit() } }
                }
            Text("of \(totalPages)").foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .onChange(of: currentPage) { _, page in
            if !focused { text = "\(page + 1)" }
        }
        .onAppear { text = "\(currentPage + 1)" }
    }

    private func commit() {
        if let val = Int(text), val >= 1, val <= totalPages {
            currentPage = val - 1
        }
        DispatchQueue.main.async { text = "\(currentPage + 1)" }
    }
}

// MARK: - PDFKit Bridge

struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    let host: PDFViewHost

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AnnotatingPDFView {
        let pdfView = AnnotatingPDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .darkGray
        host.attach(pdfView)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        // Set document after observer is registered so we can suppress
        // the initial page-0 notification and restore the saved page instead.
        context.coordinator.suppressNextPageChange = true
        pdfView.document = document
        if let page = document.page(at: currentPage) { pdfView.go(to: page) }
        return pdfView
    }

    func updateNSView(_ pdfView: AnnotatingPDFView, context: Context) {
        if pdfView.document !== document {
            context.coordinator.suppressNextPageChange = true
            pdfView.document = document
            if let page = document.page(at: currentPage) { pdfView.go(to: page) }
            return
        }
        guard !context.coordinator.pageChangedByScroll else { return }
        if let page = document.page(at: currentPage), pdfView.currentPage !== page {
            pdfView.go(to: page)
        }
    }

    class Coordinator: NSObject {
        var parent: PDFKitRepresentable
        var pageChangedByScroll = false
        var suppressNextPageChange = false

        init(_ parent: PDFKitRepresentable) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func pageChanged(_ notification: Notification) {
            if suppressNextPageChange { suppressNextPageChange = false; return }
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage else { return }
            let index = parent.document.index(for: page)
            pageChangedByScroll = true
            DispatchQueue.main.async {
                self.parent.currentPage = index
                DispatchQueue.main.async { self.pageChangedByScroll = false }
            }
        }
    }
}

// MARK: - Welcome Screen

struct WelcomeView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "doc.richtext")
                .font(.system(size: 72))
                .foregroundColor(.secondary)
            Text("Forms PDF Reader")
                .font(.largeTitle).fontWeight(.semibold)
            Text("Open a PDF file to get started")
                .foregroundColor(.secondary)
            Button("Open PDF…", action: onOpen)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        // Invisible buttons so Space and Return also trigger open
        .background(
            Group {
                Button("", action: onOpen).keyboardShortcut(" ", modifiers: [])
                Button("", action: onOpen).keyboardShortcut(.return, modifiers: [])
            }
            .frame(width: 0, height: 0).opacity(0)
        )
    }
}

// MARK: - Find Bar

struct FindBar: View {
    @ObservedObject var host: PDFViewHost
    @Binding var query: String
    @Binding var isVisible: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))

            TextField("Find in PDF…", text: $query)
                .frame(width: 200)
                .focused($focused)
                .onSubmit { host.findNext() }
                .onChange(of: query) { _, newVal in host.search(newVal) }

            if host.isFinding {
                ProgressView().scaleEffect(0.6).frame(width: 18, height: 18)
            } else if !query.isEmpty {
                if host.findResults.isEmpty {
                    Text("No results").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("\(host.findIndex + 1) of \(host.findResults.count)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            Button { host.findPrev() } label: { Image(systemName: "chevron.up") }
                .disabled(host.findResults.isEmpty).help("Previous (⌘↑)")

            Button { host.findNext() } label: { Image(systemName: "chevron.down") }
                .disabled(host.findResults.isEmpty).help("Next (⌘↓)")

            Spacer()

            Button {
                isVisible = false; host.clearFind(); query = ""
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain).help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { focused = true }
    }
}

// Toolbar search field — uses NSSearchField directly so makeFirstResponder works reliably
private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var host: PDFViewHost

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Search this PDF..."
        f.delegate = context.coordinator
        f.sendsSearchStringImmediately = true
        f.sendsWholeSearchString = false
        host.focusSearch = { [weak f] in
            DispatchQueue.main.async { f?.window?.makeFirstResponder(f) }
        }
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        init(_ p: ToolbarSearchField) { self.parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSSearchField else { return }
            parent.text = f.stringValue
            if f.stringValue.isEmpty { parent.host.clearFind() }
            else { parent.host.search(f.stringValue) }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.host.findNext(); return true }
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                parent.text = ""; parent.host.clearFind()
                control.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
}

// MARK: - Quiz Checker

fileprivate extension Color {
    static let qBg      = Color(red: 0.051, green: 0.067, blue: 0.090)
    static let qSurface = Color(red: 0.086, green: 0.106, blue: 0.133)
    static let qCard    = Color(red: 0.118, green: 0.141, blue: 0.188)
    static let qBorder  = Color(red: 0.165, green: 0.188, blue: 0.251)
    static let qAccent  = Color(red: 0.290, green: 0.498, blue: 0.831)
    static let qGreen   = Color(red: 0.180, green: 0.659, blue: 0.290)
    static let qRed     = Color(red: 0.788, green: 0.255, blue: 0.290)
    static let qYellow  = Color(red: 0.722, green: 0.525, blue: 0.043)
    static let qText    = Color(red: 0.788, green: 0.820, blue: 0.851)
    static let qSubtext = Color(red: 0.345, green: 0.376, blue: 0.412)
}

// MARK: - Quiz PDF persistence

private let kQuizAnnotationAuthor = "__QuizCheckerData__"

private func embedQuizData(_ model: QuizModel, in doc: PDFDocument) {
    guard let page = doc.page(at: 0) else { return }
    // Remove any existing quiz annotation
    page.annotations.filter { $0.userName == kQuizAnnotationAuthor }.forEach { page.removeAnnotation($0) }
    // If quiz is at the start screen, nothing to save
    guard model.phase != .modeSelect else { return }
    guard let json = model.toJSON() else { return }
    let ann = PDFAnnotation(bounds: CGRect(x: -9999, y: -9999, width: 1, height: 1), forType: .text, withProperties: nil)
    ann.userName = kQuizAnnotationAuthor
    ann.contents = json
    ann.color = .clear
    page.addAnnotation(ann)
}

private func extractQuizJSON(from doc: PDFDocument) -> String? {
    doc.page(at: 0)?.annotations.first { $0.userName == kQuizAnnotationAuthor }?.contents
}

enum QuizPhase { case modeSelect, setup, active, summary }

struct QuizEntry: Identifiable {
    let id = UUID()
    let number: Int
    let given: Character
    let correct: Character
    var ok: Bool { given == correct }
}

class QuizModel: ObservableObject {
    @Published var phase: QuizPhase = .modeSelect
    @Published private(set) var key: [Character] = []
    @Published private(set) var results: [QuizEntry] = []
    @Published private(set) var current: Int = 0
    @Published var lastFeedbackText = ""
    @Published var lastFeedbackCorrect: Bool? = nil
    @Published var notes: [String] = Array(repeating: "", count: ShortcutStore.shared.questionCount)
    @Published var revealFeedback = true   // show ✓/✗ after each answer
    @Published var revealScore = true      // show running score while answering
    @Published var inputFocused = false    // tracks when quiz answer field is focused
    @Published var trackingOnly = false    // tracking without answer key
    @Published var flags: Set<Int> = []    // 0-based question indices

    var targetCount: Int { ShortcutStore.shared.questionCount }
    var score: Int { results.filter(\.ok).count }
    var total: Int { results.count }
    var pct: Double { total == 0 ? 0 : Double(score) / Double(total) * 100 }
    var scoreColor: Color { pct >= 70 ? .qGreen : pct >= 50 ? .qYellow : .qRed }

    func start(keyLetters: [Character], doneLetters: [Character]) {
        key = keyLetters
        results = doneLetters.enumerated().map {
            QuizEntry(number: $0.offset + 1, given: $0.element, correct: keyLetters[$0.offset])
        }
        current = doneLetters.count
        if let last = results.last {
            lastFeedbackText = last.ok
                ? "✓  correct   \(score)/\(total)  \(String(format: "%.1f", pct))%"
                : "✗   \(score)/\(total)  \(String(format: "%.1f", pct))%"
            lastFeedbackCorrect = last.ok
        }
        phase = current >= targetCount ? .summary : .active
    }

    func startTracking() {
        key = Array(repeating: "?", count: targetCount)
        trackingOnly = true
        results = []; current = 0
        lastFeedbackText = ""; lastFeedbackCorrect = nil
        notes = Array(repeating: "", count: targetCount)
        phase = .active
    }

    func addKey(_ keyLetters: [Character]) {
        guard keyLetters.count == targetCount else { return }
        key = keyLetters
        trackingOnly = false
        results = results.map { QuizEntry(number: $0.number, given: $0.given, correct: keyLetters[$0.number - 1]) }
    }

    func submit(_ c: Character) {
        guard current < targetCount else { return }
        let correctChar: Character = trackingOnly ? "?" : key[current]
        results.append(QuizEntry(number: current + 1, given: c, correct: correctChar))
        current += 1
        if !trackingOnly, let last = results.last {
            lastFeedbackText = last.ok
                ? "✓  correct   \(score)/\(total)  \(String(format: "%.1f", pct))%"
                : "✗   \(score)/\(total)  \(String(format: "%.1f", pct))%"
            lastFeedbackCorrect = last.ok
        }
        if current >= targetCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.phase = .summary }
        }
    }

    func undo() {
        guard !results.isEmpty, phase == .active || phase == .summary else { return }
        if phase == .summary { phase = .active }
        results.removeLast()
        current -= 1
        if !results.isEmpty {
            lastFeedbackText = "undone — Q\(current + 1)"
            lastFeedbackCorrect = nil
        } else {
            lastFeedbackText = ""
            lastFeedbackCorrect = nil
        }
    }

    func changeAnswer(_ index: Int, to c: Character) {
        guard index < results.count else { return }
        let correctChar: Character = trackingOnly ? results[index].correct : key[index]
        results[index] = QuizEntry(number: index + 1, given: c, correct: correctChar)
        if !trackingOnly {
            lastFeedbackText = results[index].ok
                ? "✓  correct   \(score)/\(total)  \(String(format: "%.1f", pct))%"
                : "✗   \(score)/\(total)  \(String(format: "%.1f", pct))%"
            lastFeedbackCorrect = results[index].ok
        }
    }

    func fillAndSubmit(_ idx: Int, _ c: Character) {
        guard idx < targetCount, idx >= current else { return }
        while current < idx {
            let correctChar: Character = trackingOnly ? "?" : key[current]
            results.append(QuizEntry(number: current + 1, given: "?", correct: correctChar))
            current += 1
        }
        submit(c)
    }

    func toggleFlag(_ q: Int) {
        if flags.contains(q) { flags.remove(q) } else { flags.insert(q) }
    }

    func newQuiz() { key = []; results = []; current = 0; trackingOnly = false; phase = .modeSelect; lastFeedbackText = ""; lastFeedbackCorrect = nil; notes = Array(repeating: "", count: targetCount); flags = [] }
    func retry()   { results = []; current = 0; phase = .active; lastFeedbackText = ""; lastFeedbackCorrect = nil
        if trackingOnly { key = Array(repeating: "?", count: targetCount) }
    }

    func sheetsText() -> String {
        let hasNotes = notes.prefix(results.count).contains { !$0.isEmpty }
        return results.enumerated().map { i, e in
            if trackingOnly {
                return hasNotes ? "\(String(e.given))\t\t\(notes[i])" : String(e.given)
            } else {
                return hasNotes ? "\(String(e.given))\t\(String(e.correct))\t\(notes[i])" : "\(String(e.given))\t\(String(e.correct))"
            }
        }.joined(separator: "\n")
    }

    func toJSON() -> String? {
        let phaseStr: String
        switch phase {
        case .modeSelect: phaseStr = "modeSelect"
        case .setup:      phaseStr = "setup"
        case .active:     phaseStr = "active"
        case .summary:    phaseStr = "summary"
        }
        var dict: [String: Any] = [
            "phase":         phaseStr,
            "key":           String(key),
            "results":       results.map { ["n": $0.number, "g": String($0.given), "c": String($0.correct)] },
            "current":       current,
            "notes":         notes,
            "trackingOnly":  trackingOnly,
            "revealFeedback": revealFeedback,
            "revealScore":   revealScore,
            "lastFeedbackText": lastFeedbackText,
            "flags":         Array(flags)
        ]
        if let lfc = lastFeedbackCorrect { dict["lastFeedbackCorrect"] = lfc }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    func restore(from json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let ks = dict["key"] as? String { key = Array(ks) }
        if let arr = dict["results"] as? [[String: Any]] {
            results = arr.compactMap { r in
                guard let n  = r["n"] as? Int,
                      let gs = r["g"] as? String, let g = gs.first,
                      let cs = r["c"] as? String, let c = cs.first else { return nil }
                return QuizEntry(number: n, given: g, correct: c)
            }
        }
        if let c  = dict["current"]       as? Int    { current       = c  }
        if let n  = dict["notes"]         as? [String] { notes       = n  }
        if let t  = dict["trackingOnly"]  as? Bool   { trackingOnly  = t  }
        if let rf = dict["revealFeedback"] as? Bool  { revealFeedback = rf }
        if let rs = dict["revealScore"]   as? Bool   { revealScore   = rs }
        if let ft = dict["lastFeedbackText"] as? String { lastFeedbackText = ft }
        lastFeedbackCorrect = dict["lastFeedbackCorrect"] as? Bool
        if let fl = dict["flags"] as? [Int] { flags = Set(fl) }

        switch dict["phase"] as? String {
        case "active":  phase = .active
        case "summary": phase = .summary
        case "setup":   phase = .setup
        default:        phase = .modeSelect
        }
    }
}

struct QuizPanel: View {
    @ObservedObject var model: QuizModel
    @Binding var currentPage: Int
    let totalPages: Int
    @State private var showLog   = false
    @State private var showNotes = false
    @State private var notesAllView = false  // false = current Q, true = all Qs

    var body: some View {
        Group {
            switch model.phase {
            case .modeSelect: QuizModeSelectView().environmentObject(model)
            case .setup:      QuizSetupView().environmentObject(model)
            case .active:     QuizActiveView(showLog: $showLog, showNotes: $showNotes, notesAllView: $notesAllView, currentPage: $currentPage, totalPages: totalPages).environmentObject(model)
            case .summary:    QuizSummaryView(showLog: $showLog, showNotes: $showNotes, notesAllView: $notesAllView).environmentObject(model)
            }
        }
        .background(Color.qBg)
        .preferredColorScheme(.dark)
    }
}

// MARK: Setup

struct QuizModeSelectView: View {
    @EnvironmentObject var model: QuizModel

    var body: some View {
        HStack(spacing: 10) {
            modeCard(
                title: "With answer key",
                subtitle: "Check answers as you go and see your score"
            ) { model.phase = .setup }

            modeCard(
                title: "Without answer key",
                subtitle: "Log what you answered — add a key later if you want"
            ) { model.startTracking() }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder private func modeCard(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .bold)).foregroundColor(.qText)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.qSubtext)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.qSurface)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.qBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct QuizSetupView: View {
    @EnvironmentObject var model: QuizModel
    @State private var keyText  = ""
    @State private var doneText = ""

    private var keyLetters:  [Character] { Array(keyText.uppercased().filter  { $0.isLetter }) }
    private var doneLetters: [Character] { Array(doneText.uppercased().filter { $0.isLetter }) }
    private var ready: Bool { keyLetters.count == model.targetCount && doneLetters.count <= model.targetCount }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Back arrow
            Button { model.phase = .modeSelect } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                    .foregroundColor(.qSubtext)
            }
            .buttonStyle(.plain)
            .padding(.top, 22)

            // Answer key
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Answer key").font(.system(size: 11)).foregroundColor(.qSubtext)
                    Spacer()
                    Text("\(keyLetters.count)/\(model.targetCount)").font(.system(size: 11))
                        .foregroundColor(keyLetters.count == model.targetCount ? .qGreen : .qSubtext)
                }
                qTextArea($keyText)
            }

            // Already done
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Already done (opt.)").font(.system(size: 11)).foregroundColor(.qSubtext)
                    Spacer()
                    let n = doneLetters.count
                    let tgt = model.targetCount
                    Text(n > tgt ? "max \(tgt)" : n == 0 ? "→Q1" : "→Q\(n+1)").font(.system(size: 11))
                        .foregroundColor(n > tgt ? .qRed : .qSubtext)
                }
                qTextArea($doneText)
            }

            // Start
            VStack {
                Spacer()
                Button { model.start(keyLetters: keyLetters, doneLetters: doneLetters) } label: {
                    Text("Start →")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(ready ? Color(red: 0.54, green: 0.67, blue: 0.86) : .qSubtext)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(ready ? Color(red: 0.165, green: 0.247, blue: 0.373) : Color.qBorder)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain).disabled(!ready)
            }
            .frame(height: 68)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private func qTextArea(_ b: Binding<String>) -> some View {
        TextEditor(text: b)
            .font(.system(size: 12, design: .monospaced)).foregroundColor(.qText)
            .scrollContentBackground(.hidden).background(Color.qSurface)
            .frame(height: 52)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.qBorder, lineWidth: 1))
    }
}

// MARK: Active

struct QuizActiveView: View {
    @EnvironmentObject var model: QuizModel
    @Binding var showLog: Bool
    @Binding var showNotes: Bool
    @Binding var notesAllView: Bool
    @Binding var currentPage: Int
    let totalPages: Int
    @State private var input = ""

    // When PDF pages == question count, the quiz follows the scroll position
    private var synced: Bool { totalPages == model.targetCount }
    private var viewingQ: Int { synced ? currentPage : model.current }
    private var viewingQAnswered: Bool { viewingQ < model.current }
    private var viewingQFuture: Bool { synced && viewingQ > model.current }
    @State private var feedbackText  = ""
    @State private var feedbackColor: Color = .qSubtext
    @State private var lastSubmitted: Character? = nil
    @State private var lastCorrect: Character? = nil
    @State private var copied = false
    @State private var showAddKey = false
    @State private var addKeyText = ""
    @State private var showRestartConfirm = false
    @FocusState private var focused: Bool

    @ViewBuilder private var restartButton: some View {
        Button { showRestartConfirm = true } label: {
            Text("restart").font(.system(size: 14, weight: .bold)).foregroundColor(.qSubtext)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showRestartConfirm, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("start a new quiz?")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.qText)
                Text("all answers and notes will be cleared.")
                    .font(.system(size: 11)).foregroundColor(.qSubtext)
                HStack(spacing: 12) {
                    Button("cancel") { showRestartConfirm = false }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.qSubtext)
                    Button("restart") { model.newQuiz(); showRestartConfirm = false }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .bold))
                        .foregroundColor(.qRed)
                }
            }
            .padding(14).background(Color.qBg).preferredColorScheme(.dark)
        }
    }

    private func feedbackColorFor(_ correct: Bool?) -> Color {
        guard let c = correct else { return .qSubtext }
        return c ? .qGreen : .qRed
    }

    private var visibleFeedback: String {
        if model.trackingOnly { return " " }
        guard !feedbackText.isEmpty else { return " " }
        if !model.revealFeedback && !model.revealScore { return " " }
        if !model.revealFeedback {
            let parts = feedbackText.components(separatedBy: "   ")
            return parts.dropFirst().joined(separator: "   ").trimmingCharacters(in: .whitespaces)
        }
        if !model.revealScore {
            return feedbackText.components(separatedBy: "   ").first ?? feedbackText
        }
        return feedbackText
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // ── Left cluster ──────────────────────────────────────────
                HStack(spacing: 10) {
                    Text("Q\(viewingQ + 1)/\(model.targetCount)")
                        .font(.system(size: 18, weight: .bold)).foregroundColor(.qText)

                    let isFlagged = model.flags.contains(viewingQ)
                    Button {
                        model.toggleFlag(viewingQ)
                    } label: {
                        Image(systemName: isFlagged ? "flag.fill" : "flag")
                            .font(.system(size: 12))
                            .foregroundColor(isFlagged ? .orange : .qSubtext)
                    }
                    .buttonStyle(.plain)
                    .help(isFlagged ? "Unflag Q\(viewingQ + 1)" : "Flag Q\(viewingQ + 1)")

                    TextField("", text: $input)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(viewingQAnswered ? .qAccent : .qText).multilineTextAlignment(.center)
                        .frame(width: 40).padding(.vertical, 5)
                        .background(Color.qSurface)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(viewingQAnswered ? Color.qAccent.opacity(0.5) : Color.qBorder, lineWidth: 1))
                        .focused($focused)
                        .onChange(of: focused) { _, val in model.inputFocused = val }
                        .onChange(of: input) { _, val in
                            if let c = val.uppercased().last(where: { $0.isLetter }) { submitAnswer(c) }
                            else if !val.isEmpty { input = "" }
                        }

                    Text(visibleFeedback)
                        .font(.system(size: 14, weight: .bold)).foregroundColor(feedbackColor)

                    Button("undo") {
                        model.undo()
                        feedbackText = model.lastFeedbackText
                        feedbackColor = feedbackColorFor(model.lastFeedbackCorrect)
                        lastSubmitted = nil; lastCorrect = nil
                    }
                    .keyboardShortcut("u", modifiers: .command)
                    .buttonStyle(.plain).font(.system(size: 14, weight: .bold))
                    .foregroundColor(model.results.isEmpty ? Color.qSubtext.opacity(0.3) : .qSubtext)
                    .disabled(model.results.isEmpty)

                    // copy moved to right cluster

                    if model.trackingOnly {
                        let addKeyLetters = Array(addKeyText.uppercased().filter { $0.isLetter })
                        Button { showAddKey.toggle() } label: {
                            Text("add key").font(.system(size: 14, weight: .bold)).foregroundColor(.qAccent)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showAddKey, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("answer key").font(.system(size: 11)).foregroundColor(.qSubtext)
                                    Spacer()
                                    Text("\(addKeyLetters.count)/\(model.targetCount)").font(.system(size: 11))
                                        .foregroundColor(addKeyLetters.count == model.targetCount ? .qGreen : .qSubtext)
                                }
                                TextEditor(text: $addKeyText)
                                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.qText)
                                    .scrollContentBackground(.hidden).background(Color.qSurface)
                                    .frame(width: 200, height: 52)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.qBorder, lineWidth: 1))
                                Button {
                                    model.addKey(addKeyLetters); showAddKey = false; addKeyText = ""
                                } label: {
                                    Text("apply key →")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(addKeyLetters.count == model.targetCount ? Color(red: 0.54, green: 0.67, blue: 0.86) : .qSubtext)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(addKeyLetters.count == model.targetCount ? Color(red: 0.165, green: 0.247, blue: 0.373) : Color.qBorder)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain).disabled(addKeyLetters.count != model.targetCount)
                            }
                            .padding(12).background(Color.qBg).preferredColorScheme(.dark)
                        }
                        restartButton
                    } else {
                        restartButton
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showLog.toggle(); showNotes = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("log/notes").font(.system(size: 14, weight: .bold))
                                .foregroundColor(showLog ? .qAccent : .qSubtext)
                            Image(systemName: showLog ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(showLog ? .qAccent : .qSubtext)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // ── Center: submitted letter display ──────────────────────
                if let letter = lastSubmitted {
                    let centerActive = !model.trackingOnly && model.revealFeedback
                    let showWrongAnswer = centerActive && feedbackColor == .qRed
                    let centerText: String = {
                        var s = "Q\(model.current): you entered \(String(letter))"
                        if showWrongAnswer, let correct = lastCorrect {
                            s += " (answer = \(String(correct)))"
                        }
                        return s
                    }()
                    Text(centerText)
                        .font(.system(size: model.revealFeedback ? 16 : 17, weight: .bold))
                        .foregroundColor(centerActive ? feedbackColor : .qText)
                        .lineLimit(1)
                }

                // ── Right cluster: copy + reveal toggles ─────────────────
                HStack(spacing: 8) {
                    Button { copySheet() } label: {
                        HStack(spacing: 5) {
                            Text(copied ? "copied!" : "copy to spreadsheet")
                                .font(.system(size: 14, weight: .bold))
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundColor(.qSubtext.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(copied ? .qGreen : .qSubtext)
                    .help("Pastes your answers, correct answers, and notes into 3 columns on Google Sheets / Excel")

                    if !model.trackingOnly {
                        Button {
                            model.revealScore.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.revealScore ? "eye.fill" : "eye.slash.fill")
                                Text(model.revealScore ? "score on" : "score off")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(model.revealScore ? .qAccent : .qSubtext)
                        .help(model.revealScore ? "Hide score" : "Show score")

                        Button {
                            model.revealFeedback.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.revealFeedback ? "checkmark.circle.fill" : "checkmark.circle")
                                Text(model.revealFeedback ? "feedback on" : "feedback off")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(model.revealFeedback ? .qGreen : .qSubtext)
                        .help(model.revealFeedback ? "Hide right/wrong feedback" : "Show right/wrong feedback")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.qBorder)
                    Rectangle().fill(Color.qAccent)
                        .frame(width: geo.size.width * CGFloat(model.current) / CGFloat(model.targetCount))
                        .animation(.easeInOut(duration: 0.2), value: model.current)
                }
            }
            .frame(height: 2)

            if showLog {
                QuizLogPanel(model: model, viewingQ: viewingQ, onSelectQ: { i in
                    if synced { currentPage = i }
                })
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            focused = true
            if !model.lastFeedbackText.isEmpty {
                feedbackText = model.lastFeedbackText
                feedbackColor = feedbackColorFor(model.lastFeedbackCorrect)
            }
        }
        .onChange(of: model.lastFeedbackText) { _, text in
            // Handles case where restore() fires after onAppear (PDF was just opened)
            if !text.isEmpty, feedbackText.isEmpty {
                feedbackText = text
                feedbackColor = feedbackColorFor(model.lastFeedbackCorrect)
            }
        }
        .onDisappear { model.inputFocused = false }
    }

    private func submitAnswer(_ c: Character) {
        input = ""
        if viewingQAnswered {
            model.changeAnswer(viewingQ, to: c)
            lastSubmitted = c
            feedbackText = model.lastFeedbackText
            feedbackColor = feedbackColorFor(model.lastFeedbackCorrect)
            lastCorrect = model.results[viewingQ].ok ? nil : model.results[viewingQ].correct
        } else if viewingQFuture {
            model.fillAndSubmit(viewingQ, c)
            lastSubmitted = c
            if !model.trackingOnly, let last = model.results.last {
                feedbackText  = last.ok
                    ? "✓  correct   \(model.score)/\(model.total)  \(String(format: "%.1f", model.pct))%"
                    : "✗   \(model.score)/\(model.total)  \(String(format: "%.1f", model.pct))%"
                feedbackColor = last.ok ? .qGreen : .qRed
                lastCorrect   = last.ok ? nil : last.correct
            }
        } else {
            model.submit(c); lastSubmitted = c
            if !model.trackingOnly, let last = model.results.last {
                feedbackText  = last.ok
                    ? "✓  correct   \(model.score)/\(model.total)  \(String(format: "%.1f", model.pct))%"
                    : "✗   \(model.score)/\(model.total)  \(String(format: "%.1f", model.pct))%"
                feedbackColor = last.ok ? .qGreen : .qRed
                lastCorrect   = last.ok ? nil : last.correct
            }
        }
        DispatchQueue.main.async { focused = true }
    }

    private func copySheet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.sheetsText(), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }
}

// MARK: Log + Notes Panel

struct QuizLogPanel: View {
    @ObservedObject var model: QuizModel
    let viewingQ: Int
    var onSelectQ: ((Int) -> Void)? = nil
    @State private var selectedQ: Int = 0
    @State private var notesAllView = false

    var body: some View {
        HStack(spacing: 0) {
            // ── Left: question list ───────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(0..<model.targetCount, id: \.self) { i in
                            listRow(i: i).id(i)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .onAppear {
                    selectedQ = viewingQ
                    proxy.scrollTo(viewingQ, anchor: .center)
                }
                .onChange(of: viewingQ) { _, q in
                    selectedQ = q
                    withAnimation { proxy.scrollTo(q, anchor: .center) }
                }
                .onChange(of: model.results.count) { _, _ in
                    withAnimation { proxy.scrollTo(model.results.count - 1, anchor: .center) }
                }
            }
            .frame(width: 230)

            Divider()

            // ── Right: note editor ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Button { withAnimation { notesAllView = false } } label: {
                            Text("Q\(selectedQ + 1) Note")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(!notesAllView ? .qText : .qSubtext)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                        }.buttonStyle(.plain)
                        Button { withAnimation { notesAllView = true } } label: {
                            Text("All Notes")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(notesAllView ? .qText : .qSubtext)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                        }.buttonStyle(.plain)
                    }
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(4)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 6)

                if notesAllView {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(0..<model.targetCount, id: \.self) { i in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(String(format: "Q%02d", i + 1))
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.qSubtext)
                                            .frame(width: 32, alignment: .leading)
                                        TextEditor(text: Binding(
                                            get: { i < model.notes.count ? model.notes[i] : "" },
                                            set: { if i < model.notes.count { model.notes[i] = $0 } }
                                        ))
                                        .font(.system(size: 11)).foregroundColor(.qText)
                                        .scrollContentBackground(.hidden).background(Color.clear)
                                        .frame(minHeight: 18)
                                    }
                                    .id(i)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                        .onAppear { proxy.scrollTo(selectedQ, anchor: .center) }
                        .onChange(of: selectedQ) { _, q in withAnimation { proxy.scrollTo(q, anchor: .center) } }
                    }
                } else {
                    TextEditor(text: Binding(
                        get: { selectedQ < model.notes.count ? model.notes[selectedQ] : "" },
                        set: { if selectedQ < model.notes.count { model.notes[selectedQ] = $0 } }
                    ))
                    .font(.system(size: 13)).foregroundColor(.qText)
                    .scrollContentBackground(.hidden).background(Color.clear)
                    .padding(.horizontal, 6).padding(.bottom, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: notesAllView ? 140 : 82)
        .background(Color.qSurface)
    }

    @ViewBuilder private func listRow(i: Int) -> some View {
        let answered = i < model.results.count
        let e: QuizEntry? = answered ? model.results[i] : nil
        let isSelected = i == selectedQ
        let isViewing  = i == viewingQ

        HStack(spacing: 4) {
            Button { model.toggleFlag(i) } label: {
                Image(systemName: model.flags.contains(i) ? "flag.fill" : "flag")
                    .font(.system(size: 8))
                    .foregroundColor(model.flags.contains(i) ? .orange : .qSubtext.opacity(0.25))
            }.buttonStyle(.plain)

            Text(String(format: "Q%02d", i + 1))
                .font(.system(size: 13, weight: isViewing ? .bold : .regular, design: .monospaced))
                .foregroundColor(isViewing ? .qText : .qSubtext)
                .frame(width: 34, alignment: .leading)

            answerText(e: e)

            if i < model.notes.count && !model.notes[i].isEmpty {
                Text(model.notes[i])
                    .font(.system(size: 11))
                    .foregroundColor(.qSubtext.opacity(0.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(isSelected ? Color.white.opacity(0.07) : Color.clear)
        .cornerRadius(3)
        .contentShape(Rectangle())
        .onTapGesture { selectedQ = i; onSelectQ?(i) }
    }

    @ViewBuilder private func answerText(e: QuizEntry?) -> some View {
        if let e = e {
            let isSkip = e.given == "?"
            if model.trackingOnly || !model.revealFeedback {
                Text(String(e.given))
                    .foregroundColor(isSkip ? .qSubtext.opacity(0.3) : .qText)
                    .frame(width: 18)
            } else {
                Text(String(e.given))
                    .foregroundColor(isSkip ? .qSubtext.opacity(0.3) : (e.ok ? .qGreen : .qRed))
                    .frame(width: 18)
                if !isSkip {
                    Text(e.ok ? "✓" : "✗")
                        .foregroundColor(e.ok ? .qGreen : .qRed)
                        .frame(width: 14)
                }
            }
        } else {
            Text("—").foregroundColor(.qSubtext.opacity(0.3)).frame(width: 18)
        }
    }
}

// MARK: Notes Panel

struct NotesPanel: View {
    @ObservedObject var model: QuizModel
    @Binding var notesAllView: Bool
    let currentQ: Int
    @State private var displayQ = 0

    private var lastQ: Int { max(0, model.notes.count - 1) }

    var body: some View {
        HStack(spacing: 0) {
            // ── Sidebar ───────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation { notesAllView = false }
                    } label: {
                        Text("Q\(displayQ + 1)").font(.system(size: 14, weight: .bold))
                            .foregroundColor(!notesAllView ? .qText : .qSubtext)
                    }
                    .buttonStyle(.plain)

                    Text("·").foregroundColor(.qSubtext).font(.system(size: 13))

                    Button {
                        withAnimation { notesAllView = true }
                    } label: {
                        Text("show all notes").font(.system(size: 14, weight: .bold))
                            .foregroundColor(notesAllView ? .qText : .qSubtext)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 20) {
                    Button {
                        displayQ = max(0, displayQ - 1)
                    } label: {
                        Text("←").font(.system(size: 14, weight: .bold))
                            .foregroundColor((notesAllView || displayQ == 0) ? Color.qSubtext.opacity(0.3) : .qSubtext)
                    }
                    .buttonStyle(.plain).disabled(notesAllView || displayQ == 0)

                    Button {
                        displayQ = min(lastQ, displayQ + 1)
                    } label: {
                        Text("→").font(.system(size: 14, weight: .bold))
                            .foregroundColor((notesAllView || displayQ >= lastQ) ? Color.qSubtext.opacity(0.3) : .qSubtext)
                    }
                    .buttonStyle(.plain).disabled(notesAllView || displayQ >= lastQ)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .fixedSize(horizontal: true, vertical: false)

            Divider()

            // ── Content area ─────────────────────────────────────────────
            if notesAllView {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.notes.indices, id: \.self) { i in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(String(format: "Q%02d", i + 1))
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.qSubtext)
                                        .frame(width: 34, alignment: .leading)
                                    Text(model.notes[i].isEmpty ? "—" : model.notes[i])
                                        .font(.system(size: 13))
                                        .foregroundColor(model.notes[i].isEmpty ? Color.qSubtext.opacity(0.4) : .qText)
                                }
                                .id(i)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    .onAppear { proxy.scrollTo(displayQ, anchor: .center) }
                }
                .frame(height: 110)
            } else {
                let idx = min(displayQ, lastQ)
                TextEditor(text: Binding(
                    get: { model.notes[idx] },
                    set: { model.notes[idx] = $0 }
                ))
                .font(.system(size: 14)).foregroundColor(.qText)
                .scrollContentBackground(.hidden).background(Color.qSurface)
                .frame(height: 46)
                .padding(.horizontal, 4).padding(.vertical, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.qSurface)
        .onAppear { displayQ = currentQ }
        .onChange(of: currentQ) { _, newQ in if !notesAllView { displayQ = newQ } }
    }
}

// MARK: Summary

struct QuizSummaryView: View {
    @EnvironmentObject var model: QuizModel
    @Binding var showLog: Bool
    @Binding var showNotes: Bool
    @Binding var notesAllView: Bool
    @State private var copied = false
    @State private var showResults = false
    @State private var showLogPanel = true
    @State private var showAddKey = false
    @State private var addKeyText = ""
    private var missed: [QuizEntry] { model.results.filter { !$0.ok } }
    private var flaggedCount: Int { model.flags.count }

    var body: some View {
        VStack(spacing: 0) {
            // ── Slim header ───────────────────────────────────────────────────
            HStack(spacing: 10) {
                if showResults {
                    if !model.trackingOnly {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(model.score)/\(model.targetCount)")
                                .font(.system(size: 14, weight: .bold)).foregroundColor(model.scoreColor)
                            Text("(\(String(format: "%.1f", model.pct))%)")
                                .font(.system(size: 12)).foregroundColor(model.scoreColor)
                        }
                        Text(missed.isEmpty ? "· perfect!" : "· \(missed.count) missed")
                            .font(.system(size: 11)).foregroundColor(missed.isEmpty ? .qGreen : .qSubtext)
                        if flaggedCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "flag.fill").font(.system(size: 10)).foregroundColor(.orange)
                                Text("\(flaggedCount)").font(.system(size: 11)).foregroundColor(.orange)
                            }
                        }
                    } else {
                        addKeySection
                    }
                } else {
                    Text("done").font(.system(size: 13, weight: .semibold)).foregroundColor(.qSubtext)
                    if model.trackingOnly { addKeySection }
                }
                Spacer()
                undoBtn
                if showResults {
                    copyBtn(highlighted: !showLogPanel)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showLogPanel.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("log/notes").font(.system(size: 11, weight: .medium))
                            Image(systemName: showLogPanel ? "chevron.up" : "chevron.down").font(.system(size: 9))
                        }
                        .foregroundColor(.qText)
                    }
                    .buttonStyle(.plain)
                    qBtn("new quiz", accent: true) { model.newQuiz() }
                    qBtn("retry") { model.retry() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            // ── Panel area (takes over where log was) ─────────────────────────
            if showLogPanel {
                QuizLogPanel(model: model, viewingQ: model.results.count - 1)
                    .transition(.opacity)
            } else if showResults {
                // Results panel
                VStack(spacing: 14) {
                    if !model.trackingOnly {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(model.score)/\(model.targetCount)")
                                .font(.system(size: 28, weight: .bold)).foregroundColor(model.scoreColor)
                            Text("(\(String(format: "%.1f", model.pct))%)")
                                .font(.system(size: 18)).foregroundColor(model.scoreColor)
                        }
                        Text(missed.isEmpty ? "Perfect score! 🎉" : "\(missed.count) question\(missed.count == 1 ? "" : "s") missed")
                            .font(.system(size: 13)).foregroundColor(missed.isEmpty ? .qGreen : .qSubtext)
                    }
                    HStack(spacing: 10) {
                        Button { model.revealScore.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.revealScore ? "eye.fill" : "eye.slash.fill")
                                Text(model.revealScore ? "score on" : "score off")
                            }.font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(model.revealScore ? .qAccent : .qText)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color(white: 0.22)).cornerRadius(5)

                        Button { model.revealFeedback.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.revealFeedback ? "checkmark.circle.fill" : "checkmark.circle")
                                Text(model.revealFeedback ? "feedback on" : "feedback off")
                            }.font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(model.revealFeedback ? .qGreen : .qText)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color(white: 0.22)).cornerRadius(5)

                        copyBtn(highlighted: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .background(Color.qSurface)
                .transition(.opacity)
            } else {
                // Finish panel (state 1)
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.qGreen).font(.system(size: 20))
                        Text("Quiz complete!")
                            .font(.system(size: 18, weight: .bold)).foregroundColor(.qText)
                    }
                    HStack(spacing: 12) {
                        Button {
                            withAnimation { showResults = true }
                            model.revealScore = true; model.revealFeedback = true
                        } label: {
                            Text("see results")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.54, green: 0.67, blue: 0.86))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Color(red: 0.165, green: 0.247, blue: 0.373))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        copyBtn(highlighted: false)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .background(Color.qSurface)
                .transition(.opacity)
            }
        }
        .onAppear { showLog = true }
        .animation(.easeInOut(duration: 0.18), value: showResults)
        .animation(.easeInOut(duration: 0.18), value: showLogPanel)
    }

    @ViewBuilder private var undoBtn: some View {
        Button("undo") { model.undo() }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            .foregroundColor(.qText)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color(white: 0.22)).cornerRadius(5)
    }

    @ViewBuilder private func copyBtn(highlighted: Bool) -> some View {
        Button { copySheet() } label: {
            HStack(spacing: 5) {
                Text(copied ? "copied!" : "copy to spreadsheet")
                Image(systemName: "info.circle").font(.system(size: 9))
                    .foregroundColor(highlighted && !copied ? Color(red: 0.54, green: 0.67, blue: 0.86).opacity(0.6) : .qText.opacity(0.4))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundColor(copied ? .qGreen : (highlighted ? Color(red: 0.54, green: 0.67, blue: 0.86) : .qText))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(highlighted && !copied ? Color(red: 0.165, green: 0.247, blue: 0.373) : Color(white: 0.22))
        .cornerRadius(5)
        .help("Pastes your answers, correct answers, and notes into 3 columns on Google Sheets / Excel")
    }

    @ViewBuilder private var addKeySection: some View {
        let addKeyLetters = Array(addKeyText.uppercased().filter { $0.isLetter })
        Button { showAddKey.toggle() } label: {
            Text("add key")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 0.54, green: 0.67, blue: 0.86))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color(red: 0.165, green: 0.247, blue: 0.373))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAddKey, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("answer key").font(.system(size: 11)).foregroundColor(.qSubtext)
                    Spacer()
                    Text("\(addKeyLetters.count)/\(model.targetCount)").font(.system(size: 11))
                        .foregroundColor(addKeyLetters.count == model.targetCount ? .qGreen : .qSubtext)
                }
                TextEditor(text: $addKeyText)
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.qText)
                    .scrollContentBackground(.hidden).background(Color.qSurface)
                    .frame(width: 200, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.qBorder, lineWidth: 1))
                Button {
                    model.addKey(addKeyLetters); showAddKey = false; addKeyText = ""
                    showResults = true; model.revealScore = true; model.revealFeedback = true
                } label: {
                    Text("apply key →")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(addKeyLetters.count == model.targetCount ? Color(red: 0.54, green: 0.67, blue: 0.86) : .qSubtext)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(addKeyLetters.count == model.targetCount ? Color(red: 0.165, green: 0.247, blue: 0.373) : Color.qBorder)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain).disabled(addKeyLetters.count != model.targetCount)
            }
            .padding(12).background(Color.qBg).preferredColorScheme(.dark)
        }
    }

    @ViewBuilder private func qBtn(_ label: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accent ? Color(red: 0.54, green: 0.67, blue: 0.86) : .qText)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(accent ? Color(red: 0.165, green: 0.247, blue: 0.373) : Color(white: 0.22))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
    }

    private func copySheet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.sheetsText(), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }
}

// MARK: - Lab Values

struct LabValue: Identifiable {
    let id = UUID()
    let name: String
    let range: String
}

struct LabSection: Identifiable {
    let id = UUID()
    let title: String
    let values: [LabValue]
}

let nbmeLabSections: [LabSection] = [
    LabSection(title: "Serum — Electrolytes", values: [
        LabValue(name: "Sodium (Na+)",         range: "136–146 mEq/L"),
        LabValue(name: "Potassium (K+)",        range: "3.5–5.0 mEq/L"),
        LabValue(name: "Chloride (Cl–)",        range: "95–105 mEq/L"),
        LabValue(name: "Bicarbonate (HCO3–)",   range: "22–28 mEq/L"),
        LabValue(name: "Urea nitrogen (BUN)",   range: "7–18 mg/dL"),
        LabValue(name: "Creatinine",            range: "0.6–1.2 mg/dL"),
        LabValue(name: "Glucose (fasting)",     range: "70–100 mg/dL"),
        LabValue(name: "Glucose (random)",      range: "<140 mg/dL"),
        LabValue(name: "Calcium",               range: "8.4–10.2 mg/dL"),
        LabValue(name: "Magnesium (Mg2+)",      range: "1.5–2.0 mg/dL"),
        LabValue(name: "Phosphorus",            range: "3.0–4.5 mg/dL"),
    ]),
    LabSection(title: "Serum — Hepatic", values: [
        LabValue(name: "ALT",                   range: "10–40 U/L"),
        LabValue(name: "AST",                   range: "12–38 U/L"),
        LabValue(name: "Alkaline phosphatase",  range: "25–100 U/L"),
        LabValue(name: "Bilirubin, total",      range: "0.1–1.0 mg/dL"),
        LabValue(name: "Bilirubin, direct",     range: "0.0–0.3 mg/dL"),
        LabValue(name: "Proteins, total",       range: "6.0–7.8 g/dL"),
        LabValue(name: "Albumin",               range: "3.5–5.5 g/dL"),
        LabValue(name: "Globulin",              range: "2.3–3.5 g/dL"),
        LabValue(name: "Amylase",               range: "25–125 U/L"),
        LabValue(name: "Lipase",                range: "13–60 U/L"),
    ]),
    LabSection(title: "Serum — Other", values: [
        LabValue(name: "Creatinine clearance (M)", range: "97–137 mL/min"),
        LabValue(name: "Creatinine clearance (F)", range: "88–128 mL/min"),
        LabValue(name: "Creatine kinase (M)",    range: "25–90 U/L"),
        LabValue(name: "Creatine kinase (F)",    range: "10–70 U/L"),
        LabValue(name: "LDH",                    range: "45–200 U/L"),
        LabValue(name: "Osmolality",             range: "275–295 mOsmol/kg"),
        LabValue(name: "Troponin I",             range: "≤0.04 ng/mL"),
        LabValue(name: "Uric acid",              range: "3.0–8.2 mg/dL"),
    ]),
    LabSection(title: "Serum — Lipids", values: [
        LabValue(name: "Cholesterol, total (normal)", range: "<200 mg/dL"),
        LabValue(name: "Cholesterol, total (high)",   range: ">240 mg/dL"),
        LabValue(name: "HDL",                    range: "40–60 mg/dL"),
        LabValue(name: "LDL",                    range: "<160 mg/dL"),
        LabValue(name: "Triglycerides (normal)", range: "<150 mg/dL"),
        LabValue(name: "Triglycerides (borderline)", range: "151–199 mg/dL"),
    ]),
    LabSection(title: "Serum — Iron Studies", values: [
        LabValue(name: "Ferritin (M)",          range: "20–250 ng/mL"),
        LabValue(name: "Ferritin (F)",          range: "10–120 ng/mL"),
        LabValue(name: "Iron (M)",              range: "65–175 µg/dL"),
        LabValue(name: "Iron (F)",              range: "50–170 µg/dL"),
        LabValue(name: "TIBC",                  range: "250–400 µg/dL"),
        LabValue(name: "Transferrin",           range: "200–360 mg/dL"),
    ]),
    LabSection(title: "Serum — Endocrine", values: [
        LabValue(name: "TSH",                   range: "0.4–4.0 µU/mL"),
        LabValue(name: "T3 (total)",            range: "100–200 ng/dL"),
        LabValue(name: "T3 resin uptake",       range: "25–35%"),
        LabValue(name: "T4 (total)",            range: "5–12 µg/dL"),
        LabValue(name: "Free T4",               range: "0.9–1.7 ng/dL"),
        LabValue(name: "Thyroidal iodine uptake", range: "8–30% /24h"),
        LabValue(name: "Intact PTH",            range: "10–60 pg/mL"),
        LabValue(name: "Cortisol (0800h)",      range: "5–23 µg/dL"),
        LabValue(name: "Cortisol (1600h)",      range: "3–15 µg/dL"),
        LabValue(name: "Prolactin (M)",         range: "<17 ng/mL"),
        LabValue(name: "Prolactin (F)",         range: "<25 ng/mL"),
        LabValue(name: "Growth hormone (fasting)", range: "<5 ng/mL"),
        LabValue(name: "Growth hormone (stimulated)", range: ">7 ng/mL"),
        LabValue(name: "FSH (M)",               range: "4–25 mIU/mL"),
        LabValue(name: "LH (M)",                range: "6–23 mIU/mL"),
    ]),
    LabSection(title: "Serum — Immunoglobulins", values: [
        LabValue(name: "IgA",   range: "76–390 mg/dL"),
        LabValue(name: "IgE",   range: "0–380 IU/mL"),
        LabValue(name: "IgG",   range: "650–1500 mg/dL"),
        LabValue(name: "IgM",   range: "50–300 mg/dL"),
    ]),
    LabSection(title: "Arterial Blood Gas", values: [
        LabValue(name: "PO2",   range: "75–105 mm Hg"),
        LabValue(name: "PCO2",  range: "33–45 mm Hg"),
        LabValue(name: "pH",    range: "7.35–7.45"),
    ]),
    LabSection(title: "CSF", values: [
        LabValue(name: "Cell count",       range: "0–5/mm³"),
        LabValue(name: "Chloride",         range: "118–132 mEq/L"),
        LabValue(name: "Glucose",          range: "40–70 mg/dL"),
        LabValue(name: "Pressure",         range: "70–180 mm H2O"),
        LabValue(name: "Proteins, total",  range: "<40 mg/dL"),
        LabValue(name: "Gamma globulin",   range: "3–12% total protein"),
    ]),
    LabSection(title: "Hematology — CBC", values: [
        LabValue(name: "Hematocrit (M)",     range: "41–53%"),
        LabValue(name: "Hematocrit (F)",     range: "36–46%"),
        LabValue(name: "Hemoglobin (M)",     range: "13.5–17.5 g/dL"),
        LabValue(name: "Hemoglobin (F)",     range: "12.0–16.0 g/dL"),
        LabValue(name: "MCH",                range: "25–35 pg/cell"),
        LabValue(name: "MCHC",               range: "31–36%"),
        LabValue(name: "MCV",                range: "80–100 µm³"),
        LabValue(name: "WBC",                range: "4,500–11,000/mm³"),
        LabValue(name: "Neutrophils (seg)",  range: "54–62%"),
        LabValue(name: "Neutrophils (bands)", range: "3–5%"),
        LabValue(name: "Lymphocytes",        range: "25–33%"),
        LabValue(name: "Monocytes",          range: "3–7%"),
        LabValue(name: "Eosinophils",        range: "1–3%"),
        LabValue(name: "Basophils",          range: "0–0.75%"),
        LabValue(name: "Platelets",          range: "150,000–400,000/mm³"),
        LabValue(name: "RBC (M)",            range: "4.3–5.9 × 10⁶/mm³"),
        LabValue(name: "RBC (F)",            range: "3.5–5.5 × 10⁶/mm³"),
        LabValue(name: "Reticulocytes",      range: "0.5–1.5%"),
    ]),
    LabSection(title: "Hematology — Coagulation", values: [
        LabValue(name: "aPTT",     range: "25–40 sec"),
        LabValue(name: "PT",       range: "11–15 sec"),
        LabValue(name: "D-dimer",  range: "≤250 ng/mL"),
        LabValue(name: "ESR (M)",  range: "0–15 mm/h"),
        LabValue(name: "ESR (F)",  range: "0–20 mm/h"),
        LabValue(name: "CD4+ T cells", range: "≥500/mm³"),
        LabValue(name: "HbA1c",    range: "≤6%"),
    ]),
    LabSection(title: "Urine", values: [
        LabValue(name: "Calcium",          range: "100–300 mg/24h"),
        LabValue(name: "Osmolality",       range: "50–1200 mOsmol/kg"),
        LabValue(name: "Oxalate",          range: "8–40 µg/mL"),
        LabValue(name: "Proteins, total",  range: "<150 mg/24h"),
    ]),
    LabSection(title: "BMI", values: [
        LabValue(name: "Normal BMI", range: "19–25 kg/m²"),
    ]),
]

struct LabValuesPanel: View {
    @State private var search = ""

    private var filtered: [LabSection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nbmeLabSections }
        return nbmeLabSections.compactMap { section in
            let matchedValues = section.values.filter {
                $0.name.lowercased().contains(q) || $0.range.lowercased().contains(q)
            }
            if section.title.lowercased().contains(q) { return section }
            return matchedValues.isEmpty ? nil : LabSection(title: section.title, values: matchedValues)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NBME Lab Values")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search lab values...", text: $search)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 10).padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(filtered) { section in
                        Section {
                            ForEach(section.values) { val in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(val.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Text(val.range)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.001))
                                Divider().padding(.leading, 12)
                            }
                        } header: {
                            Text(section.title.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.windowBackgroundColor))
                        }
                    }
                }
            }
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var sc = ShortcutStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.headline)
                .padding(.bottom, 12)

            Group {
                sectionHeader("Annotation Tools")
                ShortcutRow(label: "Cursor mode",        key: $sc.cursor)
                ShortcutRow(label: "Highlight mode",     key: $sc.highlight)
                ShortcutRow(label: "Strikethrough mode", key: $sc.strikethrough)
                ShortcutRow(label: "Text box",           key: $sc.textBox)
            }

            Divider().padding(.vertical, 10)

            Group {
                sectionHeader("Navigation & Tools")
                ShortcutRow(label: "Switch tab",   key: $sc.switchTab)
                ShortcutRow(label: "Quiz checker", key: $sc.openQuiz)
            }

            Divider().padding(.vertical, 10)

            Group {
                sectionHeader("Quiz")
                HStack {
                    Text("Questions per quiz").frame(width: 165, alignment: .leading)
                    Stepper(value: $sc.questionCount, in: 1...500) {
                        Text("\(sc.questionCount)")
                            .foregroundStyle(sc.questionCount == 50 ? Color.primary : Color.accentColor)
                            .frame(width: 40, alignment: .leading)
                    }
                }
            }

            Divider().padding(.vertical, 10)

            Text("Fixed shortcuts: ⌘F Find · ⌘Z Undo · ⌘⇧Z Redo · ⌘S Save · ⌘O Open · ⌘W Close tab · Space Switch tab")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}

struct ShortcutRow: View {
    let label: String
    @Binding var key: String
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label).frame(width: 165, alignment: .leading)

            Button(recording ? "Press a key…" : (key.isEmpty ? "None" : key.uppercased())) {
                recording ? stopRecording() : startRecording()
            }
            .frame(width: 110)
            .foregroundStyle(recording ? Color.accentColor : Color.primary)
            .background(
                recording ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                recording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))

            Button("Clear") { key = "" }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(key.isEmpty ? 0.3 : 1)
                .disabled(key.isEmpty)
        }
        .padding(.vertical, 3)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { self.stopRecording(); return nil } // Escape = cancel
            let raw = event.charactersIgnoringModifiers ?? ""
            if let ch = raw.first, ch.isLetter { self.key = String(ch).lowercased() }
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
