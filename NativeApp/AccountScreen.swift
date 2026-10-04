import SwiftUI
import AuthenticationServices
import PiksCore

struct AccountScreen: View {
    @ObservedObject var account: AccountStore
    let localCleanup: (UUID) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var registrationID: String?
    @State private var mode: Mode = .login
    @State private var confirmDeletion = false
    enum Mode: String, CaseIterable { case login = "Вход", register = "Регистрация", reset = "Восстановление" }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Проекты, видео и фотографии хранятся только на этом устройстве.")
                    Text("Вход не переносит проекты в облако. Гостевые проекты остаются в гостевом каталоге.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let user = account.session?.user {
                    Section("Ваш аккаунт") {
                        Text(user.email ?? "Аккаунт Apple")
                        Button("Выйти") { Task { await account.logout() } }.disabled(account.busy)
                        Button("Удалить аккаунт", role: .destructive) { confirmDeletion = true }.disabled(account.busy)
                    }
                } else {
                    Section("Войти в аккаунт") {
                        if account.capabilities?.apple == true {
                            SignInWithAppleButton(.signIn, onRequest: account.beginApple) { result in
                                Task { await account.receiveApple(result); await account.prepareApple() }
                            }.signInWithAppleButtonStyle(.white).frame(height: 48)
                                .disabled(!account.appleReady || account.busy).accessibilityIdentifier("account.apple")
                        }
                        if account.googleReady {
                            Button { Task { await account.signInGoogle() } } label: {
                                HStack { Text("G").font(.title3.bold()); Text("Войти через Google"); Spacer() }.frame(minHeight: 44)
                            }.disabled(account.busy).accessibilityIdentifier("account.google")
                        }
                        if account.capabilities == nil || (account.capabilities?.apple == false && account.capabilities?.email == false) {
                            Text("Вход временно недоступен. Вы можете продолжать монтаж без регистрации.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Повторить") { Task { await account.loadCapabilities() } }.disabled(account.busy)
                        }
                    }
                    if account.capabilities?.email == true { emailSection }
                }
                if account.busy { Section { ProgressView("Подождите…") } }
                if let error = account.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("account.error") } }
                if let notice = account.notice { Section { Text(notice).foregroundStyle(.secondary) } }
                Section {
                    Link("Политика конфиденциальности", destination: URL(string: "https://rynpro.ru/piks-native/privacy/")!)
                    Text("Удаление приложения удалит локальные проекты. Готовые ролики можно сохранить в «Фото» и «Файлы».")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Аккаунт").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() }.disabled(account.busy) } }
                .interactiveDismissDisabled(account.busy)
                .task {
                    await account.loadCapabilities()
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 240_000_000_000) } catch { return }
                        await account.prepareApple()
                    }
                }
                .confirmationDialog("Удалить аккаунт и все его проекты с этого устройства?", isPresented: $confirmDeletion, titleVisibility: .visible) {
                    Button("Удалить аккаунт и проекты", role: .destructive) { Task { await account.deleteAccount(localCleanup: localCleanup) } }
                    Button("Отмена", role: .cancel) {}
                }
                .onChange(of: mode) { _ in registrationID = nil; code = ""; password = ""; account.error = nil }
        }
    }
    private var emailSection: some View {
        Section("Почта") {
            Picker("Действие", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("Почта", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(mode == .reset ? "Новый пароль" : "Пароль", text: $password)
                .textContentType(mode == .login ? .password : .newPassword)
            if registrationID != nil || mode == .reset {
                TextField("Код из письма", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
            }
            if mode == .login {
                Button("Войти") { Task { let result = await account.perform { try await $0.login(email: email, password: password) }; if result != nil { password = "" } } }
                    .disabled(account.busy || email.isEmpty || password.isEmpty)
            } else if mode == .register {
                if let proof = registrationID {
                    Button("Подтвердить почту") { Task { let result = await account.perform { try await $0.verifyEmail(email: email, code: code, registrationID: proof) }; if result != nil { password = ""; code = ""; registrationID = nil } } }
                        .disabled(account.busy || code.count != 6)
                } else {
                    Button("Получить код") { Task { let result = await account.perform { try await $0.register(email: email, password: password) }; registrationID = result?.registrationId; password = "" } }
                        .disabled(account.busy || email.isEmpty || password.count < 10)
                }
            } else {
                Button("Получить код восстановления") { Task { let result: Void? = await account.perform { try await $0.requestReset(email: email) }; if result != nil { account.notice = "Если почта зарегистрирована, на неё придёт код." } } }
                    .disabled(account.busy || email.isEmpty)
                Button("Сохранить новый пароль") { Task { let result: Void? = await account.perform { try await $0.resetPassword(email: email, code: code, password: password) }; if result != nil { mode = .login; account.notice = "Пароль изменён. Войдите в аккаунт." } } }
                    .disabled(account.busy || code.count != 6 || password.count < 10)
            }
            if mode != .login { Text("Пароль — не менее 10 символов. Код действует 10 минут.").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
