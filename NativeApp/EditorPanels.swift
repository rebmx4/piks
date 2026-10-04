import SwiftUI
import UIKit
import PiksCore

enum EditorPanel: String, Identifiable {
    case trim, speed, audio, text, transform, color, effects, canvas
    var id: String { rawValue }
    var title: String {
        switch self { case .trim: return "Обрезка"; case .speed: return "Скорость"; case .audio: return "Звук";
        case .text: return "Текст"; case .transform: return "Кадр"; case .color: return "Цвет"; case .effects: return "Эффекты"; case .canvas: return "Формат проекта" }
    }
}

struct EditorPanelView: View {
    let panel: EditorPanel
    @ObservedObject var store: EditorStore
    @Binding var filePicker: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                if panel == .canvas {
                    Picker("Частота кадров", selection: Binding(get: { store.project.fps }, set: { store.edit(.canvas(store.project.width, store.project.height, $0)) })) {
                        ForEach([24, 25, 30, 60], id: \.self) { Text("\($0) кадров/с").tag($0) }
                    }
                    ForEach(["9:16", "16:9", "1:1", "4:3"], id: \.self) { format in
                        Button(format) { setCanvas(format) }.frame(minHeight: 44)
                    }
                    Text("Экспорт: \(store.project.width) × \(store.project.height)").foregroundStyle(.secondary)
                } else if panel == .text {
                    TextField("Текст надписи", text: $text, axis: .vertical).lineLimit(2...5)
                    Button("Добавить надпись") {
                        let remaining = max(1, store.project.duration - store.playhead)
                        store.edit(.text(TextOverlay(text: text, at: store.playhead, duration: min(5, remaining))))
                        text = ""
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(store.project.texts) { item in
                        NavigationLink { NativeTextSettings(store: store, id: item.id) } label: { Text(item.text).lineLimit(2).frame(minHeight: 44) }
                    }
                } else if let clip = store.selectedClip {
                    switch panel {
                    case .trim:
                        if let asset = store.project.assets.first(where: { $0.id == clip.assetID }), asset.kind != .image {
                            adjustment("Начало в исходнике", value: clip.sourceStart, range: 0...max(0, asset.duration - clip.sourceDuration)) { value in
                                store.edit(.trim(clip.id, from: value, duration: clip.sourceDuration))
                            }
                            let remaining = max(0.00002, asset.duration - clip.sourceStart)
                            adjustment("Длина исходника", value: clip.sourceDuration, range: min(1.0 / Double(store.project.fps), remaining)...remaining) { value in
                                store.edit(.trim(clip.id, from: clip.sourceStart, duration: value))
                            }
                        } else {
                            adjustment("Длительность фото, с", value: clip.sourceDuration, range: 0.1...120) { store.edit(.trim(clip.id, from: 0, duration: $0)) }
                        }
                        Button("Обрезать начало до курсора") {
                            let offset = store.playhead - clip.at
                            store.edit(.trim(clip.id, from: clip.sourceStart + offset * clip.speed, duration: clip.sourceDuration - offset * clip.speed))
                        }.disabled(store.playhead <= clip.at || store.playhead >= clip.end)
                        Button("Обрезать конец по курсору") {
                            let length = store.playhead - clip.at
                            store.edit(.trim(clip.id, from: clip.sourceStart, duration: length * clip.speed))
                        }.disabled(store.playhead <= clip.at || store.playhead >= clip.end)
                        if clip.lane == 0 {
                            Button("Раньше") { reorder(clip, direction: -1) }
                            Button("Позже") { reorder(clip, direction: 1) }
                            Button("Переместить в конец") { store.edit(.reorder(clip.id, before: nil)) }
                        }
                    case .speed:
                        adjustment("Скорость ×", value: clip.speed, range: 0.05...20) { store.edit(.speed(clip.id, $0)) }
                        HStack { ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { speed in Button("\(speed, specifier: "%.2g")×") { store.edit(.speed(clip.id, speed)) }.frame(minHeight: 44) } }
                    case .audio:
                        adjustment("Громкость", value: clip.volume, range: 0...4) { value in mutate { $0.volume = value } }
                        Toggle("Без звука", isOn: Binding(get: { clip.muted }, set: { value in mutate { $0.muted = value } }))
                        adjustment("Появление, с", value: clip.fadeIn, range: 0...clip.duration) { value in mutate { $0.fadeIn = value } }
                        adjustment("Затухание, с", value: clip.fadeOut, range: 0...clip.duration) { value in mutate { $0.fadeOut = value } }
                        Picker("Каналы", selection: Binding(get: { clip.channel }, set: { value in mutate { $0.channel = value } })) {
                            Text("Стерео").tag("stereo"); Text("Левый в оба уха").tag("left"); Text("Правый в оба уха").tag("right")
                        }
                        Button("Добавить музыку из «Файлов»") { dismiss(); filePicker = true }
                    case .transform:
                        let pose = clip.transform(at: localTime(clip))
                        adjustment("Масштаб", value: pose.scale, range: 0.1...4) { value in changePose { $0.scale = value } }
                        adjustment("Поворот", value: pose.rotation, range: -180...180) { value in changePose { $0.rotation = value } }
                        adjustment("Положение X", value: pose.x, range: -1...1) { value in changePose { $0.x = value } }
                        adjustment("Положение Y", value: pose.y, range: -1...1) { value in changePose { $0.y = value } }
                        adjustment("Прозрачность", value: pose.opacity, range: 0...1) { value in changePose { $0.opacity = value } }
                        Button("Добавить ключевой кадр здесь") {
                            mutate { c in
                                let time = localTime(c)
                                let key = c.transform(at: time)
                                if c.keyframes.isEmpty, time > 0 { c.keyframes.append(c.baseTransform.at(0)) }
                                c.keyframes.removeAll { abs($0.time - time) < 1.0 / Double(store.project.fps) }
                                c.keyframes.append(key); c.keyframes.sort { $0.time < $1.time }
                            }
                        }
                        Text("Ключевых кадров: \(clip.keyframes.count)").foregroundStyle(.secondary)
                        ForEach(clip.keyframes, id: \.time) { key in
                            Button("Перейти к ключу \(key.time, specifier: "%.2f") с") { store.seek(clip.at + key.time) }.frame(minHeight: 44)
                        }
                        Button("Удалить ключевые кадры") { mutate { $0.baseTransform = pose.at(0); $0.keyframes.removeAll() } }
                        Button("Заполнить кадр") {
                            if let a = store.project.assets.first(where: { $0.id == clip.assetID }) {
                                let fit = min(Double(store.project.width) / Double(a.width), Double(store.project.height) / Double(a.height))
                                let fill = max(Double(store.project.width) / Double(a.width), Double(store.project.height) / Double(a.height))
                                changePose { $0.scale = fill / fit }
                            }
                        }
                        Section("Обрезка кадра") {
                            adjustment("Слева", value: clip.crop.x, range: 0...max(0, 1 - clip.crop.width)) { value in mutate { $0.crop.x = value } }
                            adjustment("Сверху", value: clip.crop.y, range: 0...max(0, 1 - clip.crop.height)) { value in mutate { $0.crop.y = value } }
                            adjustment("Ширина", value: clip.crop.width, range: 0.01...max(0.01, 1 - clip.crop.x)) { value in mutate { $0.crop.width = value } }
                            adjustment("Высота", value: clip.crop.height, range: 0.01...max(0.01, 1 - clip.crop.y)) { value in mutate { $0.crop.height = value } }
                            Button("Сбросить обрезку") { mutate { $0.crop = UnitRect() } }
                        }
                    case .color:
                        adjustment("Яркость", value: clip.effects.brightness, range: -0.5...0.5) { value in mutate { $0.effects.brightness = value } }
                        adjustment("Контраст", value: clip.effects.contrast, range: 0.25...2) { value in mutate { $0.effects.contrast = value } }
                        adjustment("Насыщенность", value: clip.effects.saturation, range: 0...2) { value in mutate { $0.effects.saturation = value } }
                        adjustment("Температура", value: clip.effects.temperature, range: -1...1) { value in mutate { $0.effects.temperature = value } }
                        Button("Сбросить цвет") { mutate { $0.effects = ClipEffects() } }
                    case .effects:
                        adjustment("Резкость", value: clip.effects.sharpen, range: 0...2) { value in mutate { $0.effects.sharpen = value } }
                        adjustment("Виньетка", value: clip.effects.vignette, range: -1...1) { value in mutate { $0.effects.vignette = value } }
                        adjustment("Зерно", value: clip.effects.grain, range: 0...0.5) { value in mutate { $0.effects.grain = value } }
                        adjustment("Размытие", value: clip.effects.blur, range: 0...1) { value in mutate { $0.effects.blur = value } }
                        adjustment("Плавное появление, с", value: clip.transitionIn, range: 0...min(3, clip.duration)) { value in mutate { $0.transitionIn = value } }
                    default: EmptyView()
                    }
                }
            }.navigationTitle(panel.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { store.endGesture(); dismiss() } } }
                .onDisappear { store.endGesture() }
        }.presentationDetents([.medium, .large])
    }
    func mutate(_ change: (inout Clip) -> Void) {
        guard var clip = store.selectedClip else { return }; change(&clip); store.edit(.replace(clip))
    }
    func localTime(_ clip: Clip) -> Double { max(0, min(clip.duration, store.playhead - clip.at)) }
    func changePose(_ change: (inout TransformKeyframe) -> Void) {
        mutate { clip in
            let time = localTime(clip)
            var key = clip.transform(at: time); change(&key)
            if clip.keyframes.isEmpty { clip.baseTransform = key.at(0) }
            else {
                clip.keyframes.removeAll { abs($0.time - time) < 1.0 / Double(store.project.fps) }
                clip.keyframes.append(key); clip.keyframes.sort { $0.time < $1.time }
            }
        }
    }
    func reorder(_ clip: Clip, direction: Int) {
        let order = store.project.clips.filter { $0.lane == 0 }.sorted { $0.at < $1.at }
        guard let index = order.firstIndex(where: { $0.id == clip.id }) else { return }
        if direction < 0, index > 0 { store.edit(.reorder(clip.id, before: order[index - 1].id)) }
        if direction > 0, index + 1 < order.count { store.edit(.reorder(clip.id, before: index + 2 < order.count ? order[index + 2].id : nil)) }
    }
    func setCanvas(_ format: String) {
        let ratios: [String: (Double, Double)] = ["9:16": (9, 16), "16:9": (16, 9), "1:1": (1, 1), "4:3": (4, 3)]
        guard let (x, y) = ratios[format] else { return }
        let edge = Double(min(store.project.width, store.project.height))
        let width = Int(edge * x / min(x, y)) / 2 * 2
        let height = Int(edge * y / min(x, y)) / 2 * 2
        store.edit(.canvas(min(8192, width), min(8192, height), store.project.fps))
    }
    func adjustment(_ label: String, value: Double, range: ClosedRange<Double>, update: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(label); Spacer(); Text(value, format: .number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: update), in: range.lowerBound...max(range.lowerBound + 0.000001, range.upperBound)) { editing in
                if editing { store.beginGesture() } else { store.endGesture() }
            }.frame(minHeight: 44).disabled(range.upperBound - range.lowerBound <= 0.000001)
        }
    }
}

struct NativeTextSettings: View {
    @ObservedObject var store: EditorStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            if let item = store.project.texts.first(where: { $0.id == id }) {
                TextField("Текст", text: Binding(get: { item.text }, set: { value in change { $0.text = value } }), axis: .vertical).lineLimit(2...8)
                scalar("Начало, с", item.at, 0...max(item.at, store.project.duration)) { value in change { $0.at = value } }
                scalar("Длительность, с", item.duration, 0.1...max(60, store.project.duration)) { value in change { $0.duration = value } }
                scalar("Положение X", item.x, 0...1) { value in change { $0.x = value } }
                scalar("Положение Y", item.y, 0...1) { value in change { $0.y = value } }
                scalar("Размер", item.fontSize, 0.01...0.25) { value in change { $0.fontSize = value } }
                Toggle("Подложка", isOn: Binding(get: { item.background }, set: { value in change { $0.background = value } }))
                Picker("Цвет", selection: Binding(get: { item.colorHex }, set: { value in change { $0.colorHex = value } })) {
                    Text("Белый").tag("FFFFFF"); Text("Чёрный").tag("000000"); Text("Жёлтый").tag("FFFF00"); Text("Красный").tag("FF3030")
                }
                Button("Удалить надпись", role: .destructive) { store.edit(.deleteText(id)); dismiss() }.frame(minHeight: 44)
            }
        }.navigationTitle("Надпись").onDisappear { store.endGesture() }
    }
    func change(_ update: (inout TextOverlay) -> Void) {
        guard var item = store.project.texts.first(where: { $0.id == id }) else { return }
        update(&item); store.edit(.text(item))
    }
    func scalar(_ title: String, _ value: Double, _ range: ClosedRange<Double>, update: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(value, format: .number.precision(.fractionLength(2))).monospacedDigit() }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: update), in: range.lowerBound...max(range.lowerBound + 0.000001, range.upperBound)) { editing in
                if editing { store.beginGesture() } else { store.endGesture() }
            }.frame(minHeight: 44)
        }
    }
}
