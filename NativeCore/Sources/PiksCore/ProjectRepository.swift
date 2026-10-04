import Foundation

/// All filesystem operations run on the caller's IO queue, never the UI thread.
public final class ProjectRepository: @unchecked Sendable {
    public enum AssetMode { case original, proxy }
    public enum Usage { case preview, export }
    public let directory: URL
    private let lock = NSRecursiveLock()
    private let files = FileManager.default
    public init(root: URL, owner: UUID?) throws {
        directory = root.appendingPathComponent(owner?.uuidString ?? "guest", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        #if !os(Linux)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        #endif
    }
    public func projectURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func save(_ project: Project) throws {
        lock.lock(); defer { lock.unlock() }
        try project.validate()
        let location = projectURL(project.id)
        let manifest = location.appendingPathComponent("project.json")
        let backup = location.appendingPathComponent("previous.json")
        if let saved = try? load(project.id) {
            if saved == project { return }
            guard saved.revision < project.revision else { throw EditorError.staleRevision }
            if files.fileExists(atPath: manifest.path), (try? decode(manifest)) != nil {
                try Data(contentsOf: manifest).write(to: backup, options: .atomic)
            }
        }
        try files.createDirectory(at: location, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(project).write(to: manifest, options: .atomic)
    }
    private func decode(_ url: URL) throws -> Project {
        let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
        try p.validate(); return p
    }
    public func load(_ id: UUID) throws -> Project {
        lock.lock(); defer { lock.unlock() }
        let location = projectURL(id)
        var firstError: Error = EditorError.missingProject
        for name in ["project.json", "previous.json"] {
            do {
                let p = try decode(location.appendingPathComponent(name))
                guard p.id == id else { throw EditorError.invalid("Идентификатор проекта повреждён.") }
                return p
            } catch { if name == "project.json" { firstError = error } }
        }
        throw firstError
    }
    public func catalog() throws -> [Project] {
        lock.lock(); defer { lock.unlock() }
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url in UUID(uuidString: url.lastPathComponent).flatMap { try? load($0) } }
            .sorted { $0.modified > $1.modified }
    }
    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try files.removeItem(at: projectURL(id))
    }
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if UUID(uuidString: url.lastPathComponent) != nil { try files.removeItem(at: url) }
        }
    }
    public func assetURL(project: UUID, asset: MediaAsset, mode: AssetMode) throws -> URL {
        let dir = projectURL(project).appendingPathComponent(mode == .original ? "originals" : "proxies", isDirectory: true)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = mode == .proxy ? "mp4" : asset.fileExtension
        return dir.appendingPathComponent(asset.id.uuidString + "." + ext)
    }
    public func resolve(project: UUID, asset: MediaAsset, usage: Usage) throws -> URL {
        if usage == .preview && asset.kind == .video {
            let proxy = try assetURL(project: project, asset: asset, mode: .proxy)
            if files.fileExists(atPath: proxy.path) { return proxy }
        }
        let original = try assetURL(project: project, asset: asset, mode: .original)
        guard files.fileExists(atPath: original.path) else { throw EditorError.missingOriginal }
        return original
    }
}
