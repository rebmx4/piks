import Foundation
import AVFoundation
import UIKit
import Combine
import PiksCore

@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var history: EditorHistory
    @Published var selected: UUID?
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published private(set) var busy: String?
    @Published var error: String?
    @Published private(set) var saving = false
    @Published private(set) var exportProgress: Double?
    @Published var exportedFile: URL?
    @Published private(set) var thumbnails: [UUID: UIImage] = [:]
    let player = AVPlayer()
    let repository: ProjectRepository
    let media: MediaLibrary
    private let io = DispatchQueue(label: "piks.native.project-io", qos: .utility)
    private var saveWork: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?
    private var previewTemps: TempFiles?
    private var exporter: NativeExporter?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var previewGeneration = UUID()
    private var activity: UIBackgroundTaskIdentifier = .invalid
    var project: Project { history.project }
    var selectedClip: Clip? { project.clips.first { $0.id == selected } }

    init(project: Project, repository: ProjectRepository) {
        history = EditorHistory(project: project); self.repository = repository
        media = MediaLibrary(repository: repository)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self, self.isPlaying else { return }
            self.playhead = max(0, min(self.project.duration, time.seconds))
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
            self.isPlaying = false
        }
        refreshPreview(); loadThumbnails()
    }
    func close() {
        player.pause(); isPlaying = false; previewTask?.cancel(); previewGeneration = UUID()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.replaceCurrentItem(with: nil); previewTemps?.removeAll(); previewTemps = nil
        saveImmediately(); Task { await media.cancelProxies() }
    }
    func edit(_ command: EditCommand) {
        guard exportProgress == nil else { return }
        do {
            try history.apply(command); queueSave(); refreshPreview()
            UISelectionFeedbackGenerator().selectionChanged()
        } catch { self.error = error.localizedDescription }
    }
    func beginGesture() { history.beginTransaction() }
    func endGesture() { history.endTransaction(); queueSave() }
    func undo() { history.undo(); queueSave(); refreshPreview() }
    func redo() { history.redo(); queueSave(); refreshPreview() }
    func seek(_ time: Double) {
        playhead = max(0, min(project.duration, time))
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 30000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlayback() {
        if isPlaying { player.pause(); isPlaying = false }
        else {
            if playhead >= project.duration - 0.01 { seek(0) }
            player.play(); isPlaying = true
        }
    }
    func queueSave() {
        saveWork?.cancel()
        let snapshot = project; let repo = repository
        let work = DispatchWorkItem { [weak self] in
            do { try repo.save(snapshot) }
            catch { DispatchQueue.main.async { self?.error = error.localizedDescription } }
            DispatchQueue.main.async { self?.saving = false }
        }
        saving = true; saveWork = work; io.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    func saveImmediately() {
        saveWork?.cancel()
        let snapshot = project; let repo = repository
        activity = UIApplication.shared.beginBackgroundTask(withName: "Save project") { [weak self] in self?.finishActivity() }
        io.async { [weak self] in
            do { try repo.save(snapshot) }
            catch { DispatchQueue.main.async { self?.error = error.localizedDescription } }
            DispatchQueue.main.async { self?.saving = false; self?.finishActivity() }
        }
    }
    private func finishActivity() {
        if activity != .invalid { UIApplication.shared.endBackgroundTask(activity); activity = .invalid }
    }
    func importFiles(_ files: [URL], lane: Int = 0) {
        guard busy == nil, exportProgress == nil else { return }
        busy = "Импорт файлов…"
        let id = project.id
        Task {
            defer { busy = nil }
            for file in files {
                do {
                    let a = try await media.importFile(file, project: id)
                    guard project.id == id else { return }
                    let chosenLane = a.kind == .audio ? -1 : lane
                    let at = chosenLane == 0 ? project.clips.filter { $0.lane == 0 }.map(\.end).max() ?? 0 : playhead
                    edit(.importMedia(a, lane: chosenLane, at: at, duration: a.kind == .image ? 5 : a.duration))
                    selected = project.clips.last?.id
                    loadThumbnails()
                    if a.kind == .video {
                        Task {
                            do { _ = try await media.proxy(for: a, project: id); if project.id == id { refreshPreview() } }
                            catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
                        }
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private func loadThumbnails() {
        let snapshot = project
        Task {
            for asset in snapshot.assets where asset.kind != .audio && thumbnails[asset.id] == nil {
                if let image = try? await media.thumbnail(for: asset, project: snapshot.id), project.id == snapshot.id {
                    thumbnails[asset.id] = image
                }
            }
        }
    }
    func refreshPreview() {
        previewTask?.cancel(); let generation = UUID(); previewGeneration = generation
        let snapshot = project; let repo = repository
        guard snapshot.duration > 0 else { player.replaceCurrentItem(with: nil); return }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { () -> (PlanAssembly, TempFiles) in
                    let typed = try RenderPlanBuilder.build(snapshot, mode: .preview)
                    let files = try RenderAdapter.files(typed, repository: repo, usage: .preview)
                    let temps = TempFiles()
                    do { return (try NativeExporter.assemble(RenderAdapter.plan(typed), files, temps: temps), temps) }
                    catch { temps.removeAll(); throw error }
                }.value
                guard let self, !Task.isCancelled, self.previewGeneration == generation,
                      self.project.id == snapshot.id, self.project.revision == snapshot.revision else {
                    prepared.1.removeAll(); return
                }
                let item = AVPlayerItem(asset: prepared.0.comp)
                item.videoComposition = prepared.0.video; item.audioMix = prepared.0.mix
                let old = self.previewTemps; self.player.replaceCurrentItem(with: item)
                self.previewTemps = prepared.1; old?.removeAll()
                self.seek(self.playhead)
                if self.isPlaying { self.player.play() }
            } catch {
                if !Task.isCancelled, let self, self.previewGeneration == generation { self.error = error.localizedDescription }
            }
        }
    }
    func export(saveToPhotos: Bool) {
        guard exporter == nil, project.duration > 0, busy == nil else { return }
        player.pause(); isPlaying = false; exportProgress = 0
        let snapshot = project, repo = repository
        Task {
            do {
                let pair = try await Task.detached(priority: .userInitiated) { () -> (ExportPlan, [String: URL]) in
                    let typed = try RenderPlanBuilder.build(snapshot, mode: .export)
                    return (try RenderAdapter.plan(typed, save: saveToPhotos), try RenderAdapter.files(typed, repository: repo, usage: .export))
                }.value
                guard exportProgress != nil else { return }
                let job = NativeExporter(job: UUID().uuidString, plan: pair.0, send: { [weak self] event in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let value = event["value"] as? Double { self.exportProgress = value }
                        if event["event"] as? String == "export-error" { self.error = event["reason"] as? String }
                        if let reason = event["saveError"] as? String { self.error = reason }
                    }
                }, resolve: { id, done in done(pair.1[id]) })
                exporter = job
                job.onFinish = { [weak self] file in
                    self?.exportProgress = nil; self?.exporter = nil; self?.exportedFile = file
                }
                job.start()
            } catch { exportProgress = nil; self.error = error.localizedDescription }
        }
    }
    func cancelExport() { exporter?.cancel(); if exporter == nil { exportProgress = nil } }
}
