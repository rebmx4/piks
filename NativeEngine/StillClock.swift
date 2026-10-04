import AVFoundation
import CoreVideo

/// A tiny local clock track drives composition requests during photos and gaps.
/// It never enters the visible layers and needs no bundled external media.
enum StillClock {
    private static let lock = NSLock()
    static func movie() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("piks-native-clock-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError("Не удалось создать дорожку фото.") }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let pixel = buffer else { throw ExportError("Не хватает памяти для кадра.") }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let bytes = CVPixelBufferGetBaseAddress(pixel) {
            memset(bytes, 0, CVPixelBufferGetBytesPerRow(pixel) * 16)
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for frame in 0..<2 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { usleep(1000) }
            guard input.isReadyForMoreMediaData, adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)) else {
                writer.cancelWriting(); try? FileManager.default.removeItem(at: url)
                throw writer.error ?? ExportError("Дорожка фото не записалась.")
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        let complete = DispatchSemaphore(value: 0)
        writer.finishWriting { complete.signal() }
        guard complete.wait(timeout: .now() + 15) == .success, writer.status == .completed else {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: url)
            throw writer.error ?? ExportError("Дорожка фото не завершилась.")
        }
        return url
    }
}
