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
//
// Настройки цвета клипа (web/core/color.js) приходят готовыми: таблица цвета
// 33³ (те же байты, что у превью) и числа резкости, виньетки, зерна. Их
// формулы — как в шейдере превью (web/engine/grade.js), к кадру клипа до
// общего цвета (RenderScene.effected).
//
// Сборка №17 (владелец, 26.09.2026: «чтобы меньше делать сборок»): общие
// кубики, из которых страница собирает функции без новых сборок. Всё
// необязательно — старые планы читаются как раньше.
//   - скорость: у куска и звука src — длина в исходнике (dur — на ленте);
//     отрезок растягивается scaleTimeRange, звук с сохранением тона;
//   - обрезка: crop [x, y, w, h] — доли кадра, как его видит зритель; матрица
//     плана по-прежнему от ПОЛНОГО кадра;
//   - маска: mask — номер картинки в masks (PNG, белое — видно) или список
//     номеров по кадрам с k0 (−1 — без маски), в долях полного кадра куска,
//     едет с куском;
//   - нахлёст: куски одного слоя могут идти одновременно (переходы) — каждый
//     со своими строками кадра и прозрачностью;
//   - фильтры Core Image по имени: ci у куска (к кадру куска: точки — в
//     пикселях исходника стоя, y вверх) и у плана (ко всему кадру, под
//     надписями: пиксели выхода, y вверх) — { name, params, anim, k0, clamp };
//   - фото: ролик плана — картинка (jpg/png/heic): неподвижный кадр, движение —
//     строками кадра, как у видео. В плане нужен хотя бы один кусок видео.

// MARK: - План со страницы

struct ExportPlan {
    struct Item {
        let media: String
        let at: Double
        let from: Double
        let dur: Double
        let k0: Int
        let frames: [[Double]]      // [a, b, c, d, tx, ty, прозрачность] на кадр, начиная с k0
        let fx: Fx?                 // настройки цвета куска, nil — без них
        let src: Double?            // длина в исходнике (скорость), nil — равна dur
        let crop: CGRect?           // обрезка: доли кадра, как видит зритель, y вниз
        let mask: [Int]             // маски: одна на кусок или по кадру с k0, −1 — без маски
        let ci: [CiStep]            // фильтры Core Image к кадру куска
    }
    // Фильтр Core Image по имени: params — постоянные значения (число, массив
    // 2…4 чисел — вектор, у ключей с Color — цвет), anim — числа по кадрам
    // (с кадра k0 выхода), clamp — края повторяются, итог обрезан по кадру.
    struct CiStep {
        let name: String
        let params: [String: Any]
        let anim: [String: [Double]]
        let k0: Int
        let clamp: Bool
    }
    // Настройки цвета куска — готовые числа формул шейдера превью.
    struct Fx {
        let lut: Int                // номер таблицы в luts, −1 — без таблицы
        let sharpen: Double         // c + k·(c − среднее четырёх соседей)
        let vignette: Double        // плюс — края темнее на это × форму, минус — светлее
        let grain: Double           // c + (шум − ½) × это
    }
    struct Sound {
        let media: String
        let at: Double
        let from: Double
        let dur: Double
        let volume: Double
        // Точки громкости на ленте (секунды выхода): между ними — плавно.
        let keys: [(at: Double, g: Double)]
        let src: Double?            // длина в исходнике (скорость), nil — равна dur
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
    let luts: [Data]                // таблицы цвета для CIColorCube: 33³ × RGBA, Float32
    let masks: [Data]               // маски кусков: PNG
    let ci: [CiStep]                // фильтры ко всему кадру
    let save: Bool

    static let lutN = 33

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
                var fx: Fx? = nil
                if let f = raw["fx"] as? [String: Any] {
                    fx = Fx(lut: ExportPlan.int(f["lut"]) ?? -1,
                            sharpen: ExportPlan.num(f["sharpen"]) ?? 0,
                            vignette: ExportPlan.num(f["vignette"]) ?? 0,
                            grain: ExportPlan.num(f["grain"]) ?? 0)
                }
                var crop: CGRect? = nil
                let c = ((raw["crop"] as? [Any]) ?? []).compactMap { ExportPlan.num($0) }
                if c.count == 4, c[2] > 0.001, c[3] > 0.001 {
                    let r = CGRect(x: c[0], y: c[1], width: c[2], height: c[3])
                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    if !r.isNull, r.width > 0.001, r.height > 0.001 { crop = r }
                }
                let srcLen = ExportPlan.num(raw["src"]).flatMap { $0 > 0 ? $0 : nil }
                items.append(Item(media: mid, at: at, from: from, dur: dur,
                                  k0: ExportPlan.int(raw["k0"]) ?? 0, frames: rows, fx: fx,
                                  src: srcLen, crop: crop, mask: ExportPlan.ints(raw["mask"]),
                                  ci: ExportPlan.steps(raw["ci"])))
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
            let keys: [(at: Double, g: Double)] = ((raw["keys"] as? [[String: Any]]) ?? []).compactMap {
                (k: [String: Any]) -> (at: Double, g: Double)? in
                guard let kat = ExportPlan.num(k["at"]), let g = ExportPlan.num(k["g"]) else { return nil }
                return (at: kat, g: g)
            }
            allSounds.append(Sound(media: mid, at: at, from: from, dur: dur,
                                   volume: ExportPlan.num(raw["volume"]) ?? 1, keys: keys,
                                   src: ExportPlan.num(raw["src"]).flatMap { $0 > 0 ? $0 : nil }))
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

        // Таблицы цвета: байты 0…255 -> Float32 0…1, как ждёт CIColorCube.
        // Битая таблица — пустая (кусок без неё), номера остальных не сдвигаются.
        let size = ExportPlan.lutN * ExportPlan.lutN * ExportPlan.lutN * 4
        var tables: [Data] = []
        for raw in (json["luts"] as? [Any]) ?? [] {
            guard let text = raw as? String, let bytes = Data(base64Encoded: text), bytes.count == size else {
                tables.append(Data())
                continue
            }
            var floats = [Float](repeating: 0, count: size)
            bytes.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                for i in 0..<size { floats[i] = Float(p[i]) / 255 }
            }
            tables.append(floats.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        luts = tables

        masks = ((json["masks"] as? [Any]) ?? []).map { raw in
            ((raw as? String).flatMap { Data(base64Encoded: $0) }) ?? Data()
        }
        ci = ExportPlan.steps(json["ci"])
    }

    static func num(_ v: Any?) -> Double? { return (v as? NSNumber)?.doubleValue }
    static func int(_ v: Any?) -> Int? { return (v as? NSNumber)?.intValue }
    static func ints(_ v: Any?) -> [Int] {
        if let list = v as? [Any] { return list.map { ExportPlan.int($0) ?? -1 } }
        return ExportPlan.int(v).map { [$0] } ?? []
    }

    static func steps(_ v: Any?) -> [CiStep] {
        var out: [CiStep] = []
        for raw in (v as? [[String: Any]]) ?? [] {
            guard let name = raw["name"] as? String, name.hasPrefix("CI") else { continue }
            var anim: [String: [Double]] = [:]
            for (key, list) in (raw["anim"] as? [String: Any]) ?? [:] {
                let values = ((list as? [Any]) ?? []).compactMap { ExportPlan.num($0) }
                if !values.isEmpty { anim[key] = values }
            }
            out.append(CiStep(name: name, params: (raw["params"] as? [String: Any]) ?? [:], anim: anim,
                              k0: ExportPlan.int(raw["k0"]) ?? 0, clamp: (raw["clamp"] as? Bool) ?? true))
        }
        return out
    }
}

struct ExportError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { return text }
}

// MARK: - Сцена: что лежит на кадре в момент t

final class RenderScene {
    struct Item {
        let trackID: CMPersistentTrackID    // у фото — kCMPersistentTrackID_Invalid
        let still: CIImage?                 // фото: кадр стоя, y вверх, от (0, 0)
        var at: Double
        let end: Double
        let k0: Int
        let frames: [[Double]]
        let pref: CGAffineTransform     // поворот хранения исходника
        let fx: ExportPlan.Fx?
        let crop: CGRect?
        let mask: [CIImage?]                // одна на кусок или по кадру с k0
        let ci: [ExportPlan.CiStep]
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
    let luts: [Data]
    let ci: [ExportPlan.CiStep]         // ко всему кадру, под надписями
    private var lastMain: CIImage?      // основной слой, если кадра на стыке нет

    init(size: CGSize, fps: Double, layers: [[Item]], overlays: [Overlay], grade: [Double]?, luts: [Data],
         ci: [ExportPlan.CiStep] = []) {
        self.size = size
        self.fps = fps
        self.layers = layers
        self.overlays = overlays
        self.grade = grade
        self.luts = luts
        self.ci = ci
    }

    // Вызывается только с очереди композитора — по одному кадру за раз.
    func compose(at t: Double, frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        var out = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bounds)
        let k = Int((t * fps).rounded())
        for (index, layer) in layers.enumerated() {
            // Куски слоя в этот миг: обычно один, при переходе — два (нахлёст).
            var placed: CIImage? = nil
            for item in RenderScene.items(in: layer, at: t) {
                guard let image = render(item, at: t, k: k, frame: frame) else { continue }
                placed = placed.map { image.composited(over: $0) } ?? image
            }
            if index == 0 {
                // Основной слой не пустеет: на стыке кусков или в последнем
                // кадре держим прошлый кадр, а не вспышку чёрного.
                if let image = placed { lastMain = image } else { placed = lastMain }
            }
            if let image = placed { out = image.composited(over: out) }
        }
        for step in ci { out = RenderScene.filtered(out, step, k: k, clamp: bounds) }
        for o in overlays where t + 1e-6 >= o.at && t + 1e-6 < o.end {
            out = o.image.composited(over: out)
        }
        return out.cropped(to: bounds)
    }

    // Кадр куска на выходе: обрезка -> цвет -> фильтры -> матрица -> маска ->
    // прозрачность. nil — кадра нет (стык, конец ролика).
    private func render(_ item: Item, at t: Double, k: Int,
                        frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        var source: CIImage
        let raw: CGSize
        if let still = item.still {
            source = still
            raw = still.extent.size
        } else {
            guard let buffer = frame(item.trackID) else { return nil }
            source = CIImage(cvPixelBuffer: buffer)
            raw = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        }
        // Обрезка — до цвета: виньетка и зерно ложатся на рамку, как в превью.
        // Матрица — всё равно от ПОЛНОГО кадра (raw), не от обрезанного.
        if let crop = item.crop {
            let full = CGRect(origin: .zero, size: raw)
            let r = crop.applying(RenderScene.toUnit(raw, item.pref).inverted()).integral.intersection(full)
            if !r.isNull, r.width >= 1, r.height >= 1 { source = source.cropped(to: r) }
        }
        let row = sample(item, at: t)
        if let fx = item.fx {
            let cube: Data? = luts.indices.contains(fx.lut) ? luts[fx.lut] : nil
            source = RenderScene.effected(source, fx, cube: cube, frame: k)
        }
        if let g = grade { source = RenderScene.graded(source, g) }
        if !item.ci.isEmpty {
            // Фильтры куска — в кадре стоя (как видит зритель, пиксели
            // исходника, y вверх): иначе углы и точки легли бы боком.
            let shown = CGRect(origin: .zero, size: raw).applying(item.pref)
            let up = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: raw.height)
                .concatenating(item.pref)
                .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -shown.minX, ty: shown.maxY))
            var u = source.transformed(by: up)
            for step in item.ci { u = RenderScene.filtered(u, step, k: k, clamp: u.extent) }
            source = u.transformed(by: up.inverted())
        }
        let m = RenderScene.placement(raw, item.pref, row, out: size)
        var image = source.transformed(by: m, highQualityDownsample: item.still != nil)
        let maskNow: CIImage? = item.mask.isEmpty ? nil
            : item.mask[max(0, min(item.mask.count - 1, k - item.k0))]
        if let mask = maskNow {
            // Маска в долях полного кадра куска (y вниз) — той же матрицей.
            let me = mask.extent
            let toUnit = CGAffineTransform(a: 1 / max(me.width, 1), b: 0, c: 0, d: -1 / max(me.height, 1),
                                           tx: -me.minX / max(me.width, 1), ty: 1 + me.minY / max(me.height, 1))
            let placedMask = mask.transformed(by: toUnit.concatenating(RenderScene.planMatrix(row))
                .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)))
            image = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: placedMask,
            ])
        }
        let opacity = row.count > 6 ? row[6] : 1
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity))),
            ])
        }
        return image
    }

    private func sample(_ item: Item, at t: Double) -> [Double] {
        if item.frames.count == 1 { return item.frames[0] }
        let k = Int((t * fps).rounded()) - item.k0
        return item.frames[max(0, min(item.frames.count - 1, k))]
    }

    static func items(in layer: [Item], at t: Double) -> [Item] {
        let tt = t + 1e-6
        return layer.filter { tt >= $0.at && tt < $0.end }
    }

    // Кадр декодера (Core Image: y вверх, хранение боком) -> доли кадра, КАК
    // ЕГО ВИДИТ зритель, y вниз.
    static func toUnit(_ raw: CGSize, _ pref: CGAffineTransform) -> CGAffineTransform {
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: raw.height)
        let shown = CGRect(origin: .zero, size: raw).applying(pref)
        let upright = pref.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
        let unit = CGAffineTransform(scaleX: 1 / max(shown.width, 1), y: 1 / max(shown.height, 1))
        return flipIn.concatenating(upright).concatenating(unit)
    }

    static func planMatrix(_ r: [Double]) -> CGAffineTransform {
        return CGAffineTransform(a: CGFloat(r[0]), b: CGFloat(r[1]), c: CGFloat(r[2]),
                                 d: CGFloat(r[3]), tx: CGFloat(r[4]), ty: CGFloat(r[5]))
    }

    // Кадр декодера -> пиксели выхода. Матрица плана работает в долях кадра,
    // КАК ЕГО ВИДИТ зритель, y вниз.
    static func placement(_ raw: CGSize, _ pref: CGAffineTransform, _ r: [Double],
                          out: CGSize) -> CGAffineTransform {
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height)
        return toUnit(raw, pref).concatenating(planMatrix(r)).concatenating(flipOut)
    }

    // Фильтр Core Image по имени. Значения ставятся только в известные фильтру
    // ключи и только своего вида (число, вектор, цвет) — иначе Core Image
    // уронил бы приложение; неизвестный фильтр пропускается.
    static func filtered(_ image: CIImage, _ step: ExportPlan.CiStep, k: Int, clamp: CGRect) -> CIImage {
        guard let f = CIFilter(name: step.name) else { return image }
        let keys = Set(f.inputKeys)
        guard keys.contains(kCIInputImageKey) else { return image }
        f.setDefaults()
        f.setValue(step.clamp ? image.clampedToExtent() : image, forKey: kCIInputImageKey)
        func put(_ key: String, _ value: Any) {
            guard keys.contains(key), key != kCIInputImageKey else { return }
            let kind = ((f.attributes[key] as? [String: Any])?[kCIAttributeClass] as? String) ?? ""
            if let n = value as? NSNumber, kind == "NSNumber" {
                f.setValue(n, forKey: key)
            } else if let list = value as? [Any] {
                let v = list.compactMap { ExportPlan.num($0) }.map { CGFloat($0) }
                if kind == "CIVector", (1...4).contains(v.count) {
                    f.setValue(CIVector(values: v, count: v.count), forKey: key)
                } else if kind == "CIColor", v.count >= 3 {
                    f.setValue(CIColor(red: v[0], green: v[1], blue: v[2], alpha: v.count > 3 ? v[3] : 1), forKey: key)
                }
            }
        }
        for (key, value) in step.params { put(key, value) }
        for (key, list) in step.anim {
            let i = max(0, min(list.count - 1, k - step.k0))
            put(key, NSNumber(value: list[i]))
        }
        guard let out = f.outputImage else { return image }
        return step.clamp ? out.cropped(to: clamp) : out
    }

    // Настройки цвета куска — как в шейдере превью, в том же порядке:
    // резкость -> таблица цвета -> виньетка -> зерно. Кадр — в своих точках,
    // до поворота и растяжения на выход.
    static func effected(_ image: CIImage, _ fx: ExportPlan.Fx, cube: Data?, frame: Int) -> CIImage {
        let extent = image.extent
        var c = image
        // Резкость: c + k·(c − среднее четырёх соседей) — свёртка 3×3. Края
        // кадра повторяются, как у текстуры превью.
        if fx.sharpen > 0 {
            let k = CGFloat(fx.sharpen), q = -k / 4
            let weights: [CGFloat] = [0, q, 0, q, 1 + k, q, 0, q, 0]
            c = c.clampedToExtent()
                .applyingFilter("CIConvolution3X3", parameters: [
                    "inputWeights": CIVector(values: weights, count: 9),
                    "inputBias": NSNumber(value: 0),
                ])
                .cropped(to: extent)
                .applyingFilter("CIColorClamp", parameters: [:])
        }
        // Таблица цвета — те же байты, что у превью и экспорта страницы.
        if let data = cube, !data.isEmpty {
            c = c.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": NSNumber(value: ExportPlan.lutN),
                "inputCubeData": data,
            ])
        }
        // Виньетка по кадру клипа: форма S растягивается на кадр, сила a.
        // Темнее: c·(1 − a·S); светлее: c + a·S − c·a·S (экран).
        if fx.vignette != 0 {
            let a = CGFloat(abs(fx.vignette))
            let mask = RenderScene.vignetteMask
            let me = mask.extent
            let fitted = mask.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: extent.width / me.width, y: extent.height / me.height)
                    .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
                .cropped(to: extent)
            let dark = fx.vignette > 0
            let s = dark ? -a : a, b: CGFloat = dark ? 1 : 0
            let m = fitted.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
            ])
            c = m.applyingFilter(dark ? "CIMultiplyCompositing" : "CIScreenBlendMode",
                                 parameters: [kCIInputBackgroundImageKey: c])
        }
        // Зерно: c + (n − ½)·a, n — одноцветный шум по точкам кадра, у каждого
        // кадра свой. Через смешивание по маске: (c − a/2) + n·a — без
        // сложения картинок, которое путает прозрачность.
        if fx.grain > 0, let random = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let a = CGFloat(fx.grain), h = a / 2
            let shift = CGAffineTransform(translationX: CGFloat((frame * 97) % 509), y: CGFloat((frame * 211) % 499))
            let noise = random.transformed(by: shift)
                .cropped(to: extent)
                .settingAlphaOne(in: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
            let lighter = c.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: h, y: h, z: h, w: 0),
            ])
            let darker = c.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: -h, y: -h, z: -h, w: 0),
            ])
            c = lighter.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: darker,
                kCIInputMaskImageKey: noise,
            ]).applyingFilter("CIColorClamp", parameters: [:])
        }
        return c.cropped(to: extent)
    }

    // Форма виньетки S: 0 в центре, 1 в углах — как в шейдере превью:
    // d = |(uv − ½)·2|·√½, S = smoothstep(0.35, 1, d). 512×512 хватает:
    // растянутая на кадр, она расходится с формулой меньше 1/255
    // (tests/unit/nativeplan.test.mjs). Считается один раз.
    static let vignetteMask: CIImage = {
        let n = 512
        var px = [Float](repeating: 1, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let u = (Double(x) + 0.5) / Double(n) - 0.5
                let v = (Double(y) + 0.5) / Double(n) - 0.5
                let d = (u * u + v * v).squareRoot() * 2 * 0.70710678
                let t = min(1, max(0, (d - 0.35) / 0.65))
                let s = Float(t * t * (3 - 2 * t))
                let i = (y * n + x) * 4
                px[i] = s
                px[i + 1] = s
                px[i + 2] = s
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: n * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
    }()

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
    // Промежуточные — половинной точности явно: зерну и виньетке нужны
    // значения за пределами 0…1 до последней обрезки, как в шейдере.
    static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
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
    // Скорость (сборка №17): srcDur секунд исходника ложатся на dur секунд
    // ленты — вставляем отрезок исходника и растягиваем его scaleTimeRange.
    // Скорость «почти 1» — без растяжения, ровно как до №17 (расчёт в CMTime).
    private func place(_ track: AVMutableCompositionTrack, _ src: AVAssetTrack,
                       at: Double, from: Double, dur: Double, srcDur: Double? = nil,
                       ends: inout [CMPersistentTrackID: CMTime]) throws {
        var rate = max(0.01, (srcDur ?? dur) / max(dur, 0.000001))   // секунд исходника на секунду ленты
        if abs(rate - 1) <= 0.0005 { rate = 1 }
        var start = time(at)
        var source = time(from)
        var length = time(rate == 1 ? dur : (srcDur ?? dur))         // длина в исходнике
        let srcEnd = CMTimeRangeGetEnd(src.timeRange)
        if CMTimeCompare(CMTimeAdd(source, length), srcEnd) > 0 { length = CMTimeSubtract(srcEnd, source) }
        let end = ends[track.trackID] ?? CMTime.zero
        if CMTimeCompare(start, end) < 0 {
            let overlap = CMTimeSubtract(end, start)                  // на ленте
            let skip = rate == 1 ? overlap : time(CMTimeGetSeconds(overlap) * rate)
            start = end
            source = CMTimeAdd(source, skip)
            length = CMTimeSubtract(length, skip)
        } else if CMTimeCompare(start, end) > 0 {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: start))
        }
        guard CMTimeCompare(length, CMTime.zero) > 0 else { return }
        try track.insertTimeRange(CMTimeRange(start: source, duration: length), of: src, at: start)
        var placed = length                                          // длина на ленте
        if rate != 1 {
            placed = time(CMTimeGetSeconds(length) / rate)
            track.scaleTimeRange(CMTimeRange(start: start, duration: length), toDuration: placed)
        }
        ends[track.trackID] = CMTimeAdd(start, placed)
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
        // Фото (сборка №17): картинка стоя, без цветового управления — как видео.
        var stills: [String: CIImage] = [:]
        func still(_ id: String) -> CIImage? {
            if let s = stills[id] { return s }
            guard let url = files[id], NativeExporter.isImage(url),
                  let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .colorSpace: NSNull()])
            else { return nil }
            let e = img.extent
            let s = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            stills[id] = s
            return s
        }
        var maskImages: [Int: CIImage] = [:]
        func maskImage(_ i: Int) -> CIImage? {
            guard plan.masks.indices.contains(i), !plan.masks[i].isEmpty else { return nil }
            if let m = maskImages[i] { return m }
            guard let m = CIImage(data: plan.masks[i], options: [.colorSpace: NSNull()]) else { return nil }
            maskImages[i] = m
            return m
        }

        let total = CMTime(value: CMTimeValue(plan.frames), timescale: CMTimeScale(plan.fps))
        var ends: [CMPersistentTrackID: CMTime] = [:]
        var videoIDs: [CMPersistentTrackID] = []
        var firstTrack: AVMutableCompositionTrack? = nil
        var sceneLayers: [[RenderScene.Item]] = []

        // Видео: на каждый слой дорожки по роликам — разные ролики не
        // смешиваются на одной дорожке. Куски одного слоя, идущие одновременно
        // (переход, сборка №17), — на разные дорожки: дорожка идёт по порядку.
        let slack = 0.5 / Double(plan.fps)
        for layer in plan.layers {
            var tracks: [String: [AVMutableCompositionTrack]] = [:]
            var items: [RenderScene.Item] = []
            for it in layer {
                if let img = still(it.media) {
                    items.append(RenderScene.Item(trackID: kCMPersistentTrackID_Invalid, still: img,
                                                  at: it.at, end: it.at + it.dur, k0: it.k0, frames: it.frames,
                                                  pref: .identity, fx: it.fx, crop: it.crop,
                                                  mask: it.mask.map { maskImage($0) }, ci: it.ci))
                    continue
                }
                guard let a = asset(it.media), let src = a.tracks(withMediaType: .video).first else {
                    throw ExportError("в ролике не нашлось видео")
                }
                var track: AVMutableCompositionTrack? = nil
                for t in tracks[it.media] ?? [] {
                    let free = CMTimeGetSeconds(ends[t.trackID] ?? CMTime.zero)
                    if free <= it.at + slack { track = t; break }
                }
                if track == nil {
                    guard let made = comp.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw ExportError("не создаётся дорожка видео")
                    }
                    tracks[it.media, default: []].append(made)
                    videoIDs.append(made.trackID)
                    if firstTrack == nil { firstTrack = made }
                    track = made
                }
                guard let chosen = track else { throw ExportError("не создаётся дорожка видео") }
                try place(chosen, src, at: it.at, from: it.from, dur: it.dur, srcDur: it.src, ends: &ends)
                items.append(RenderScene.Item(trackID: chosen.trackID, still: nil, at: it.at, end: it.at + it.dur,
                                              k0: it.k0, frames: it.frames, pref: src.preferredTransform,
                                              fx: it.fx, crop: it.crop, mask: it.mask.map { maskImage($0) }, ci: it.ci))
            }
            // Нахлёст меньше полукадра — округление плана, а не переход: в
            // кадре один кусок, как до сборки №17 (первый по списку).
            let order = items.indices.sorted { items[$0].at < items[$1].at }
            for (p, q) in zip(order, order.dropFirst())
                where items[q].at < items[p].end && items[p].end - items[q].at < slack {
                items[q].at = items[p].end
            }
            sceneLayers.append(items)
        }
        guard let mainTrack = firstTrack else { throw ExportError("в ролике нет ни одного куска видео") }
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
            try place(track, src, at: s.at, from: s.from, dur: s.dur, srcDur: s.src, ends: &ends)
            let p = params[track.trackID] ?? AVMutableAudioMixInputParameters(track: track)
            if s.keys.count >= 2 {
                // Точки громкости: уровень в начале куска, дальше между
                // соседними точками — плавный переход (setVolumeRamp).
                let end = s.at + s.dur
                func gain(_ t: Double) -> Double {
                    if t <= s.keys[0].at { return s.keys[0].g }
                    for i in 0..<(s.keys.count - 1) where t <= s.keys[i + 1].at {
                        let a = s.keys[i], b = s.keys[i + 1]
                        return a.g + (b.g - a.g) * (t - a.at) / max(0.001, b.at - a.at)
                    }
                    return s.keys[s.keys.count - 1].g
                }
                var cursor = s.at
                // Уровень в начале — отдельно, только если первый переход
                // начинается позже: пересекаться с ним не должен.
                if s.keys[0].at > s.at + 0.001 { p.setVolume(Float(gain(cursor)), at: start) }
                for i in 0..<(s.keys.count - 1) {
                    let from = max(s.keys[i].at, cursor), to = min(s.keys[i + 1].at, end)
                    if to - from < 0.001 { continue }
                    p.setVolumeRamp(fromStartVolume: Float(gain(from)), toEndVolume: Float(gain(to)),
                                    timeRange: CMTimeRange(start: time(from), end: time(to)))
                    cursor = to
                }
                if cursor < end - 0.001 { p.setVolume(Float(gain(cursor)), at: time(cursor)) }
            } else {
                p.setVolume(Float(s.volume), at: start)
            }
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
                                layers: sceneLayers, overlays: overlays, grade: plan.grade, luts: plan.luts,
                                ci: plan.ci)
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
            // Ускоренный и замедленный звук — без смены тона (голос не «мультяшный»).
            output.audioTimePitchAlgorithm = .spectral
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

    static func isImage(_ url: URL) -> Bool {
        return ["jpg", "jpeg", "png", "heic", "heif"].contains(url.pathExtension.lowercased())
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
