import Foundation
import AVFoundation
import UIKit
import ImageIO
import PiksCore

actor MediaLibrary {
    let repository: ProjectRepository
    private var proxies: [UUID: Task<URL, Error>] = [:]
    init(repository: ProjectRepository) { self.repository = repository }

    func importFile(_ source: URL, project: UUID) async throws -> MediaAsset {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        let image = ["jpg", "jpeg", "png", "heic", "heif"].contains(ext)
        var metadata: MediaAsset
        if image {
            guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(sourceImage, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int else { throw EditorError.invalid("Изображение не читается.") }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            metadata = MediaAsset(kind: .image, originalName: source.lastPathComponent, duration: 0,
                                  width: orientation >= 5 ? h : w, height: orientation >= 5 ? w : h)
        } else {
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw EditorError.invalid("Файл пустой или повреждён.") }
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            if let video {
                let size = try await video.load(.naturalSize)
                let transform = try await video.load(.preferredTransform)
                let shown = CGRect(origin: .zero, size: size).applying(transform)
                let rate = try await video.load(.nominalFrameRate)
                metadata = MediaAsset(kind: .video, originalName: source.lastPathComponent, duration: duration,
                                      width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                                      hasAudio: audio != nil, frameRate: Double(rate))
            } else if audio != nil {
                metadata = MediaAsset(kind: .audio, originalName: source.lastPathComponent, duration: duration,
                                      width: 0, height: 0, hasAudio: true)
            } else { throw EditorError.invalid("В файле нет видео или звука.") }
        }
        let target = try repository.assetURL(project: project, asset: metadata, mode: .original)
        // A separate temporary name prevents partially copied originals becoming visible.
        let partial = target.appendingPathExtension("importing")
        do {
            try FileManager.default.copyItem(at: source, to: partial)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: target)
            var local = target; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try local.setResourceValues(values)
            return metadata
        } catch {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func proxy(for asset: MediaAsset, project: UUID) async throws -> URL {
        let original = try repository.resolve(project: project, asset: asset, usage: .export)
        guard asset.kind == .video, min(asset.width, asset.height) > 1080 else { return original }
        let output = try repository.assetURL(project: project, asset: asset, mode: .proxy)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        if let task = proxies[asset.id] { return try await task.value }
        let task = Task<URL, Error> {
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPreset1920x1080) else {
                throw EditorError.invalid("Не удалось создать копию для монтажа.")
            }
            let partial = output.deletingPathExtension().appendingPathExtension("partial.mp4")
            try? FileManager.default.removeItem(at: partial)
            session.outputURL = partial; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
            do {
                try await withTaskCancellationHandler(operation: {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        session.exportAsynchronously {
                            if session.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: session.error ?? CancellationError()) }
                        }
                    }
                }, onCancel: { session.cancelExport() })
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: partial, to: output)
                return output
            } catch { try? FileManager.default.removeItem(at: partial); throw error }
        }
        proxies[asset.id] = task
        defer { proxies[asset.id] = nil }
        return try await task.value
    }

    func thumbnail(for asset: MediaAsset, project: UUID, at time: Double = 0, size: CGSize = CGSize(width: 160, height: 160)) async throws -> UIImage {
        let source = try repository.resolve(project: project, asset: asset, usage: .preview)
        if asset.kind == .image {
            guard let dataSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(dataSource, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                     kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)] as CFDictionary) else {
                throw EditorError.invalid("Миниатюра не создаётся.")
            }
            return UIImage(cgImage: image)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = size
        let cg = try await generator.image(at: CMTime(seconds: min(time, max(0, asset.duration - 0.01)), preferredTimescale: 600)).image
        return UIImage(cgImage: cg)
    }
    func cancelProxies() { for task in proxies.values { task.cancel() }; proxies.removeAll() }

    func discard(_ asset: MediaAsset, project: UUID) {
        // Only a new asset that was not accepted into the project may be discarded.
        for mode in [ProjectRepository.AssetMode.original, .proxy] {
            if let url = try? repository.assetURL(project: project, asset: asset, mode: mode) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
