import Foundation
import AVFoundation
import CoreImage
import Photos
import UIKit

// Нативный экспорт Ryndi: ролик собирает сам телефон, как CapCut.
//
// Зачем. Страница в браузере собирает ролик медленнее реального времени
// (1080p в Safari — около 0,5–1×), не читает HEVC 10 бит с айфона и не
// потянет несколько слоёв видео. Телефон делает то же видеокартой и
// аппаратным кодировщиком в разы быстрее.
//
// Как устроено. Страница присылает ПЛАН (web/core/nativeplan.js): какие
// куски каких роликов где стоят, и для каждого кадра — готовую матрицу,
// куда поставить кадр исходника. Считать здесь нечего: матрицы уже сверены
// тестами с превью. Телефон:
//   1) складывает куски в дорожки AVMutableComposition;
//   2) на каждый кадр выхода берёт кадры дорожек и кладёт их слоями по
//      матрицам (RyndiCompositor, Core Image на видеокарте);
//   3) сводит звук (AVAudioMix) и пишет HEVC нужного размера, частоты и
//      потока (AVAssetReader → AVAssetWriter);
//   4) сохраняет файл в галерею.
//
// Цвет. Core Image работает без цветового управления (NSNull) — как WebGL
// превью: числа кадра обрабатываются как есть, картинка совпадает. HDR с
// айфона AVFoundation сам переводит в обычный 709 до того, как кадр попадёт
// к нам (свойства цвета у композиции ниже).

// MARK: - План со страницы

struct ExportPlan {
    struct Item {
        let media: String
        let at: Double
        let from: Double
        let dur: Double
        let k0: Int
        let frames: [[Double]]      // [a, b, c, d, tx, ty, прозрачность] на кадр, начиная с k0
    }
    struct Sound {
        let media: String
        let at: Double
        let from: Double
        let dur: Double
        let volume: Double
    }
    struct Overlay {
        let png: Data
        let at: Double
        let dur: Double
        let rect: CGRect            // в пикселях выхода, y вниз
    }

    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let codec: String
    let frames: Int
    let media: [String: String]     // id ролика -> адрес ryndi-media://...
    let layers: [[Item]]            // снизу вверх
    let overlays: [Overlay]
    let sounds: [Sound]
    let grade: [Double]?
    let save: Bool

    init?(json: [String: Any]) {
        guard let w = ExportPlan.int(json["width"]), let h = ExportPlan.int(json["height"]),
              let rate = ExportPlan.int(json["fps"]), let count = ExportPlan.int(json["frames"]),
              w > 0, h > 0, rate > 0, count > 0 else { return nil }
        width = w
        height = h
        fps = rate
        frames = count
        bitrate = ExportPlan.int(json["bitrate"]) ?? 8_000_000
        codec = (json["codec"] as? String) ?? "hevc"
        save = (json["save"] as? Bool) ?? true

        var urls: [String: String] = [:]
        for entry in (json["media"] as? [[String: Any]]) ?? [] {
            if let id = entry["id"] as? String, let url = entry["url"] as? String { urls[id] = url }
        }
        media = urls

        var allLayers: [[Item]] = []
        for layer in (json["layers"] as? [[String: Any]]) ?? [] {
            var items: [Item] = []
            for raw in (layer["items"] as? [[String: Any]]) ?? [] {
                guard let mid = raw["media"] as? String,
                      let at = ExportPlan.num(raw["at"]),
                      let from = ExportPlan.num(raw["from"]),
                      let dur = ExportPlan.num(raw["dur"]) else { continue }
                var rows: [[Double]] = []
                for row in (raw["frames"] as? [Any]) ?? [] {
                    let values = ((row as? [Any]) ?? []).compactMap { ExportPlan.num($0) }
                    if values.count >= 6 { rows.append(values) }
                }
                if rows.isEmpty { continue }
                items.append(Item(media: mid, at: at, from: from, dur: dur,
                                  k0: ExportPlan.int(raw["k0"]) ?? 0, frames: rows))
            }
            allLayers.append(items)
        }
        layers = allLayers

        var allSounds: [Sound] = []
        for raw in (json["sounds"] as? [[String: Any]]) ?? [] {
            guard let mid = raw["media"] as? String,
                  let at = ExportPlan.num(raw["at"]),
                  let from = ExportPlan.num(raw["from"]),
                  let dur = ExportPlan.num(raw["dur"]) else { continue }
            allSounds.append(Sound(media: mid, at: at, from: from, dur: dur,
                                   volume: ExportPlan.num(raw["volume"]) ?? 1))
        }
        sounds = allSounds

        var allOverlays: [Overlay] = []
        for raw in (json["images"] as? [[String: Any]]) ?? [] {
            guard let text = raw["png"] as? String, let data = Data(base64Encoded: text),
                  let at = ExportPlan.num(raw["at"]), let dur = ExportPlan.num(raw["dur"]) else { continue }
            let r = ((raw["rect"] as? [Any]) ?? []).compactMap { ExportPlan.num($0) }
            guard r.count == 4 else { continue }
            allOverlays.append(Overlay(png: data, at: at, dur: dur,
                                       rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])))
        }
        overlays = allOverlays

        let g = ((json["grade"] as? [Any]) ?? []).compactMap { ExportPlan.num($0) }
        grade = g.count == 12 ? g : nil
    }

    static func num(_ v: Any?) -> Double? { return (v as? NSNumber)?.doubleValue }
    static func int(_ v: Any?) -> Int? { return (v as? NSNumber)?.intValue }
}

struct ExportError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { return text }
}

// MARK: - Сцена: что лежит на кадре в момент t

final class RenderScene {
    struct Item {
        let trackID: CMPersistentTrackID
        let at: Double
        let end: Double
        let k0: Int
        let frames: [[Double]]
        let pref: CGAffineTransform     // поворот хранения исходника
    }
    struct Overlay {
        let image: CIImage
        let at: Double
        let end: Double
    }

    let size: CGSize
    let fps: Double
    let layers: [[Item]]
    let overlays: [Overlay]
    let grade: [Double]?
    private var lastMain: CIImage?      // основной слой, если кадра на стыке нет

    init(size: CGSize, fps: Double, layers: [[Item]], overlays: [Overlay], grade: [Double]?) {
        self.size = size
        self.fps = fps
        self.layers = layers
        self.overlays = overlays
        self.grade = grade
    }

    // Вызывается только с очереди композитора — по одному кадру за раз.
    func compose(at t: Double, frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        var out = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        for (index, layer) in layers.enumerated() {
            var placed: CIImage? = nil
            if let item = RenderScene.item(in: layer, at: t), let buffer = frame(item.trackID) {
                let row = sample(item, at: t)
                var source = CIImage(cvPixelBuffer: buffer)
                if let g = grade { source = RenderScene.graded(source, g) }
                let m = RenderScene.placement(source.extent.size, item.pref, row, out: size)
                var image = source.transformed(by: m)
                let opacity = row.count > 6 ? row[6] : 1
                if opacity < 0.999 {
                    image = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity))),
                    ])
                }
                placed = image
                if index == 0 { lastMain = image }
            } else if index == 0 {
                // Основной слой не пустеет: на стыке кусков или в последнем
                // кадре держим прошлый кадр, а не вспышку чёрного.
                placed = lastMain
            }
            if let image = placed { out = image.composited(over: out) }
        }
        for o in overlays where t + 1e-6 >= o.at && t + 1e-6 < o.end {
            out = o.image.composited(over: out)
        }
        return out.cropped(to: bounds)
    }

    private func sample(_ item: Item, at t: Double) -> [Double] {
        if item.frames.count == 1 { return item.frames[0] }
        let k = Int((t * fps).rounded()) - item.k0
        return item.frames[max(0, min(item.frames.count - 1, k))]
    }

    static func item(in layer: [Item], at t: Double) -> Item? {
        let tt = t + 1e-6
        for it in layer where tt >= it.at && tt < it.end { return it }
        return nil
    }

    // Кадр декодера (Core Image: y вверх, хранение боком) -> пиксели выхода.
    // Матрица плана работает в долях кадра, КАК ЕГО ВИДИТ зритель, y вниз.
    static func placement(_ raw: CGSize, _ pref: CGAffineTransform, _ r: [Double],
                          out: CGSize) -> CGAffineTransform {
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: raw.height)
        let shown = CGRect(origin: .zero, size: raw).applying(pref)
        let upright = pref.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
        let unit = CGAffineTransform(scaleX: 1 / max(shown.width, 1), y: 1 / max(shown.height, 1))
        let plan = CGAffineTransform(a: CGFloat(r[0]), b: CGFloat(r[1]), c: CGFloat(r[2]),
                                     d: CGFloat(r[3]), tx: CGFloat(r[4]), ty: CGFloat(r[5]))
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height)
        return flipIn.concatenating(upright).concatenating(unit).concatenating(plan).concatenating(flipOut)
    }

    // Цвет как в шейдере превью: матрица 3×3 и сдвиг, затем обрезка в 0..1.
    static func graded(_ image: CIImage, _ g: [Double]) -> CIImage {
        guard g.count >= 12 else { return image }
        func v(_ i: Int) -> CGFloat { return CGFloat(g[i]) }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v(0), y: v(1), z: v(2), w: 0),
            "inputGVector": CIVector(x: v(3), y: v(4), z: v(5), w: 0),
            "inputBVector": CIVector(x: v(6), y: v(7), z: v(8), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: v(9), y: v(10), z: v(11), w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [:])
    }
}

// MARK: - Инструкция и композитор

final class RyndiInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let scene: RenderScene

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], scene: RenderScene) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.scene = scene
        super.init()
    }
}

final class RyndiCompositor: NSObject, AVVideoCompositing {
    // Без цветового управления — как WebGL превью (см. шапку файла).
    static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])

    private let queue = DispatchQueue(label: "ryndi.compositor")
    private var cancelling = false

    var sourcePixelBufferAttributes: [String: Any]? {
        return [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        return [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            if self.cancelling {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? RyndiInstruction,
                      let out = request.renderContext.newPixelBuffer() else {
                    request.finish(with: ExportError("кадр не собрался"))
                    return
                }
                let scene = instruction.scene
                let t = CMTimeGetSeconds(request.compositionTime)
                let image = scene.compose(at: t) { request.sourceFrame(byTrackID: $0) }
                RyndiCompositor.context.render(image, to: out,
                                               bounds: CGRect(origin: .zero, size: scene.size),
                                               colorSpace: nil)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelling = true
        queue.async { self.cancelling = false }
    }
}

// MARK: - Экспорт

final class NativeExporter {
    let job: String
    private let plan: ExportPlan
    private let send: ([String: Any]) -> Void
    private let resolve: (String, @escaping (URL?) -> Void) -> Void
    private let work = DispatchQueue(label: "ryndi.export.work")
    private let videoQueue = DispatchQueue(label: "ryndi.export.video")
    private let audioQueue = DispatchQueue(label: "ryndi.export.audio")
    private let started = Date()
    private var lastProgress = Date.distantPast
    private var cancelled = false
    private var ended = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    // Вызывается на главной очереди, когда экспорт закончился (файл или nil).
    var onFinish: ((URL?) -> Void)?

    // Время с точностью до миллисекунды и до кадра при 24, 25, 30, 50 и 60.
    private static let scale: CMTimeScale = 30000

    init(job: String, plan: ExportPlan,
         send: @escaping ([String: Any]) -> Void,
         resolve: @escaping (String, @escaping (URL?) -> Void) -> Void) {
        self.job = job
        self.plan = plan
        self.send = send
        self.resolve = resolve
    }

    func start() {
        send(["event": "export-progress", "job": job, "value": 0.0])
        resolveAll { files in
            self.work.async {
                if self.cancelled { self.finishCancelled(); return }
                do {
                    try self.build(files)
                } catch {
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        reader?.cancelReading()
        if reader == nil { work.async { self.finishCancelled() } }
    }

    // Адрес ryndi-media://orig/<id>.mp4 -> файл ролика в галерее.
    private func resolveAll(_ done: @escaping ([String: URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [String: URL] = [:]
        for (id, address) in plan.media {
            let name = URL(string: address)?.lastPathComponent ?? ""
            let fileId = (name as NSString).deletingPathExtension
            group.enter()
            resolve(fileId) { file in
                if let file = file {
                    lock.lock()
                    found[id] = file
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(found) }
    }

    private func time(_ seconds: Double) -> CMTime {
        return CMTime(seconds: seconds, preferredTimescale: NativeExporter.scale)
    }

    // Кусок исходника на дорожку. Дорожка идёт по порядку: пустое место
    // до куска заполняется пустотой, нахлёст от округления срезается.
    private func place(_ track: AVMutableCompositionTrack, _ src: AVAssetTrack,
                       at: Double, from: Double, dur: Double,
                       ends: inout [CMPersistentTrackID: CMTime]) throws {
        var start = time(at)
        var source = time(from)
        var length = time(dur)
        let srcEnd = CMTimeRangeGetEnd(src.timeRange)
        if CMTimeCompare(CMTimeAdd(source, length), srcEnd) > 0 { length = CMTimeSubtract(srcEnd, source) }
        let end = ends[track.trackID] ?? CMTime.zero
        if CMTimeCompare(start, end) < 0 {
            let overlap = CMTimeSubtract(end, start)
            start = end
            source = CMTimeAdd(source, overlap)
            length = CMTimeSubtract(length, overlap)
        } else if CMTimeCompare(start, end) > 0 {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: start))
        }
        guard CMTimeCompare(length, CMTime.zero) > 0 else { return }
        try track.insertTimeRange(CMTimeRange(start: source, duration: length), of: src, at: start)
        ends[track.trackID] = CMTimeAdd(start, length)
    }

    private func build(_ files: [String: URL]) throws {
        for id in plan.media.keys where files[id] == nil {
            throw ExportError("ролик не найден в галерее — откройте его заново")
        }
        let comp = AVMutableComposition()
        var assets: [String: AVURLAsset] = [:]
        func asset(_ id: String) -> AVURLAsset? {
            if let a = assets[id] { return a }
            guard let url = files[id] else { return nil }
            let a = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[id] = a
            return a
        }

        let total = CMTime(value: CMTimeValue(plan.frames), timescale: CMTimeScale(plan.fps))
        var ends: [CMPersistentTrackID: CMTime] = [:]
        var videoIDs: [CMPersistentTrackID] = []
        var firstTrack: AVMutableCompositionTrack? = nil
        var sceneLayers: [[RenderScene.Item]] = []

        // Видео: на каждый слой по дорожке на ролик — куски одного слоя не
        // пересекаются, а разные ролики не смешиваются на одной дорожке.
        for layer in plan.layers {
            var tracks: [String: AVMutableCompositionTrack] = [:]
            var items: [RenderScene.Item] = []
            for it in layer {
                guard let a = asset(it.media), let src = a.tracks(withMediaType: .video).first else {
                    throw ExportError("в ролике не нашлось видео")
                }
                let track: AVMutableCompositionTrack
                if let known = tracks[it.media] {
                    track = known
                } else {
                    guard let made = comp.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw ExportError("не создаётся дорожка видео")
                    }
                    tracks[it.media] = made
                    videoIDs.append(made.trackID)
                    if firstTrack == nil { firstTrack = made }
                    track = made
                }
                try place(track, src, at: it.at, from: it.from, dur: it.dur, ends: &ends)
                items.append(RenderScene.Item(trackID: track.trackID, at: it.at, end: it.at + it.dur,
                                              k0: it.k0, frames: it.frames, pref: src.preferredTransform))
            }
            sceneLayers.append(items)
        }
        guard let mainTrack = firstTrack else { throw ExportError("в ролике нет кусков") }
        // Композиция не короче ролика: иначе последние кадры не прочитаются.
        let mainEnd = ends[mainTrack.trackID] ?? CMTime.zero
        if CMTimeCompare(mainEnd, total) < 0 {
            mainTrack.insertEmptyTimeRange(CMTimeRange(start: mainEnd, end: total))
        }

        // Звук: кусок на первую свободную к его началу дорожку.
        var audioTracks: [AVMutableCompositionTrack] = []
        var params: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        for s in plan.sounds {
            guard let a = asset(s.media), let src = a.tracks(withMediaType: .audio).first else { continue }
            let start = time(s.at)
            var chosen: AVMutableCompositionTrack? = nil
            for t in audioTracks where CMTimeCompare(ends[t.trackID] ?? CMTime.zero, start) <= 0 {
                chosen = t
                break
            }
            if chosen == nil,
               let made = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                audioTracks.append(made)
                chosen = made
            }
            guard let track = chosen else { continue }
            try place(track, src, at: s.at, from: s.from, dur: s.dur, ends: &ends)
            let p = params[track.trackID] ?? AVMutableAudioMixInputParameters(track: track)
            p.setVolume(Float(s.volume), at: start)
            params[track.trackID] = p
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = Array(params.values)

        // Картинки поверх (надписи): в пиксели выхода, y вверх для Core Image.
        let outH = CGFloat(plan.height)
        var overlays: [RenderScene.Overlay] = []
        for o in plan.overlays {
            guard let img = CIImage(data: o.png, options: [.colorSpace: NSNull()]) else { continue }
            let e = img.extent
            guard e.width > 0, e.height > 0 else { continue }
            let r = o.rect
            let tr = CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: r.width / e.width, y: r.height / e.height))
                .concatenating(CGAffineTransform(translationX: r.minX, y: outH - r.maxY))
            overlays.append(RenderScene.Overlay(image: img.transformed(by: tr), at: o.at, end: o.at + o.dur))
        }

        let scene = RenderScene(size: CGSize(width: plan.width, height: plan.height), fps: Double(plan.fps),
                                layers: sceneLayers, overlays: overlays, grade: plan.grade)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = RyndiCompositor.self
        vc.renderSize = scene.size
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.fps))
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let span = CMTimeCompare(comp.duration, total) > 0 ? comp.duration : total
        vc.instructions = [RyndiInstruction(timeRange: CMTimeRange(start: CMTime.zero, duration: span),
                                            trackIDs: videoIDs, scene: scene)]

        try run(comp, vc, mix, total)
    }

    private func videoSettings(_ codec: AVVideoCodecType) -> [String: Any] {
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.bitrate,
                AVVideoExpectedSourceFrameRateKey: plan.fps,
                AVVideoMaxKeyFrameIntervalKey: plan.fps * 2,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    private func run(_ comp: AVComposition, _ vc: AVVideoComposition, _ mix: AVAudioMix, _ total: CMTime) throws {
        let safeJob = String(job.filter { $0.isLetter || $0.isNumber }.prefix(32))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ryndi-export-\(safeJob).mp4")
        try? FileManager.default.removeItem(at: out)

        // Запись. HEVC, если телефон его пишет, иначе H.264.
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var codec: AVVideoCodecType = plan.codec == "h264" ? .h264 : .hevc
        var vs = videoSettings(codec)
        if !writer.canApply(outputSettings: vs, forMediaType: .video) {
            codec = .h264
            vs = videoSettings(codec)
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw ExportError("кодировщик видео не запускается") }
        writer.add(videoIn)

        // Чтение: кадры через композитор, звук сведённым.
        let reader = try AVAssetReader(asset: comp)
        reader.timeRange = CMTimeRange(start: CMTime.zero, duration: total)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: comp.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = vc
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw ExportError("кадры не читаются") }
        reader.add(videoOut)

        // Звук берём, только если его есть куда писать: непрочитанный выход
        // остановил бы чтение целиком.
        var audioIn: AVAssetWriterInput? = nil
        var audioOut: AVAssetReaderAudioMixOutput? = nil
        let audioTracks = comp.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let aac: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000,
            ]
            let pcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            input.expectsMediaDataInRealTime = false
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
            output.audioMix = mix
            output.alwaysCopiesSampleData = false
            if writer.canAdd(input) && reader.canAdd(output) {
                writer.add(input)
                reader.add(output)
                audioIn = input
                audioOut = output
            }
        }

        self.reader = reader
        self.writer = writer
        if cancelled { finishCancelled(); return }
        guard writer.startWriting() else {
            throw writer.error ?? (ExportError("запись файла не началась") as Error)
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? (ExportError("чтение роликов не началось") as Error)
        }
        writer.startSession(atSourceTime: CMTime.zero)

        let group = DispatchGroup()
        let seconds = max(CMTimeGetSeconds(total), 0.001)
        pump(videoIn, videoOut, videoQueue, group, progressOf: seconds)
        if let input = audioIn, let output = audioOut {
            pump(input, output, audioQueue, group, progressOf: nil)
        }
        let hasAudio = audioIn != nil
        group.notify(queue: work) {
            self.complete(reader, writer, out, codec: codec, audio: hasAudio)
        }
    }

    private func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, _ queue: DispatchQueue,
                      _ group: DispatchGroup, progressOf seconds: Double?) {
        group.enter()
        var finished = false
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData && !finished {
                if self.cancelled {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                if let seconds = seconds {
                    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                    self.progress(t / seconds)
                }
                if !input.append(sample) {
                    finished = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }

    private func progress(_ value: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastProgress) > 0.25 else { return }
        lastProgress = now
        send(["event": "export-progress", "job": job, "value": max(0, min(1, value))])
    }

    private func complete(_ reader: AVAssetReader, _ writer: AVAssetWriter, _ out: URL,
                          codec: AVVideoCodecType, audio: Bool) {
        if cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            finishCancelled()
            return
        }
        if reader.status == .failed || writer.status == .failed {
            let why = (writer.error ?? reader.error)?.localizedDescription ?? "сборка ролика не удалась"
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: out)
            fail(why)
            return
        }
        writer.finishWriting {
            guard writer.status == .completed else {
                self.fail(writer.error?.localizedDescription ?? "файл не записался")
                return
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
            let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            var info: [String: Any] = [
                "event": "export-done", "job": self.job, "bytes": bytes,
                "took": Date().timeIntervalSince(self.started),
                "width": self.plan.width, "height": self.plan.height, "fps": self.plan.fps,
                "codec": codec == .hevc ? "hevc" : "avc", "audio": audio,
            ]
            guard self.plan.save else {
                info["saved"] = false
                self.end(info, file: out)
                return
            }
            NativeExporter.saveToPhotos(out) { ok, why in
                info["saved"] = ok
                if let why = why { info["saveError"] = why }
                self.end(info, file: out)
            }
        }
    }

    private func finishCancelled() {
        end(["event": "export-cancelled", "job": job], file: nil)
    }

    private func fail(_ reason: String) {
        end(["event": "export-error", "job": job, "reason": reason], file: nil)
    }

    private func end(_ event: [String: Any], file: URL?) {
        DispatchQueue.main.async {
            if self.ended { return }
            self.ended = true
            self.send(event)
            self.onFinish?(file)
        }
    }

    static func saveToPhotos(_ url: URL, done: @escaping (Bool, String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                done(false, "нет разрешения сохранять в галерею")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }, completionHandler: { ok, error in
                done(ok, ok ? nil : (error?.localizedDescription ?? "в галерею не сохранилось"))
            })
        }
    }
}
