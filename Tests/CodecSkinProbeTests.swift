import XCTest
import AVFoundation
import CoreImage
import UIKit
import MediaPipeTasksVision

// Characterize the two new prerequisites. Passing on Simulator does not prove
// speed or original-file compatibility on the owner's physical iPhone.
final class CodecSkinProbeTests: XCTestCase {
    func testNativeDecoderReadsHigh422TenBit4KFrames() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "high422-10bit-probe", withExtension: "mp4", subdirectory: "ProbeInputs"))
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: 3840, height: 2160))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        XCTAssertTrue(reader.canAdd(output)); reader.add(output)
        XCTAssertTrue(reader.startReading(), String(describing: reader.error))
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 3840)
            XCTAssertEqual(CVPixelBufferGetHeight(buffer), 2160)
            frames += 1
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(frames, 6)
        print("APIKS_CODEC_PROBE frames=\(frames) size=3840x2160 expected=High422/10bit")
    }

    func testPinnedSkinModelRunsOnTheNativeCPUWithPublicInput() throws {
        let bundle = Bundle(for: Self.self)
        let model = try XCTUnwrap(bundle.url(forResource: "selfie_multiclass_256x256",
            withExtension: "tflite", subdirectory: "ProbeInputs"))
        let imageURL = try XCTUnwrap(bundle.url(forResource: "portrait", withExtension: "jpg",
            subdirectory: "ProbeInputs"))
        let original = try XCTUnwrap(UIImage(contentsOfFile: imageURL.path))
        let scale = 360 / max(original.size.width, original.size.height)
        let size = CGSize(width: (original.size.width * scale).rounded(),
                          height: (original.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let input = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        }
        let options = ImageSegmenterOptions()
        options.baseOptions.modelAssetPath = model.path
        options.baseOptions.delegate = .CPU
        options.runningMode = .image
        options.outputCategoryMask = true
        options.outputConfidenceMasks = false
        let segmenter = try ImageSegmenter(options: options)
        let image = try MPImage(uiImage: input)
        let began = CFAbsoluteTimeGetCurrent()
        let result = try segmenter.segment(image: image)
        let mask = try XCTUnwrap(result.categoryMask)
        let categories = Array(UnsafeBufferPointer(start: mask.uint8Data, count: mask.width * mask.height))
        XCTAssertEqual(mask.width, 256); XCTAssertEqual(mask.height, 256)
        XCTAssertTrue(categories.allSatisfy { $0 <= 5 })
        XCTAssertGreaterThan(categories.filter { $0 == 2 || $0 == 3 }.count, 100,
            "Public portrait must produce actual skin, not a missing/all-zero result")
        let attachments: [(String, Data)] = [
            ("skin-input.png", try XCTUnwrap(input.pngData())),
            ("skin-categories.bin", Data(categories))]
        for (name, bytes) in attachments {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.data")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        print("APIKS_SKIN_PROBE backend=CPU input=\(Int(size.width))x\(Int(size.height)) " +
              "mask=\(mask.width)x\(mask.height) ms=\(Int((CFAbsoluteTimeGetCurrent()-began)*1000))")
    }
}
