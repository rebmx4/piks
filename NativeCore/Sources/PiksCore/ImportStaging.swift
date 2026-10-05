import Foundation

/// Own only copies explicitly created by the picker; external file URLs are never deleted.
public final class ImportStaging: @unchecked Sendable {
    public static let shared = ImportStaging(root: FileManager.default.temporaryDirectory.appendingPathComponent("piks-picker", isDirectory: true))
    private let root: URL
    private let lock = NSLock()
    private var owned = Set<URL>()
    public init(root: URL) { self.root = root.standardizedFileURL }
    public func copy(_ source: URL) throws -> URL {
        guard source.isFileURL,
              (try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw EditorError.invalid("Выберите обычный видео-, аудио- или фотофайл.")
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = folder.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: source, to: target) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
        lock.lock(); owned.insert(target); lock.unlock()
        return target
    }
    public func remove(_ files: [URL]) {
        for file in files {
            let target = file.standardizedFileURL
            lock.lock(); let isOwned = owned.remove(target) != nil; lock.unlock()
            guard isOwned else { continue }
            try? FileManager.default.removeItem(at: target)
            let folder = target.deletingLastPathComponent()
            if folder.deletingLastPathComponent().pathComponents == root.pathComponents,
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
