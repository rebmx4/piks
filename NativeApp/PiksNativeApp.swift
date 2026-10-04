import SwiftUI
import PiksCore

@main
struct PiksNativeApp: App {
    var body: some Scene {
        WindowGroup { ProjectLibraryView().preferredColorScheme(.dark).tint(Color(red: 0.25, green: 0.8, blue: 0.93)) }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var error: String?
    @Published var loading = false
    @Published private(set) var repository: ProjectRepository?
    private let root: URL
    private var generation = UUID()
    private let io = DispatchQueue(label: "piks.native.library-io", qos: .userInitiated)
    init(owner: UUID? = nil, root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
        selectOwner(owner)
    }
    func selectOwner(_ owner: UUID?) {
        generation = UUID(); let token = generation; let root = root
        projects = []; repository = nil; loading = true; error = nil
        io.async { [weak self] in
            do {
                let repo = try ProjectRepository(root: root, owner: owner), list = try repo.catalog()
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.repository = repo; self.projects = list; self.loading = false
                }
            } catch { DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.error = error.localizedDescription; self.loading = false
            } }
        }
    }
    func deleteAccountProjects(_ owner: UUID) async throws {
        let root = root
        try await Task.detached(priority: .userInitiated) {
            try ProjectRepository(root: root, owner: owner).deleteAll()
        }.value
    }
    func reload() {
        guard let repo = repository else { return }
        loading = true; let token = generation
        io.async { [weak self] in
            do { let list = try repo.catalog(); DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.projects = list; self.loading = false
            } }
            catch { DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.error = error.localizedDescription; self.loading = false
            } }
        }
    }
    func create(_ completion: @escaping (Project) -> Void) {
        let p = Project(name: "Новый проект")
        guard let repo = repository else { return }
        let token = generation
        io.async { [weak self] in
            do { try repo.save(p); DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.reload(); completion(p)
            } }
            catch { DispatchQueue.main.async { self?.error = error.localizedDescription } }
        }
    }
    func delete(_ project: Project) {
        guard let repo = repository else { return }
        let token = generation
        io.async { [weak self] in
            do { try repo.delete(project.id); DispatchQueue.main.async { if self?.generation == token { self?.reload() } } }
            catch { DispatchQueue.main.async { self?.error = error.localizedDescription } }
        }
    }
}

struct ProjectLibraryView: View {
    @StateObject private var library = LibraryStore()
    @StateObject private var account = AccountStore()
    @State private var opened: Project?
    @State private var deleting: Project?
    @State private var showAccount = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Твои истории.\nТвой монтаж.").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Исходники и проекты хранятся на этом устройстве.").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { library.create { opened = $0 } } label: {
                        HStack { Image(systemName: "plus.circle.fill"); Text("Создать проект").fontWeight(.semibold); Spacer(); Image(systemName: "arrow.up.right") }
                            .padding(20).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20)).foregroundStyle(.black)
                    }.accessibilityIdentifier("library.create").disabled(library.repository == nil)
                    HStack { Text("Мои проекты").font(.title3.bold()); Spacer(); Text("\(library.projects.count)").foregroundStyle(.secondary) }
                    if library.loading { ProgressView().frame(maxWidth: .infinity) }
                    else if library.projects.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("Здесь появятся твои проекты").font(.headline)
                            Text("Добавь видео или фото и начни монтаж.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 18) {
                        ForEach(library.projects) { p in
                            Button { opened = p } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)).aspectRatio(1.25, contentMode: .fit)
                                        Image(systemName: "play.rectangle.fill").font(.system(size: 32)).foregroundStyle(Color.accentColor)
                                        VStack { Spacer(); HStack { Spacer(); Text(formatTime(p.duration)).font(.caption.monospacedDigit()).padding(7).background(.black.opacity(0.7), in: Capsule()) }.padding(8) }
                                    }
                                    Text(p.name).font(.headline).lineLimit(1)
                                    Text(p.modified, style: .date).font(.caption).foregroundStyle(.secondary)
                                }.foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityIdentifier("library.project.\(p.id)")
                                .contextMenu { Button("Удалить проект", role: .destructive) { deleting = p } }
                        }
                    }
                    Text("Удаление приложения удалит локальные проекты. Сохраняй готовые ролики в «Фото» или «Файлы».")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
                }.padding(20)
            }.navigationTitle("APIKS").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showAccount = true } label: { Image(systemName: "person.crop.circle").frame(width: 44, height: 44) }.accessibilityLabel("Аккаунт") } }
                .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
                    if let p = opened, let repo = library.repository { EditorScreen(project: p, repository: repo).onDisappear { library.reload() } }
                }
                .sheet(isPresented: $showAccount) { AccountScreen(account: account, localCleanup: library.deleteAccountProjects) }
                .task { library.selectOwner(account.session?.user.id) }
                .onChange(of: account.session?.user.id) { owner in opened = nil; library.selectOwner(owner) }
                .confirmationDialog("Удалить проект и его исходники с этого устройства?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) { if let p = deleting { library.delete(p) }; deleting = nil }
                }
                .alert("Не удалось выполнить действие", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("OK") { library.error = nil } } message: { Text(library.error ?? "") }
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    let safe = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%02d:%02d", safe / 60, safe % 60)
}
