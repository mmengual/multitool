import AppKit
import Combine
import CryptoKit

/// One entry of the clipboard history.
struct ClipboardItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, files }

    let id: UUID
    var date: Date
    let kind: Kind
    /// Plain text for `.text`; file names for `.files`.
    var text: String?
    /// Rich text kept alongside the plain text, when the source offered it.
    var rtf: Data?
    var filePaths: [String]?
    /// File name inside the store's image folder.
    var imageFile: String?
    var imageWidth: Double?
    var imageHeight: Double?
    var sourceBundleID: String?
    var sourceAppName: String?
    var pinned: Bool
    /// Content fingerprint, used to merge duplicates.
    let hash: String

    /// One-line label for lists.
    var title: String {
        switch kind {
        case .text:
            let flat = (text ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .prefix(40).joined(separator: " ")
            return flat.isEmpty ? "Espaces seuls" : flat
        case .image:
            if let w = imageWidth, let h = imageHeight { return "Image \(Int(w)) × \(Int(h))" }
            return "Image"
        case .files:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            if names.count <= 1 { return names.first ?? "Fichier" }
            return "\(names[0]) + \(names.count - 1) autre(s)"
        }
    }

    func matches(_ query: String) -> Bool {
        if query.isEmpty { return true }
        let haystack = [text, sourceAppName, filePaths?.joined(separator: " ")]
            .compactMap { $0 }.joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }
}

/// The history, persisted as JSON in ~/Library/Application Support/Multitool/Clipboard.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipboardItem] = []

    private let directory = AppInfo.supportDirectory("Clipboard")
    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var imagesURL: URL {
        let url = directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var saveWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        load()
        prune()
        let s = Settings.shared
        s.$clipboardMaxItems.combineLatest(s.$clipboardRetentionDays)
            .dropFirst()
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.prune() } }
            .store(in: &cancellables)
    }

    var pinned: [ClipboardItem] { items.filter(\.pinned) }
    var recent: [ClipboardItem] { items.filter { !$0.pinned } }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imageFile.map { imagesURL.appendingPathComponent($0) }
    }

    // MARK: Capture

    func addText(_ text: String, rtf: Data?, source: NSRunningApplication?) {
        let hash = Self.digest(Data(text.utf8))
        insert(ClipboardItem(id: UUID(), date: Date(), kind: .text, text: text,
                             rtf: (rtf?.count ?? 0) <= 512_000 ? rtf : nil,
                             sourceBundleID: source?.bundleIdentifier,
                             sourceAppName: source?.localizedName, pinned: false, hash: hash))
    }

    func addFiles(_ urls: [URL], source: NSRunningApplication?) {
        let paths = urls.map(\.path)
        let hash = Self.digest(Data(paths.joined(separator: "\n").utf8))
        insert(ClipboardItem(id: UUID(), date: Date(), kind: .files,
                             text: urls.map(\.lastPathComponent).joined(separator: "\n"),
                             filePaths: paths, sourceBundleID: source?.bundleIdentifier,
                             sourceAppName: source?.localizedName, pinned: false, hash: hash))
    }

    func addImage(png: Data, size: CGSize, source: NSRunningApplication?) {
        let hash = Self.digest(png)
        if bumpExisting(hash: hash) { return }
        let name = "\(UUID().uuidString).png"
        do {
            try png.write(to: imagesURL.appendingPathComponent(name), options: .atomic)
        } catch {
            Log.clipboard.error("image write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        insert(ClipboardItem(id: UUID(), date: Date(), kind: .image, imageFile: name,
                             imageWidth: size.width, imageHeight: size.height,
                             sourceBundleID: source?.bundleIdentifier,
                             sourceAppName: source?.localizedName, pinned: false, hash: hash))
    }

    private func insert(_ item: ClipboardItem) {
        if bumpExisting(hash: item.hash) { return }
        items.insert(item, at: 0)
        prune()
        scheduleSave()
    }

    /// Copying something already in the history moves it back to the top.
    private func bumpExisting(hash: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.hash == hash }) else { return false }
        var existing = items.remove(at: index)
        existing.date = Date()
        items.insert(existing, at: 0)
        scheduleSave()
        return true
    }

    // MARK: Editing

    func touch(_ item: ClipboardItem) { _ = bumpExisting(hash: item.hash) }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        scheduleSave()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        removeFiles(of: [item])
        scheduleSave()
    }

    /// Clears the history. Pinned items survive unless `includingPinned`.
    func clear(includingPinned: Bool = false) {
        let removed = items.filter { includingPinned || !$0.pinned }
        items.removeAll { includingPinned || !$0.pinned }
        removeFiles(of: removed)
        scheduleSave()
    }

    // MARK: Retention

    func prune() {
        let s = Settings.shared
        var kept: [ClipboardItem] = []
        var removed: [ClipboardItem] = []
        let cutoff = s.clipboardRetentionDays > 0
            ? Date().addingTimeInterval(-Double(s.clipboardRetentionDays) * 86_400) : nil
        var unpinnedCount = 0
        for item in items {
            if item.pinned { kept.append(item); continue }
            if let cutoff, item.date < cutoff { removed.append(item); continue }
            unpinnedCount += 1
            if unpinnedCount > s.clipboardMaxItems { removed.append(item); continue }
            kept.append(item)
        }
        guard !removed.isEmpty else { return }
        items = kept
        removeFiles(of: removed)
        scheduleSave()
    }

    private func removeFiles(of removed: [ClipboardItem]) {
        for item in removed {
            if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        do {
            items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            Log.clipboard.error("history unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: historyURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            Log.clipboard.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
