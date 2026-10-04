# APIKS Native production — план выполнения

Spec: docs/native/SPEC.md. Авторизация: «старт», 04.10.2026.
Global constraints: отдельная ветка; локальные проекты/1080p proxy/экспорт оригиналов;
без Firebase и платных сервисов; исходную WebView-версию не менять.

Рекомендуемая модель для реализации: GPT-6.1-sol, уровень max. Причина: владелец
выбрал Sol с максимальным рассуждением для переноса монтажного движка и проверки
взаимосвязанных медиаопераций и безопасности сессий.

### Task 1: Swift core and durable local projects

Interfaces: Project, Asset, Clip, EditorHistory, ProjectRepository; временная шкала в секундах,
media trim в исходных секундах, duration = sourceDuration / speed.
Write failing Swift tests for split/trim/speed/undo, invalid mutations, original/proxy selection,
atomic save/reopen and ownership isolation. Run with the official isolated Linux toolchain.
Expected: tests fail before implementation and pass afterward. No iOS imports in the core.
Implement validated Codable models, commands/history and atomic filesystem persistence.
Commit only native files after checks. Record test evidence in the ledger.

### Task 2: Native media pipeline and original-resolution render

Consumes Task 1 models; produces MediaLibrary, ProxyQueue, RenderPlanBuilder, ExportSession.
Read existing native AVFoundation compositor and audio mixer; copy independent code into NativeEngine.
Write render-plan tests: original resolution, orientation, trim/speed, multilayer timing, audio and texts.
Implement file import, metadata, 1080p proxy, thumbnails, own export, progress/cancellation.
Expected: preview resolves proxies; export rejects unavailable originals and uses no web fallback.

### Task 3: Native editor UI and complete first editing scenario

Consumes Task 1 EditorStore and Task 2 pipeline; produces SwiftUI library/editor and UIKit timeline.
Implement import, reliable selection, scrubbing, split/trim/reorder, undo/redo, save/reopen/export/share.
Add integration/XCTest and accessible identifiers for essential actions.
Expected: complete native flow compiles and runs on the Mac simulator; project survives relaunch.

### Task 4: Feature parity and responsive editing

Consumes Tasks 1–3; produces implemented feature matrix and performance measurements.
Implement layers, crop/transform, speed, volume/fades, grade/LUT, effects, native text and captions,
keyframes, transitions and supported native retouch/background processing without paid ASR.
Test time mapping, audio/export parity, stale async completion, cancellation and long/4K projects.
Expected: every claimed feature has a working native path; unsupported functions remain explicitly open.

### Task 5: Own identity service

Consumes account contract in SPEC; produces HTTPS API, SQLite users/sessions, tests and deployment recipe.
Write failing tests for email verification, login, token rotation/replay, rate limits, provider audiences,
account deletion and isolation. Implement verified Apple/Google identities and email authentication.
Expected: no media upload routes; credentials/secrets never in source or logs; tests pass.

### Task 6: Native sign-in and local account catalog

Consumes Task 5 API and Task 1 repository; produces Apple/Google/email UI, Keychain and account deletion.
Keep guest editing available, document local-only projects, isolate catalogs on account switch.
Test expiry/restoration, cancelled login, network failure, deletion and unavailable email transport.
Expected: account never uploads project/media; login cancellation leaves the editor usable.

### Task 7: Apple/Google provisioning and release configuration

Consumes native app/API; produces separate bundle IDs, App Group, OAuth clients, privacy metadata.
Use owner's authenticated browser. Configure only free identity services and new native identifiers.
Expected: current test app IDs/profiles remain unchanged; privacy claims match actual network traffic.

### Task 8: Mac CI, native tests and TestFlight artifact

Consumes Tasks 1–7; produces native-only XcodeGen/Codemagic workflow, XCTest and signed native IPA.
Run Mac compilation and tests before archive/upload; fix failures within the corresponding task.
Expected: successful native checks and processed separate TestFlight build, with no publication to App Store.

### Task 9: Device validation, Store materials and final review

Consumes processed build; produces measured device scenarios, real screenshots, reviewer notes and checklist.
Validate touch targets, offline project reopen, 4K export, sound, cancel/background/memory and account deletion.
Use one fresh-context whole-branch reviewer; fix important findings and repeat affected checks.
Expected: reviewed, testable release candidate; unresolved external or device checks stated accurately.
