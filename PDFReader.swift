import SwiftUI
import PDFKit
import UniformTypeIdentifiers

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
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var hasUnsavedChanges: (() -> Bool)?
    var performSave: (() -> Void)?
    // All open doc hosts — checked on quit so every unsaved doc is caught
    var allHosts: (() -> [PDFViewHost]) = { [] }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = allHosts().filter { $0.hasUnsavedChanges }
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
            let dirty = getAllHosts().filter { $0.hasUnsavedChanges }
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
    var suppressContextMenu = false

    override func menu(for event: NSEvent) -> NSMenu? {
        suppressContextMenu ? nil : super.menu(for: event)
    }

    private var mouseDownLocation: CGPoint = .zero

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
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
}

class PDFViewHost: ObservableObject {
    weak var pdfView: AnnotatingPDFView?
    @Published var currentScale: CGFloat = 1.0
    @Published var activeTool: AnnotationTool = .highlight {
        didSet { pdfView?.suppressContextMenu = (activeTool == .highlight) }
    }
    @Published var highlightColor: Color = Color(red: 1.0, green: 1.0, blue: 0.0)
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasUnsavedChanges = false
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
        scaleObserver = view.observe(\.scaleFactor, options: [.new]) { [weak self] _, change in
            if let s = change.newValue {
                DispatchQueue.main.async { self?.currentScale = s }
            }
        }
        view.onSelectionReleased = { [weak self] in self?.handleSelectionReleased() }
        view.onLeftClick = { [weak self] page, pt in self?.handleLeftClick(page: page, pagePoint: pt) }
        view.onRightClick = { [weak self] page, pt in self?.handleRightClick(page: page, pagePoint: pt) }
    }

    // Auto-apply current tool when the user finishes a drag-selection.
    private func handleSelectionReleased() {
        switch activeTool {
        case .cursor: break
        case .highlight:
            applyAnnotation(subtype: .highlight, color: NSColor(highlightColor))
        case .strikethrough:
            applyAnnotation(subtype: .strikeOut, color: NSColor.red.withAlphaComponent(0.85))
        }
    }

    // Left-click: remove any annotation directly under the cursor.
    private func handleLeftClick(page: PDFPage, pagePoint: CGPoint) {
        guard let hit = page.annotations.first(where: {
            ($0.type == "Highlight" || isStrikethrough($0)) && $0.bounds.contains(pagePoint)
        }) else { return }
        page.removeAnnotation(hit)
        pushUndo(.removed([(hit, page)]))
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

    func discardChanges() { hasUnsavedChanges = false }

    func undo() {
        guard let entry = undoHistory.popLast() else { return }
        switch entry {
        case .added(let items):   items.forEach { $0.1.removeAnnotation($0.0) }
        case .removed(let items): items.forEach { $0.1.addAnnotation($0.0) }
        }
        redoHistory.append(entry)
        canUndo = !undoHistory.isEmpty
        canRedo = true
    }

    func redo() {
        guard let entry = redoHistory.popLast() else { return }
        switch entry {
        case .added(let items):   items.forEach { $0.1.addAnnotation($0.0) }
        case .removed(let items): items.forEach { $0.1.removeAnnotation($0.0) }
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
        if let url = document.documentURL {
            document.write(to: url)
            hasUnsavedChanges = false
        } else {
            saveAs()
        }
    }

    func saveAs() {
        guard let document = pdfView?.document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.documentURL?.lastPathComponent ?? "document.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.write(to: url)
        hasUnsavedChanges = false
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

// MARK: - Root

struct DocEntry: Identifiable {
    let id = UUID()
    let doc: PDFDocument
    let title: String
    let quizModel = QuizModel()
    let host = PDFViewHost()
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
                    showQuiz: Binding(
                        get: { docs[activeIndex].showQuiz },
                        set: { docs[activeIndex].showQuiz = $0 }
                    ),
                    currentPage: Binding(
                        get: { docs[activeIndex].currentPage },
                        set: { docs[activeIndex].currentPage = $0 }
                    ),
                    onSwitchTab: switchTab
                )
                .id(docs[activeIndex].id)
            }
        }
        .onAppear {
            if docs.isEmpty { openFile() }
            appDelegate.allHosts = { docs.map { $0.host } }
        }
        .onChange(of: docs.count) { _, _ in
            appDelegate.allHosts = { docs.map { $0.host } }
        }
        .navigationTitle(docs.isEmpty ? "PDF Reader" : docs[activeIndex].title)
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
    @Binding var showQuiz: Bool
    @Binding var currentPage: Int
    let onSwitchTab: () -> Void
    @State private var totalPages: Int
    @State private var keyMonitor: Any?
    @State private var showColorPicker = false
    @State private var savedFeedback = false
    @EnvironmentObject var appDelegate: AppDelegate

    init(document: PDFDocument, host: PDFViewHost, quizModel: QuizModel, showQuiz: Binding<Bool>, currentPage: Binding<Int>, onSwitchTab: @escaping () -> Void = {}) {
        self.document = document
        self.host = host
        self.quizModel = quizModel
        self._showQuiz = showQuiz
        self._currentPage = currentPage
        self.onSwitchTab = onSwitchTab
        _totalPages = State(initialValue: document.pageCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowCloseInterceptor(getAllHosts: appDelegate.allHosts).frame(width: 0, height: 0)
            PDFKitRepresentable(document: document, currentPage: $currentPage, host: host)

            Divider()

            HStack(spacing: 10) {
                // Page navigation
                Button { currentPage -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(currentPage == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])

                PageTextField(currentPage: $currentPage, totalPages: totalPages)

                Button { currentPage += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(currentPage >= totalPages - 1)
                    .keyboardShortcut(.rightArrow, modifiers: [])

                Divider().frame(height: 20)

                // Tool buttons
                toolButton(.cursor)
                toolButton(.highlight)
                toolButton(.strikethrough)

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

                Button { saveWithFeedback() } label: { Image(systemName: "square.and.arrow.down") }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!host.hasUnsavedChanges)
                    .help("Save (⌘S)")

                if savedFeedback {
                    Text("Saved ✓")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.green)
                        .transition(.opacity)
                }

                Button { showQuiz.toggle() } label: { Image(systemName: "checklist") }
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
                QuizPanel(model: quizModel)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showQuiz)
        .animation(.easeInOut(duration: 0.15), value: host.activeTool == .highlight)
        .onChange(of: host.hasUnsavedChanges) { _, newValue in
            NSApp.keyWindow?.isDocumentEdited = newValue
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let noMods = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                // Spacebar switches tabs even when a text field is focused
                if noMods, event.charactersIgnoringModifiers == " " {
                    onSwitchTab()
                    return nil
                }
                guard noMods, !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
                switch event.charactersIgnoringModifiers {
                case "a": host.activeTool = .cursor;        return nil
                case "s": host.activeTool = .highlight;     return nil
                case "d": host.activeTool = .strikethrough; return nil
                case "f": onSwitchTab();                    return nil
                default:  return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    private func saveWithFeedback() {
        host.save()
        savedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedFeedback = false }
    }

    @ViewBuilder
    private func toolButton(_ tool: AnnotationTool) -> some View {
        let isActive = host.activeTool == tool
        Button { host.activeTool = tool } label: {
            Image(systemName: tool.icon)
        }
        .keyboardShortcut(tool.shortcut, modifiers: [])
        .buttonStyle(.bordered)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .background(
            isActive ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .help("\(tool.label) (\(String(tool.shortcut.character).uppercased()))")
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
            Text("PDF Reader")
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

enum QuizPhase { case setup, active, summary }

struct QuizEntry: Identifiable {
    let id = UUID()
    let number: Int
    let given: Character
    let correct: Character
    var ok: Bool { given == correct }
}

class QuizModel: ObservableObject {
    @Published var phase: QuizPhase = .setup
    @Published private(set) var key: [Character] = []
    @Published private(set) var results: [QuizEntry] = []
    @Published private(set) var current: Int = 0

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
        phase = current >= 50 ? .summary : .active
    }

    func submit(_ c: Character) {
        guard current < key.count else { return }
        results.append(QuizEntry(number: current + 1, given: c, correct: key[current]))
        current += 1
        if current >= 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.phase = .summary }
        }
    }

    func undo() {
        guard !results.isEmpty, phase == .active else { return }
        results.removeLast()
        current -= 1
    }

    func newQuiz() { key = []; results = []; current = 0; phase = .setup }
    func retry()   { results = []; current = 0; phase = .active }

    func sheetsText() -> String {
        results.map { "\($0.given)\t\($0.correct)" }.joined(separator: "\n")
    }
}

struct QuizPanel: View {
    @ObservedObject var model: QuizModel
    @State private var showLog = false

    var body: some View {
        Group {
            switch model.phase {
            case .setup:   QuizSetupView().environmentObject(model)
            case .active:  QuizActiveView(showLog: $showLog).environmentObject(model)
            case .summary: QuizSummaryView(showLog: $showLog).environmentObject(model)
            }
        }
        .background(Color.qBg)
        .preferredColorScheme(.dark)
    }
}

// MARK: Setup

struct QuizSetupView: View {
    @EnvironmentObject var model: QuizModel
    @State private var keyText  = ""
    @State private var doneText = ""

    private var keyLetters:  [Character] { Array(keyText.uppercased().filter  { $0.isLetter }) }
    private var doneLetters: [Character] { Array(doneText.uppercased().filter { $0.isLetter }) }
    private var ready: Bool { keyLetters.count == 50 && doneLetters.count <= 50 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Answer key
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Answer key").font(.system(size: 11)).foregroundColor(.qSubtext)
                    Spacer()
                    Text("\(keyLetters.count)/50").font(.system(size: 11))
                        .foregroundColor(keyLetters.count == 50 ? .qGreen : .qSubtext)
                }
                qTextArea($keyText)
            }

            // Already done
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Already done (opt.)").font(.system(size: 11)).foregroundColor(.qSubtext)
                    Spacer()
                    let n = doneLetters.count
                    Text(n > 50 ? "max 50" : n == 0 ? "→Q1" : "→Q\(n+1)").font(.system(size: 11))
                        .foregroundColor(n > 50 ? .qRed : .qSubtext)
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
    @State private var input = ""
    @State private var feedbackText  = ""
    @State private var feedbackColor: Color = .qSubtext
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Q\(model.current + 1)/50")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(.qText)

                TextField("", text: $input)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.qText).multilineTextAlignment(.center)
                    .frame(width: 40).padding(.vertical, 5)
                    .background(Color.qSurface)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.qBorder, lineWidth: 1))
                    .focused($focused)
                    .onChange(of: input) { _, val in
                        if let c = val.uppercased().last(where: { $0.isLetter }) { submitAnswer(c) }
                        else if !val.isEmpty { input = "" }
                    }

                Text(feedbackText.isEmpty ? " " : feedbackText)
                    .font(.system(size: 13, weight: .bold)).foregroundColor(feedbackColor)

                Button("undo") {
                    model.undo()
                    feedbackText = "undone — Q\(model.current + 1)"; feedbackColor = .qSubtext
                }
                .keyboardShortcut("u", modifiers: .command)
                .buttonStyle(.plain).font(.system(size: 13, weight: .bold))
                .foregroundColor(model.results.isEmpty ? Color.qSubtext.opacity(0.3) : .qSubtext)
                .disabled(model.results.isEmpty)

                Button(copied ? "copied!" : "copy") { copySheet() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .bold))
                    .foregroundColor(copied ? .qGreen : .qSubtext)

                Button("new key") { model.newQuiz() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .bold))
                    .foregroundColor(.qSubtext)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text("log").font(.system(size: 13, weight: .bold)).foregroundColor(.qSubtext)
                        Image(systemName: showLog ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold)).foregroundColor(.qSubtext)
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.qBorder)
                    Rectangle().fill(Color.qAccent)
                        .frame(width: geo.size.width * CGFloat(model.current) / 50)
                        .animation(.easeInOut(duration: 0.2), value: model.current)
                }
            }
            .frame(height: 2)

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.results) { e in logRow(e).id(e.id) }
                        }
                        .padding(8)
                    }
                    .frame(height: 110)
                    .background(Color.qSurface)
                    .onChange(of: model.results.count) { _, _ in
                        if let last = model.results.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private func logRow(_ e: QuizEntry) -> some View {
        HStack(spacing: 0) {
            Text(String(format: "Q%02d  ", e.number)).foregroundColor(.qSubtext)
            Text(String(e.given)).foregroundColor(e.ok ? .qGreen : .qRed)
            if e.ok { Text("  ✓").foregroundColor(.qGreen) }
            else { Text("  ✗   → ").foregroundColor(.qRed); Text(String(e.correct)).foregroundColor(.qGreen) }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func submitAnswer(_ c: Character) {
        model.submit(c); input = ""
        if let last = model.results.last {
            feedbackText  = last.ok
                ? "✓  correct   \(model.score)/\(model.total)  \(String(format: "%.1f", model.pct))%"
                : "✗  was \(last.correct)   \(model.score)/\(model.total)  \(String(format: "%.1f", model.pct))%"
            feedbackColor = last.ok ? .qGreen : .qRed
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

// MARK: Summary

struct QuizSummaryView: View {
    @EnvironmentObject var model: QuizModel
    @Binding var showLog: Bool
    @State private var copied = false
    private var missed: [QuizEntry] { model.results.filter { !$0.ok } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Results").font(.system(size: 13, weight: .bold)).foregroundColor(.qText)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(model.score)/50")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(model.scoreColor)
                    Text("\(String(format: "%.1f", model.pct))%")
                        .font(.system(size: 12)).foregroundColor(model.scoreColor)
                }

                Text(missed.isEmpty ? "· perfect!" : "· \(missed.count) missed")
                    .font(.system(size: 11))
                    .foregroundColor(missed.isEmpty ? .qGreen : .qSubtext)

                Spacer()

                qBtn("new quiz", accent: true) { model.newQuiz() }
                qBtn("retry") { model.retry() }

                Button(copied ? "copied!" : "copy") { copySheet() }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundColor(copied ? .qGreen : .qSubtext)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.qCard).cornerRadius(5)

                if !missed.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("missed").font(.system(size: 11)).foregroundColor(.qSubtext)
                            Image(systemName: showLog ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9)).foregroundColor(.qSubtext)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)

            if showLog && !missed.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(missed) { e in
                            HStack(spacing: 0) {
                                Text(String(format: "Q%02d  ", e.number)).foregroundColor(.qSubtext)
                                Text(String(e.given)).foregroundColor(.qRed)
                                Text("  →  ").foregroundColor(.qSubtext)
                                Text(String(e.correct)).foregroundColor(.qGreen)
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .padding(8)
                }
                .frame(height: 110)
                .background(Color.qSurface)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private func qBtn(_ label: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: accent ? .bold : .regular))
                .foregroundColor(accent ? Color(red: 0.54, green: 0.67, blue: 0.86) : .qSubtext)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(accent ? Color(red: 0.165, green: 0.247, blue: 0.373) : Color.qCard)
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
