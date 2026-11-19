import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine
import QuickLookThumbnailing
import QuickLookUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings

enum Corner: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        }
    }

    var isTop: Bool { self == .topRight || self == .topLeft }
    var isRight: Bool { self == .bottomRight || self == .topRight }
}

enum Prefs {
    static let enabledKey = "enabled"
    static let cornerKey = "corner"
    static let marginKey = "edgeMargin"
    static let liteKey = "liteMode"
    static let keepKey = "keepItems"
    static let aeroKey = "aeroSpaceButtons"
    static let catchAllKey = "catchAll"
    static let hotkeyKey = "hotkey"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            cornerKey: Corner.bottomRight.rawValue,
            marginKey: 20.0,
            liteKey: false,
            keepKey: false,
            aeroKey: true,
            catchAllKey: true,
            hotkeyKey: HotKeyChoice.ctrlOptS.rawValue
        ])
    }

    static var corner: Corner {
        Corner(rawValue: UserDefaults.standard.string(forKey: cornerKey) ?? "") ?? .bottomRight
    }
    static var margin: CGFloat { CGFloat(UserDefaults.standard.double(forKey: marginKey)) }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var lite: Bool { UserDefaults.standard.bool(forKey: liteKey) }
    static var aero: Bool { UserDefaults.standard.bool(forKey: aeroKey) }
    static var catchAll: Bool { UserDefaults.standard.bool(forKey: catchAllKey) }
    static var hotkey: HotKeyChoice {
        HotKeyChoice(rawValue: UserDefaults.standard.string(forKey: hotkeyKey) ?? "") ?? .ctrlOptS
    }
}

// MARK: - Items

// One thing on the shelf: a file, a web link, or a piece of text.
// (Images dragged out of web pages are saved as files, so they count as files.)
struct ShelfItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case file(URL)
        case link(URL)
        case text(String)
    }

    let id = UUID()
    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    // What gets written to the pasteboard when you drag this item out.
    func makeWriter() -> any NSPasteboardWriting {
        switch kind {
        case .file(let url):
            return url as NSURL
        case .link(let url):
            let pasteboardItem = NSPasteboardItem()
            _ = pasteboardItem.setString(url.absoluteString, forType: .URL)
            _ = pasteboardItem.setString(url.absoluteString, forType: .string)
            return pasteboardItem
        case .text(let text):
            let pasteboardItem = NSPasteboardItem()
            _ = pasteboardItem.setString(text, forType: .string)
            return pasteboardItem
        }
    }
}

func symbolImage(_ name: String) -> NSImage {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
        ?? NSImage(size: NSSize(width: 32, height: 32))
}

// An icon that never opens the file (used in lite mode, and as a fallback).
func fileIcon(for url: URL, lite: Bool) -> NSImage {
    if lite {
        let type: UTType = url.hasDirectoryPath
            ? .folder
            : (UTType(filenameExtension: url.pathExtension) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }
    return NSWorkspace.shared.icon(forFile: url.path)
}

// The small picture shown under the cursor while dragging an item.
func dragIcon(for item: ShelfItem, lite: Bool) -> NSImage {
    switch item.kind {
    case .file(let url): return fileIcon(for: url, lite: lite)
    case .link: return symbolImage("link")
    case .text: return symbolImage("text.alignleft")
    }
}

// Images that don't exist as files (e.g. dragged out of a web page) get saved
// here so they behave like any other file. Cleared when Shelf starts and quits.
enum TempStore {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ToteImages", isDirectory: true)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())

        var url = directory.appendingPathComponent("Image \(stamp).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Image \(stamp) \(counter).png")
            counter += 1
        }

        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

// Turns whatever is being dragged into shelf items.
enum PasteboardReader {
    static func items(from pasteboard: NSPasteboard) -> [ShelfItem] {
        // 1. Files
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
           !urls.isEmpty {
            return urls.map { ShelfItem(.file($0)) }
        }

        // Everything below is the "also hold text, links and images" setting.
        guard Prefs.catchAll else { return [] }

        // 2. Raw image data (e.g. an image dragged out of a web page)
        if NSImage.canInit(with: pasteboard),
           let image = NSImage(pasteboard: pasteboard),
           let url = TempStore.save(image) {
            return [ShelfItem(.file(url))]
        }

        // 3. Web links
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let links = urls.filter { !$0.isFileURL }
            if !links.isEmpty { return links.map { ShelfItem(.link($0)) } }
        }

        // 4. Text (a lone web address counts as a link)
        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            return strings.compactMap { raw in
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                if let url = webURL(from: text) { return ShelfItem(.link(url)) }
                return ShelfItem(.text(text))
            }
        }

        return []
    }

    private static func webURL(from text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}

// MARK: - Global hotkey

// A few ready-made shortcuts to choose from. (Ctrl+Option combos rarely clash
// with other apps.)
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off, ctrlOptS, ctrlOptCmdS, ctrlShiftS, ctrlOptSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .ctrlOptS: return "⌃⌥S"
        case .ctrlOptCmdS: return "⌃⌥⌘S"
        case .ctrlShiftS: return "⌃⇧S"
        case .ctrlOptSpace: return "⌃⌥Space"
        }
    }

    // The key and modifier keys, in the form the system hotkey API wants.
    var combo: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .off:
            return nil
        case .ctrlOptS:
            return (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey))
        case .ctrlOptCmdS:
            return (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey))
        case .ctrlShiftS:
            return (UInt32(kVK_ANSI_S), UInt32(controlKey | shiftKey))
        case .ctrlOptSpace:
            return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        }
    }
}

// Registers a system-wide shortcut. This API needs no special permission.
@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    @Published var registrationFailed = false
    var onPress: (@MainActor () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // Call at launch and whenever the chosen shortcut changes.
    func reload() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registrationFailed = false

        guard let combo = Prefs.hotkey.combo else { return }

        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            _ = InstallEventHandler(
                GetApplicationEventTarget(),
                hotKeyCallback,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef
            )
        }

        let id = EventHotKeyID(signature: OSType(0x53484C46), id: 1)   // "SHLF"
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        registrationFailed = (status != noErr)
    }
}

// Called by the system when the shortcut is pressed.
nonisolated private func hotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.onPress?()
    }
    return noErr
}

// MARK: - Quick Look

// Shows the standard macOS Quick Look window for files on the shelf.
@MainActor
final class PreviewController: NSObject, QLPreviewPanelDataSource {
    static let shared = PreviewController()

    nonisolated(unsafe) private var urls: [URL] = []

    func show(_ url: URL, among all: [URL]) {
        urls = all.contains(url) ? all : [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex(of: url) ?? 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}

// MARK: - AeroSpace integration

// Talks to AeroSpace through its command-line tool, if it is installed.
enum AeroSpace {
    static var path: String? {
        ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { path != nil }

    // Runs `aerospace <args>` off the main thread and returns its output.
    static func run(_ args: [String]) async -> String? {
        guard let path else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}

// MARK: - Data

// Everything on the shelf (references to files, not copies), plus AeroSpace workspaces.
@MainActor
final class ShelfModel: ObservableObject {
    static let shared = ShelfModel()

    @Published var items: [ShelfItem] = [] {
        didSet { onChange?() }
    }
    @Published var workspaces: [String] = []
    @Published var focusedWorkspace = ""

    // Used by the panel-level drop handling (see ShelfContainerView).
    @Published var hoveredChip: String?
    @Published var dropTargeted = false
    var chipFrames: [String: CGRect] = [:]

    var onChange: (@MainActor () -> Void)?

    func add(_ item: ShelfItem) {
        // Don't add the same thing twice.
        if !items.contains(where: { $0.kind == item.kind }) {
            items.append(item)
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }

    // Drop file entries whose file was moved or deleted since it was added.
    func prune() {
        let alive = items.filter { item in
            if case .file(let url) = item.kind {
                return FileManager.default.fileExists(atPath: url.path)
            }
            return true
        }
        if alive.count != items.count { items = alive }
    }

    // Ask AeroSpace which workspaces exist and which one is focused.
    func refreshWorkspaces() async {
        guard Prefs.aero, AeroSpace.isAvailable else {
            if !workspaces.isEmpty { workspaces = [] }
            return
        }
        let list = await AeroSpace.run(["list-workspaces", "--all"])
        let focused = await AeroSpace.run(["list-workspaces", "--focused"])

        let names = (list ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        workspaces = names
        focusedWorkspace = (focused ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func switchWorkspace(_ name: String) async {
        _ = await AeroSpace.run(["workspace", name])
        await refreshWorkspaces()
    }
}

// MARK: - App

@main
struct ToteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Tote", systemImage: "bag") {
            MenuView()
        }
        .menuBarExtraStyle(.window)
    }
}

// The settings panel that opens when you click the tray icon.
struct MenuView: View {
    @ObservedObject private var model = ShelfModel.shared
    @AppStorage(Prefs.enabledKey) private var enabled = true
    @AppStorage(Prefs.cornerKey) private var corner: Corner = .bottomRight
    @AppStorage(Prefs.marginKey) private var margin: Double = 20
    @AppStorage(Prefs.liteKey) private var liteMode = false
    @AppStorage(Prefs.keepKey) private var keepItems = false
    @AppStorage(Prefs.aeroKey) private var aeroButtons = true
    @AppStorage(Prefs.catchAllKey) private var catchAll = true
    @AppStorage(Prefs.hotkeyKey) private var hotkey: HotKeyChoice = .ctrlOptS
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tote").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            Picker("Corner", selection: $corner) {
                ForEach(Corner.allCases) { c in
                    Text(c.label).tag(c)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Gap from screen edge: \(Int(margin)) px")
                    .font(.callout)
                Slider(value: $margin, in: 0...60, step: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Also hold text, links and images", isOn: $catchAll)
                Text("Turn this off if Tote pops up too often. Files are always held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Lite mode", isOn: $liteMode)
                Text("No previews or file details. Tote never opens your files, so macOS won't ask for folder access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Keep items after dragging out", isOn: $keepItems)

            VStack(alignment: .leading, spacing: 2) {
                if AeroSpace.isAvailable {
                    Toggle("AeroSpace workspace buttons", isOn: $aeroButtons)
                    Text("Drop something on a workspace button to switch there with it in hand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Workspace buttons appear automatically if AeroSpace is installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Picker("Show/hide shortcut", selection: $hotkey) {
                    ForEach(HotKeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .onChange(of: hotkey) { _, _ in
                    HotKeyManager.shared.reload()
                }
                if hotKeys.registrationFailed {
                    Text("Another app is already using that shortcut. Pick a different one.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("Launch at login failed: \(error)")
                    }
                }

            Divider()

            HStack {
                Button("Clear all") { model.clear() }
                    .disabled(model.items.isEmpty)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

// MARK: - Window management

// Watches for drags anywhere and manages the floating panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?
    private var panel: NSPanel?
    private let dragBoard = NSPasteboard(name: .drag)
    private lazy var lastChangeCount = dragBoard.changeCount

    private let panelWidth: CGFloat = 260

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        TempStore.clearAll()

        ShelfModel.shared.onChange = { [weak self] in
            self?.itemsChanged()
        }

        HotKeyManager.shared.onPress = { [weak self] in
            self?.togglePanel()
        }
        HotKeyManager.shared.reload()

        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempStore.clearAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            let count = dragBoard.changeCount
            if count != lastChangeCount {
                lastChangeCount = count
                if dragIsInteresting() && Prefs.enabled { showPanel() }
            }
        case .leftMouseUp:
            // Hide only if the shelf is empty and the mouse isn't over it.
            if let panel,
               ShelfModel.shared.items.isEmpty,
               !panel.frame.contains(NSEvent.mouseLocation) {
                panel.orderOut(nil)
            }
        default:
            break
        }
    }

    // Files always count. Text, links and images count if that setting is on.
    private func dragIsInteresting() -> Bool {
        if Prefs.catchAll {
            return dragBoard.canReadObject(
                forClasses: [NSURL.self, NSString.self, NSImage.self],
                options: nil
            )
        }
        return dragBoard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    // The global shortcut: show the shelf if it's hidden, hide it if it's showing.
    func togglePanel() {
        guard Prefs.enabled else { return }
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            showPanel()
        }
    }

    // The shelf hides when it becomes empty, and resizes as items change.
    private func itemsChanged() {
        if ShelfModel.shared.items.isEmpty {
            panel?.orderOut(nil)
        } else {
            resizePanel()
        }
    }

    // Empty = small drop zone. With items = up to 4 rows, then it scrolls.
    // If AeroSpace workspace buttons are showing, there is one extra row.
    private func panelHeight() -> CGFloat {
        let count = ShelfModel.shared.items.count
        let body: CGFloat = count == 0 ? 120 : 44 + 48 * CGFloat(min(count, 4))
        let bar: CGFloat = ShelfModel.shared.workspaces.isEmpty ? 0 : 32
        return body + bar
    }

    // Bottom corners grow upward, top corners grow downward.
    private func resizePanel() {
        guard let panel else { return }
        let height = panelHeight()
        var frame = panel.frame
        let oldTop = frame.maxY
        frame.size = NSSize(width: panelWidth, height: height)
        if Prefs.corner.isTop { frame.origin.y = oldTop - height }
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    private func showPanel() {
        // In lite mode we never touch the files, so skip the existence check.
        if !Prefs.lite { ShelfModel.shared.prune() }

        // Refresh the AeroSpace workspace list, then resize to fit it.
        Task { @MainActor [weak self] in
            await ShelfModel.shared.refreshWorkspaces()
            self?.resizePanel()
        }

        // Already visible? Leave it where it is (don't move it mid-drag).
        if panel?.isVisible == true { return }

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let hosting = NSHostingView(rootView: ShelfView())
            hosting.unregisterDraggedTypes()   // the container below handles drops
            p.contentView = ShelfContainerView(content: hosting)
            panel = p
        }

        // Place it in the chosen corner of the screen the mouse is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame, let panel {
            let corner = Prefs.corner
            let margin = Prefs.margin
            let height = panelHeight()
            let x = corner.isRight ? area.maxX - panelWidth - margin : area.minX + margin
            let y = corner.isTop ? area.maxY - height - margin : area.minY + margin
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
        }

        // Quick fade-in.
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        panel?.animator().alphaValue = 1
    }
}

// MARK: - Shelf panel UI

struct ShelfView: View {
    @ObservedObject private var model = ShelfModel.shared
    @AppStorage(Prefs.keepKey) private var keepItems = false
    @AppStorage(Prefs.catchAllKey) private var catchAll = true

    var body: some View {
        VStack(spacing: 6) {
            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 26, weight: .light))
                    Text(catchAll ? "Drop files, links or text" : "Drop files here")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    Text(model.items.count == 1 ? "1 item" : "\(model.items.count) items")

                    Spacer()

                    // With 2+ items you can grab them all in one drag.
                    if model.items.count > 1 {
                        Text("Drag all")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .overlay(
                                DragHandle(
                                    items: model.items,
                                    image: nil,
                                    onClick: nil,
                                    onFinished: { accepted in
                                        if accepted && !keepItems { model.clear() }
                                    }
                                )
                            )
                    }

                    Button("Clear") { model.clear() }
                        .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.items) { item in
                            ShelfRow(item: item)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: model.items)
                }
                .scrollIndicators(.hidden)
            }

            // AeroSpace workspace buttons (only when AeroSpace is available).
            if !model.workspaces.isEmpty {
                WorkspaceBar()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    model.dropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                    lineWidth: model.dropTargeted ? 2 : 1
                )
        )
        // Drops are handled by ShelfContainerView (AppKit), which needs to
        // know where the workspace buttons are.
        .coordinateSpace(.named("shelfPanel"))
        .onPreferenceChange(ChipFramesKey.self) { frames in
            Task { @MainActor in ShelfModel.shared.chipFrames = frames }
        }
    }
}

// A row of buttons, one per AeroSpace workspace.
struct WorkspaceBar: View {
    @ObservedObject private var model = ShelfModel.shared

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.workspaces, id: \.self) { name in
                    WorkspaceChip(name: name, isFocused: name == model.focusedWorkspace)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 26)
    }
}

// Click to switch workspace. (Dropping on it is handled by ShelfContainerView
// below, which looks up this button's position.)
struct WorkspaceChip: View {
    let name: String
    let isFocused: Bool
    @ObservedObject private var model = ShelfModel.shared

    var body: some View {
        Button {
            Task { await ShelfModel.shared.switchWorkspace(name) }
        } label: {
            Text(name)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 3)
                .background(
                    isFocused
                        ? Color.accentColor.opacity(0.35)
                        : Color.primary.opacity(model.hoveredChip == name ? 0.3 : 0.08),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChipFramesKey.self,
                    value: [name: proxy.frame(in: .named("shelfPanel"))]
                )
            }
        )
    }
}

// Collects each workspace button's position inside the panel.
struct ChipFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// The single place that receives drops for the whole panel. It decides whether
// the drop landed on a workspace button or on the shelf itself.
final class ShelfContainerView: NSView {
    init(content: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 120))
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // Which workspace button (if any) is under the dragged item?
    private func chip(at sender: NSDraggingInfo) -> String? {
        let p = convert(sender.draggingLocation, from: nil)
        // SwiftUI measures from the top-left, AppKit from the bottom-left.
        let point = CGPoint(x: p.x, y: bounds.height - p.y)
        return ShelfModel.shared.chipFrames.first { $0.value.contains(point) }?.key
    }

    private func updateTargets(_ sender: NSDraggingInfo) {
        let name = chip(at: sender)
        ShelfModel.shared.hoveredChip = name
        ShelfModel.shared.dropTargeted = (name == nil)
    }

    private func clearTargets() {
        ShelfModel.shared.hoveredChip = nil
        ShelfModel.shared.dropTargeted = false
    }

    // The shelf only keeps references or copies, so ask the source for a plain
    // copy (this stops Finder from moving the original file).
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTargets(sender)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTargets(sender)
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearTargets()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearTargets()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let chipName = chip(at: sender)
        clearTargets()

        let newItems = PasteboardReader.items(from: sender.draggingPasteboard)
        guard !newItems.isEmpty else { return false }

        for item in newItems { ShelfModel.shared.add(item) }

        // Dropped on a workspace button: jump to that workspace too.
        if let chipName {
            Task { await ShelfModel.shared.switchWorkspace(chipName) }
        }
        return true
    }
}

// One item on the shelf: icon, title, details, hover button, draggable.
struct ShelfRow: View {
    let item: ShelfItem
    @AppStorage(Prefs.liteKey) private var liteMode = false
    @AppStorage(Prefs.keepKey) private var keepItems = false
    @State private var thumbnail: NSImage?
    @State private var detail = ""
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Left part (icon + text) is the drag handle.
            HStack(spacing: 10) {
                iconView

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(
                DragHandle(
                    items: [item],
                    image: dragThumbnail,
                    onClick: previewAction,
                    onFinished: { accepted in
                        // Dropped somewhere that accepted it: take it off the shelf.
                        if accepted && !keepItems { ShelfModel.shared.remove(item) }
                    }
                )
            )

            actionButton

            hoverButton(symbol: "xmark.circle.fill", help: "Remove") {
                ShelfModel.shared.remove(item)
            }
        }
        .padding(6)
        .background(
            Color.primary.opacity(hovering ? 0.10 : 0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .onHover { hovering = $0 }
        .task(id: liteMode) {
            // Previews are for files only, and never in lite mode.
            guard case .file(let url) = item.kind, !liteMode else { return }
            loadDetail(for: url)
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 64, height: 64),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = rep.nsImage
            }
        }
    }

    // MARK: pieces of the row

    private var title: String {
        switch item.kind {
        case .file(let url): return url.lastPathComponent
        case .link(let url): return url.host ?? url.absoluteString
        case .text(let text): return text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    private var subtitle: String {
        switch item.kind {
        case .file: return liteMode ? "" : detail
        case .link(let url): return url.absoluteString
        case .text(let text): return text.count == 1 ? "Text · 1 character" : "Text · \(text.count) characters"
        }
    }

    // Clicking a file opens Quick Look (not in lite mode, which never opens files).
    private var previewAction: (() -> Void)? {
        guard case .file(let url) = item.kind, !liteMode else { return nil }
        return {
            let files: [URL] = ShelfModel.shared.items.compactMap { other in
                if case .file(let fileURL) = other.kind { return fileURL }
                return nil
            }
            PreviewController.shared.show(url, among: files)
        }
    }

    private var dragThumbnail: NSImage? {
        if case .file = item.kind, !liteMode { return thumbnail }
        return nil
    }

    @ViewBuilder
    private var iconView: some View {
        switch item.kind {
        case .file(let url):
            Image(nsImage: (liteMode ? nil : thumbnail) ?? fileIcon(for: url, lite: liteMode))
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .link:
            symbolTile("link")
        case .text:
            symbolTile("text.alignleft")
        }
    }

    private func symbolTile(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // File: show in Finder. Link: open in browser. Text: copy.
    @ViewBuilder
    private var actionButton: some View {
        switch item.kind {
        case .file(let url):
            hoverButton(symbol: "magnifyingglass.circle.fill", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .link(let url):
            hoverButton(symbol: "arrow.up.right.circle.fill", help: "Open in browser") {
                NSWorkspace.shared.open(url)
            }
        case .text(let text):
            hoverButton(symbol: "doc.on.doc.fill", help: "Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func hoverButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .help(help)
    }

    private func loadDetail(for url: URL) {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        var parts: [String] = []
        if let type = values.localizedTypeDescription { parts.append(type) }
        if let size = values.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        detail = parts.joined(separator: " · ")
    }
}

// MARK: - Drag source

// SwiftUI's built-in drag can't tell us whether a drop succeeded, so this small
// AppKit view starts the drag itself (one item or many) and reports back.
struct DragHandle: NSViewRepresentable {
    let items: [ShelfItem]
    let image: NSImage?
    let onClick: (() -> Void)?
    let onFinished: (Bool) -> Void

    func makeNSView(context: Context) -> DragSourceNSView {
        DragSourceNSView()
    }

    func updateNSView(_ view: DragSourceNSView, context: Context) {
        view.items = items
        view.dragImage = image
        view.onClick = onClick
        view.onFinished = onFinished
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    var items: [ShelfItem] = []
    var dragImage: NSImage?
    var onClick: (() -> Void)?
    var onFinished: ((Bool) -> Void)?

    private var mouseDownLocation: NSPoint?
    private var didStartDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didStartDrag = false
    }

    // A press and release without dragging counts as a click.
    override func mouseUp(with event: NSEvent) {
        if !didStartDrag { onClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, !items.isEmpty, let start = mouseDownLocation else { return }
        let now = event.locationInWindow
        // Ignore tiny wobbles so a simple click doesn't start a drag.
        if hypot(now.x - start.x, now.y - start.y) < 4 { return }
        didStartDrag = true

        let lite = Prefs.lite
        let size: CGFloat = 44
        let location = convert(event.locationInWindow, from: nil)

        var draggingItems: [NSDraggingItem] = []
        for (index, item) in items.enumerated() {
            // Fan multiple items out slightly so it looks like a stack.
            let offset = CGFloat(min(index, 4)) * 6
            let frame = NSRect(
                x: location.x - size / 2 + offset,
                y: location.y - size / 2 - offset,
                width: size,
                height: size
            )
            let image = (items.count == 1 ? dragImage : nil) ?? dragIcon(for: item, lite: lite)
            let draggingItem = NSDraggingItem(pasteboardWriter: item.makeWriter())
            draggingItem.setDraggingFrame(frame, contents: image)
            draggingItems.append(draggingItem)
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    // Allow copy and move, so it behaves like a normal drag (hold Option to copy).
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // Dropping back onto the shelf itself doesn't count as "used".
        let droppedOnShelf = window?.frame.contains(screenPoint) ?? false
        onFinished?(!operation.isEmpty && !droppedOnShelf)
    }
}
