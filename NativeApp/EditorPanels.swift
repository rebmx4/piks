import SwiftUI
import PiksCore

enum EditorPanel: String, Identifiable {
    case trim, speed, audio, text, transform, color, effects
    var id: String { rawValue }
    var title: String {
        switch self { case .trim: return "Обрезка"; case .speed: return "Скорость"; case .audio: return "Звук";
        case .text: return "Текст"; case .transform: return "Кадр"; case .color: return "Цвет"; case .effects: return "Эффекты" }
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
                if panel == .text {
                    TextField("Текст надписи", text: $text, axis: .vertical).lineLimit(2...5)
                    Button("Добавить надпись") {
                        let remaining = max(1, store.project.duration - store.playhead)
                        store.edit(.text(TextOverlay(text: text, at: store.playhead, duration: min(5, remaining))))
                        dismiss()
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(store.project.texts) { item in
                        HStack { Text(item.text).lineLimit(2); Spacer(); Button(role: .destructive) { store.edit(.deleteText(item.id)) } label: { Image(systemName: "trash").frame(width: 44, height: 44) } }
                    }
                } else if let clip = store.selectedClip {
                    switch panel {
                    case .trim:
                        if let asset = store.project.assets.first(where: { $0.id == clip.assetID }), asset.kind != .image {
                            adjustment("Начало в исходнике", value: clip.sourceStart, range: 0...max(0.001, asset.duration - clip.sourceDuration)) { value in
                                store.edit(.trim(clip.id, from: value, duration: clip.sourceDuration))
                            }
                            adjustment("Длина исходника", value: clip.sourceDuration, range: min(0.1, asset.duration - clip.sourceStart)...max(0.1, asset.duration - clip.sourceStart)) { value in
                                store.edit(.trim(clip.id, from: clip.sourceStart, duration: value))
                            }
                        }
                        Button("Обрезать начало до курсора") {
                            let offset = max(0, min(clip.duration - 0.01, store.playhead - clip.at))
                            store.edit(.trim(clip.id, from: clip.sourceStart + offset * clip.speed, duration: clip.sourceDuration - offset * clip.speed))
                        }
                        Button("Обрезать конец по курсору") {
                            let length = max(0.01, min(clip.duration, store.playhead - clip.at))
                            store.edit(.trim(clip.id, from: clip.sourceStart, duration: length * clip.speed))
                        }
                        if clip.lane == 0 {
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
                        adjustment("Масштаб", value: clip.baseTransform.scale, range: 0.1...4) { value in mutate { $0.baseTransform.scale = value } }
                        adjustment("Поворот", value: clip.baseTransform.rotation, range: -180...180) { value in mutate { $0.baseTransform.rotation = value } }
                        adjustment("Положение X", value: clip.baseTransform.x, range: -1...1) { value in mutate { $0.baseTransform.x = value } }
                        adjustment("Положение Y", value: clip.baseTransform.y, range: -1...1) { value in mutate { $0.baseTransform.y = value } }
                        adjustment("Прозрачность", value: clip.baseTransform.opacity, range: 0...1) { value in mutate { $0.baseTransform.opacity = value } }
                        Button("Добавить ключевой кадр здесь") {
                            mutate { c in
                                let time = max(0, min(c.duration, store.playhead - c.at))
                                let key = c.baseTransform.at(time)
                                c.keyframes.removeAll { abs($0.time - time) < 1.0 / Double(store.project.fps) }
                                c.keyframes.append(key); c.keyframes.sort { $0.time < $1.time }
                            }
                        }
                        Text("Ключевых кадров: \(clip.keyframes.count)").foregroundStyle(.secondary)
                        Button("Удалить ключевые кадры") { mutate { $0.keyframes.removeAll() } }
                        Button("Заполнить кадр") {
                            if let a = store.project.assets.first(where: { $0.id == clip.assetID }) {
                                let fit = min(Double(store.project.width) / Double(a.width), Double(store.project.height) / Double(a.height))
                                let fill = max(Double(store.project.width) / Double(a.width), Double(store.project.height) / Double(a.height))
                                mutate { $0.baseTransform.scale = fill / fit }
                            }
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
    func adjustment(_ label: String, value: Double, range: ClosedRange<Double>, update: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(label); Spacer(); Text(value, format: .number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: update), in: range) { editing in
                if editing { store.beginGesture() } else { store.endGesture() }
            }.frame(minHeight: 44)
        }
    }
}
