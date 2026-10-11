#if canImport(Nitrakit)
import Nitrakit
#endif
import CryptoKit
import Foundation

/// Where a media id's file is.
public enum MediaLocation: Sendable {
    /// A file on this device.
    case file(URL)
    /// A URL to download (signed or not). The SDK downloads it into its cache.
    case remote(URL)
}

/// The asset layer: makes media ids available as local files for the engine. Your app says
/// where an id lives (`resolve`); the SDK downloads it, shows progress on its clips and keeps
/// it in its cache.
public enum NitrakitMedia {
    /// Your lookup from a media id to its file, e.g. a signed URL from your backend. Set it
    /// once, at start-up. Without it, media stays on the device where it was added.
    nonisolated(unsafe) public static var resolve: (@Sendable (String) async throws -> MediaLocation)?

    /// Your lookup from a font family to its file (a TTF / OTF URL, e.g. on your CDN, or a local
    /// file). The SDK asks when text needs a font this device doesn't have, downloads it once
    /// and keeps it. Set it once, at start-up.
    nonisolated(unsafe) public static var resolveFont: (@Sendable (String) async throws -> MediaLocation)? {
        didSet { FontLoader.shared.start() }
    }
}

extension Editor {
    /// Adds a local file to the project as a new source, under your id for it (e.g. the id of
    /// the file in your storage). The project refers to it only by that id. The file is copied
    /// into the SDK's media folder.
    @discardableResult
    public func addMedia(id: String = UUID().uuidString, file: URL, name: String? = nil) throws -> MediaInfo {
        let local = try MediaFiles.keep(id: id, from: file)
        return try importMedia(id: id, path: local.path, name: name ?? file.lastPathComponent)
    }

    /// Makes the project's media available, after opening a saved project: files already on
    /// the device right away, the rest through `NitrakitMedia.resolve` in the background, with
    /// progress on their clips (or marked missing).
    public func loadMedia() {
        for id in mediaIds() { MediaLoader.shared.load(id, for: self) }
    }

    /// Asks `NitrakitMedia.resolve` again for a media id (or every missing one).
    public func retryMedia(id: String? = nil) {
        for i in mediaIds() where id == nil || i == id { MediaLoader.shared.load(i, for: self, retry: true) }
    }

    /// Shows progress (0–1) on a media id's clips, e.g. while your app uploads it; `nil` when done.
    public func setMediaProgress(id: String, fraction: Double?) {
        if let fraction {
            setMediaState(id: id, state: .loading(progress: Float(fraction)))
        } else {
            setMediaState(id: id, state: MediaFiles.find(id) != nil ? .ready : .missing)
        }
    }
}

/// Media files by id: a durable folder for media added on this device (the user's own files),
/// a purgeable cache for downloads (the app's storage has those).
enum MediaFiles {
    static func folder(durable: Bool) -> URL {
        let base = FileManager.default.urls(for: durable ? .applicationSupportDirectory : .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("nitrakit-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func key(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func find(_ id: String) -> URL? {
        let k = key(id)
        for durable in [true, false] {
            let dir = folder(durable: durable)
            if let name = try? FileManager.default.contentsOfDirectory(atPath: dir.path).first(where: { $0.hasPrefix(k) }) {
                return dir.appendingPathComponent(name)
            }
        }
        return nil
    }

    static func destination(_ id: String, ext: String, durable: Bool = false) -> URL {
        let name = ext.isEmpty ? key(id) : "\(key(id)).\(ext)"
        return folder(durable: durable).appendingPathComponent(name)
    }

    /// The file for `id`: on the device, else resolved and downloaded.
    static func fetch(_ id: String) async throws -> URL {
        if let local = find(id) { return local }
        guard let resolve = NitrakitMedia.resolve else { throw URLError(.fileDoesNotExist) }
        switch try await resolve(id) {
        case .file(let url):
            return try keep(id: id, from: url)
        case .remote(let url):
            let tmp = try await Download(progress: { _ in }).run(url)
            let to = destination(id, ext: url.pathExtension)
            if let old = find(id) { try? FileManager.default.removeItem(at: old) }
            try FileManager.default.moveItem(at: tmp, to: to)
            return to
        }
    }

    static func keep(id: String, from file: URL) throws -> URL {
        // Already the SDK's file for this id (e.g. a download): stays where it is.
        if let existing = find(id), existing.standardizedFileURL == file.standardizedFileURL { return existing }
        let to = destination(id, ext: file.pathExtension, durable: true)
        if to.standardizedFileURL == file.standardizedFileURL { return to }
        let fm = FileManager.default
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        if let old = find(id) { try? fm.removeItem(at: old) }
        try fm.copyItem(at: file, to: to)
        return to
    }
}

/// Fetches media ids for editors, one download per id at a time.
final class MediaLoader: @unchecked Sendable {
    static let shared = MediaLoader()
    private let lock = NSLock()
    private var running = Set<String>()

    func load(_ id: String, for editor: Editor, retry: Bool = false) {
        if !retry, let local = MediaFiles.find(id) {
            editor.setMediaLocation(id: id, path: local.path)
            return
        }
        lock.lock()
        let started = running.insert(id).inserted
        lock.unlock()
        guard started else { return }
        editor.setMediaState(id: id, state: .loading(progress: -1))
        let ref = EditorRef(editor)
        Task.detached {
            let editor = ref.editor
            defer { self.finished(id) }
            do {
                guard let resolve = NitrakitMedia.resolve else { throw URLError(.fileDoesNotExist) }
                let file: URL
                switch try await resolve(id) {
                case .file(let url):
                    file = url
                case .remote(let url):
                    file = try await Self.download(url, id: id) { p in
                        ref.editor?.setMediaState(id: id, state: .loading(progress: p))
                    }
                }
                editor?.setMediaLocation(id: id, path: file.path)
            } catch {
                NSLog("Nitrakit: media %@: %@", id, String(describing: error))
                editor?.setMediaState(id: id, state: .missing)
            }
        }
    }

    private func finished(_ id: String) {
        lock.lock()
        running.remove(id)
        lock.unlock()
    }

    private static func download(_ url: URL, id: String, progress: @escaping @Sendable (Float) -> Void) async throws -> URL {
        let tmp = try await Download(progress: progress).run(url)
        let to = MediaFiles.destination(id, ext: url.pathExtension)
        if let old = MediaFiles.find(id) { try? FileManager.default.removeItem(at: old) }
        try FileManager.default.moveItem(at: tmp, to: to)
        return to
    }
}

private final class EditorRef: @unchecked Sendable {
    weak var editor: Editor?
    init(_ editor: Editor) { self.editor = editor }
}

/// One download with progress, into a temporary file.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Float) -> Void
    private var done: CheckedContinuation<URL, Error>?

    init(progress: @escaping @Sendable (Float) -> Void) {
        self.progress = progress
    }

    func run(_ url: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            done = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten got: Int64, totalBytesExpectedToWrite total: Int64) {
        progress(total > 0 ? Float(got) / Float(total) : -1)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            done?.resume(throwing: URLError(.badServerResponse))
        } else {
            // The file is deleted when this returns: move it first.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: keep)
                done?.resume(returning: keep)
            } catch {
                done?.resume(throwing: error)
            }
        }
        done = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { done?.resume(throwing: error) }
        done = nil
    }
}

/// Fonts by family: cached files registered at start, the rest resolved when text needs them.
final class FontLoader: FontListener, @unchecked Sendable {
    static let shared = FontLoader()
    private let lock = NSLock()
    private var started = false

    static var folder: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nitrakit-fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for f in files { _ = try? registerFont(path: f.path) }
        setFontListener(listener: self)
    }

    func fontNeeded(family: String) {
        Task.detached {
            do {
                guard let resolve = NitrakitMedia.resolveFont else { return }
                let file: URL
                switch try await resolve(family) {
                case .file(let url):
                    file = url
                case .remote(let url):
                    let tmp = try await Download(progress: { _ in }).run(url)
                    let ext = url.pathExtension.isEmpty ? "ttf" : url.pathExtension
                    file = Self.folder.appendingPathComponent("\(MediaFiles.key(family)).\(ext)")
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: tmp, to: file)
                }
                _ = try registerFont(path: file.path)
            } catch {
                NSLog("Nitrakit: font %@: %@", family, String(describing: error))
            }
        }
    }
}
