import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import PiksCore

struct EditorScreen: View {
    @StateObject private var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var picker = false
    @State private var filePicker = false
    @State private var importLane = 0
    @State private var panel: EditorPanel?
    @State private var newText = ""
    @State private var exportOptions = false
    init(project: Project, repository: ProjectRepository) {
        _store = StateObject(wrappedValue: EditorStore(project: project, repository: repository))
    }
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if store.project.duration > 0 { PlayerSurface(player: store.player) }
                    else {
                        Button { picker = true } label: {
                            VStack(spacing: 12) { Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 36)); Text("Добавить видео или фото").font(.headline) }
                                .padding(30)
                        }.accessibilityIdentifier("editor.importEmpty")
                    }
                    if let busy = store.busy { VStack(spacing: 10) { ProgressView(); Text(busy).font(.caption) }.padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)) }
                }.frame(height: max(160, geo.size.height * 0.43))
                HStack(spacing: 12) {
                    Text(formatTime(store.playhead)).font(.caption.monospacedDigit()).foregroundStyle(Color.accentColor)
                    Text("/ \(formatTime(store.project.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.togglePlayback() } label: { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(store.isPlaying ? "Пауза" : "Воспроизвести").accessibilityIdentifier("editor.play")
                    Spacer()
                    Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.disabled(!store.history.canUndo).accessibilityLabel("Отменить").accessibilityIdentifier("editor.undo")
                    Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.disabled(!store.history.canRedo).accessibilityLabel("Повторить")
                }.padding(.horizontal, 12)
                NativeTimeline(project: store.project, selected: store.selected, playhead: store.playhead,
                    thumbnails: store.thumbnails, onSelect: { store.selected = $0 }, onSeek: store.seek)
                    .frame(maxHeight: .infinity).background(Color(.secondarySystemBackground))
                if let selected = store.selectedClip {
                    HStack {
                        Text(store.project.assets.first(where: { $0.id == selected.assetID })?.originalName ?? "Клип").lineLimit(1).font(.caption)
                        Spacer(); Text("\(selected.speed, specifier: "%.2g")×").font(.caption.monospacedDigit())
                    }.padding(.horizontal, 16).padding(.top, 10).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        tool("Медиа", "plus") { importLane = 0; picker = true }
                        tool("Файлы", "folder") { importLane = 0; filePicker = true }
                        tool("Формат", "aspectratio") { panel = .canvas }
                        tool("Разрез", "scissors") { if let id = store.selected { store.edit(.split(id, at: store.playhead)) } }.disabled(store.selected == nil)
                        tool("Обрезка", "arrow.left.and.right") { panel = .trim }.disabled(store.selected == nil)
                        tool("Скорость", "speedometer") { panel = .speed }.disabled(store.selected == nil)
                        tool("Звук", "speaker.wave.2") { panel = .audio }.disabled(store.selected == nil)
                        tool("Текст", "textformat") { panel = .text }
                        tool("Слой", "square.3.layers.3d") { importLane = 1; picker = true }
                        tool("Кадр", "crop.rotate") { panel = .transform }.disabled(store.selected == nil)
                        tool("Цвет", "slider.horizontal.3") { panel = .color }.disabled(store.selected == nil)
                        tool("Эффекты", "sparkles") { panel = .effects }.disabled(store.selected == nil)
                        tool("Удалить", "trash") { if let id = store.selected { store.edit(.delete(id)); store.selected = nil } }.disabled(store.selected == nil)
                    }.padding(.horizontal, 12).padding(.vertical, 12)
                }
            }
        }.navigationTitle(store.project.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Экспорт") { exportOptions = true }.fontWeight(.semibold).disabled(store.project.duration == 0 || store.busy != nil)
                        .accessibilityIdentifier("editor.export")
                }
            }
            .sheet(isPresented: $picker) { NativeMediaPicker { files in store.importFiles(files, lane: importLane) } }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.movie, .image, .audio], allowsMultipleSelection: true) { result in
                switch result { case .success(let files): store.importFiles(files, lane: importLane); case .failure(let error): store.error = error.localizedDescription }
            }
            .sheet(item: $panel) { panel in EditorPanelView(panel: panel, store: store, filePicker: $filePicker) }
            .confirmationDialog("Экспорт \(store.project.width)×\(store.project.height)", isPresented: $exportOptions, titleVisibility: .visible) {
                Button("Сохранить в «Фото»") { store.export(saveToPhotos: true) }
                Button("Экспортировать и поделиться") { store.export(saveToPhotos: false) }
            }
            .sheet(isPresented: Binding(get: { store.exportProgress != nil }, set: { if !$0 { store.cancelExport() } })) {
                VStack(spacing: 24) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 42)).foregroundStyle(Color.accentColor)
                    Text("Создаём твой ролик").font(.title2.bold())
                    Text("Экспорт из оригиналов · \(store.project.width)×\(store.project.height)").foregroundStyle(.secondary)
                    ProgressView(value: store.exportProgress ?? 0).padding(.horizontal, 32)
                    Text("\(Int((store.exportProgress ?? 0) * 100)) %").font(.title.monospacedDigit())
                    Button("Отменить экспорт", role: .cancel) { store.cancelExport() }.frame(minHeight: 44)
                }.presentationDetents([.medium]).interactiveDismissDisabled()
            }
            .sheet(item: Binding(get: { store.exportedFile.map { ShareableFile(url: $0) } }, set: { if $0 == nil { store.clearExportedFile() } })) { ShareSheet(items: [$0.url]) }
            .alert("Не удалось выполнить действие", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .onChange(of: scenePhase) { value in if value != .active { store.player.pause(); store.isPlaying = false; store.saveImmediately() } }
            .onDisappear { store.close() }
    }
    func tool(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 19)); Text(name).font(.system(size: 10, weight: .medium)) }.frame(width: 62, height: 54) }
            .buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("editor.tool.\(symbol)")
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Surface { let view = Surface(); view.playerLayer.videoGravity = .resizeAspect; view.playerLayer.player = player; return view }
    func updateUIView(_ view: Surface, context: Context) { view.playerLayer.player = player }
}

struct ShareableFile: Identifiable { var id: String { url.path }; let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct NativeMediaPicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion, dismiss: { dismiss() }) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(); config.selectionLimit = 20; config.filter = .any(of: [.videos, .images])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([URL]) -> Void, dismiss: () -> Void
        init(completion: @escaping ([URL]) -> Void, dismiss: @escaping () -> Void) { self.completion = completion; self.dismiss = dismiss }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            dismiss()
            Task {
                var files: [URL] = []
                for result in results {
                    let provider = result.itemProvider
                    let type = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie.identifier : UTType.image.identifier
                    do {
                        let file = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                                do {
                                    guard let url else { throw error ?? EditorError.invalid("Файл из «Фото» недоступен.") }
                                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                                    try FileManager.default.copyItem(at: url, to: copy)
                                    continuation.resume(returning: copy)
                                } catch { continuation.resume(throwing: error) }
                            }
                        }
                        files.append(file)
                    } catch { /* Import errors are reported by the editor in the next pipeline stage. */ }
                }
                await MainActor.run { completion(files) }
            }
        }
    }
}
