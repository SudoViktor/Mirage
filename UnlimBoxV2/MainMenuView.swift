import SwiftUI
import FileProvider
import TDLibKit

struct MainMenuView: View {
    var body: some View {
        TabView {
            ManagementTabView()
                .tabItem { Label("Керування", systemImage: "externaldrive.fill.badge.icloud") }
            
            QueueTabView()
                .tabItem { Label("Черга", systemImage: "arrow.up.arrow.down.circle.fill") }
            
            SettingsTabView()
                .tabItem { Label("Налаштування", systemImage: "gearshape.fill") }
        }
    }
}
// 🚨 ОНОВЛЕНО: Додано кнопки скасування завантажень
struct QueueTabView: View {
    @StateObject private var tgManager = TelegramManager.shared
    
    var visibleTasks: [TransferTask] {
        tgManager.activeTransfers.filter { $0.progress < 100 }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Черга передачі").font(.system(size: 22, weight: .bold))
                Spacer()
            }
            .padding(.top, 25).padding(.bottom, 15)
            
            if tgManager.activeTransfers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.icloud").font(.system(size: 40)).foregroundColor(.green.opacity(0.7))
                    Text("Усі файли синхронізовано").font(.headline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                
                VStack(spacing: 12) {
                    // 📤 БЛОК ВІДПРАВКИ
                    if !tgManager.uploadTransfers.isEmpty {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Відвантаження (\(tgManager.uploadCompletedFiles) з \(tgManager.uploadTotalFiles) файлів)")
                                    .font(.subheadline).bold()
                                Spacer()
                                
                                // 🚨 КНОПКА ТА ВІДСОТКИ
                                HStack(spacing: 12) {
                                    Text("\(tgManager.totalUploadProgress)%")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundColor(.blue)
                                    
                                    Button(action: { tgManager.cancelAllUploads() }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary.opacity(0.6))
                                            .font(.system(size: 16))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Відмінити всі відвантаження")
                                }
                            }
                            
                            HStack {
                                Text(tgManager.formatBytes(tgManager.uploadCompletedBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(tgManager.formatBytes(tgManager.uploadTotalBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            
                            ProgressView(value: Double(tgManager.totalUploadProgress), total: 100)
                                .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.05)))
                        .transition(.opacity)
                    }
                    
                    // 📥 БЛОК ЗАВАНТАЖЕННЯ
                    if !tgManager.downloadTransfers.isEmpty {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Завантаження (\(tgManager.downloadCompletedFiles) з \(tgManager.downloadTotalFiles) файлів)")
                                    .font(.subheadline).bold()
                                Spacer()
                                
                                // 🚨 КНОПКА ТА ВІДСОТКИ
                                HStack(spacing: 12) {
                                    Text("\(tgManager.totalDownloadProgress)%")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundColor(.green)
                                    
                                    Button(action: { tgManager.cancelAllDownloads() }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary.opacity(0.6))
                                            .font(.system(size: 16))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Відмінити всі завантаження")
                                }
                            }
                            
                            HStack {
                                Text(tgManager.formatBytes(tgManager.downloadCompletedBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(tgManager.formatBytes(tgManager.downloadTotalBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            
                            ProgressView(value: Double(tgManager.totalDownloadProgress), total: 100)
                                .progressViewStyle(LinearProgressViewStyle(tint: .green))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.05)))
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 15)
                
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(visibleTasks) { task in
                            HStack(spacing: 15) {
                                Image(systemName: task.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundColor(task.isUpload ? .blue : .green)
                                    .font(.title2)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.fileName)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    
                                    HStack {
                                        ProgressView(value: Double(task.progress), total: 100)
                                            .progressViewStyle(LinearProgressViewStyle(tint: task.isUpload ? .blue : .green))
                                        
                                        Text("\(task.progress)%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                            .frame(width: 40, alignment: .trailing)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .scale(scale: 0.01, anchor: .center).combined(with: .opacity)
                            ))
                        }
                    }
                    .padding(.horizontal)
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: visibleTasks.map { $0.id })
                }
            }
        }
    }
}

// MARK: - Вкладка: КЕРУВАННЯ
struct ManagementTabView: View {
    @StateObject private var tgManager = TelegramManager.shared
    @State private var showCreateAlert = false
    @State private var newStorageName = ""
    @State private var mountedDomains: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // 📦 ЗАГОЛОВОК З ІКОНКОЮ
            HStack(spacing: 12) {
                Spacer()
                Image("MirageIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
                
                Text("Мої сховища Mirage").font(.system(size: 22, weight: .bold))
                Spacer()
            }
            .padding(.top, 25).padding(.bottom, 20)

            List {
                if tgManager.isLoadingStorage {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if tgManager.storages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.plus").font(.system(size: 30)).foregroundColor(.secondary.opacity(0.5))
                        Text("У вас ще немає сховищ.").font(.subheadline).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(tgManager.storages) { storage in
                        StorageRowView(storage: storage, mountedDomains: $mountedDomains, refreshAction: refreshState)
                    }
                }
            }
            .listStyle(InsetListStyle()).padding(.horizontal).frame(height: 280)

            Button(action: { showCreateAlert = true }) {
                Label("Створити нове сховище", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered).controlSize(.large).tint(.accentColor)
            .padding(.horizontal, 30).padding(.vertical, 20)
            Spacer()
        }
        .onAppear { refreshState() }
        .alert("Нове сховище", isPresented: $showCreateAlert) {
            TextField("Назва", text: $newStorageName)
            Button("Скасувати", role: .cancel) { newStorageName = "" }
            Button("Створити") {
                if !newStorageName.trimmingCharacters(in: .whitespaces).isEmpty {
                    tgManager.createStorage(name: newStorageName)
                    newStorageName = ""
                }
            }
        }
    }
    
    private func refreshState() {
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            DispatchQueue.main.async { self.mountedDomains = Set(domains.map { $0.identifier.rawValue }) }
        }
    }
}

struct StorageRowView: View {
    let storage: UBoxStorage
    @Binding var mountedDomains: Set<String>
    var refreshAction: () -> Void
    @StateObject private var tgManager = TelegramManager.shared

    // 🚨 ДОДАНО: Стан для показу вікна бекапів
    @State private var showRestoreSheet = false

    var isMounted: Bool { mountedDomains.contains(storage.name) }

    var body: some View {
        HStack {
            Image(systemName: isMounted ? "externaldrive.fill" : "externaldrive")
                .foregroundColor(isMounted ? .green : .secondary).font(.system(size: 24))

            VStack(alignment: .leading) {
                Text(storage.name).font(.headline)
                Text(isMounted ? "Змонтовано" : "Готово до підключення").font(.caption).foregroundColor(.secondary)
            }
            Spacer()

            if isMounted {
                Button("Відключити") {
                    let domain = NSFileProviderDomain(identifier: .init(storage.name), displayName: "UBox: \(storage.name)")
                    
                    StorageEngine.shared.switchDatabase(name: storage.name)
                    StorageEngine.shared.cleanUpOrphanedFiles()
                    
                    tgManager.performDatabaseBackup(storageName: storage.name, chatId: storage.id) {
                        NSFileProviderManager.remove(domain) { _ in
                            DispatchQueue.global(qos: .background).async {
                                SettingsTabView.clearCacheFiles()
                                SettingsTabView.clearTDLibCacheFiles()
                            }
                            refreshAction()
                        }
                    }
                }.buttonStyle(.bordered).tint(.blue)
            } else {
                
                // 🚨 ДОДАНО: Блок кнопок, коли диск відключено
                HStack(spacing: 8) {
                    Button(action: { showRestoreSheet = true }) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Відновити")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    
                    Button("Підключити") {
                        let domain = NSFileProviderDomain(identifier: .init(storage.name), displayName: "UBox: \(storage.name)")
                        
                        StorageEngine.shared.switchDatabase(name: storage.name)
                        StorageEngine.shared.cleanUpOrphanedFiles()
                        
                        NSFileProviderManager.add(domain) { _ in refreshAction() }
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 8)
        // 🚨 ДОДАНО: Виклик діалогового вікна
        .sheet(isPresented: $showRestoreSheet) {
            RestoreBackupView(storage: storage)
        }
    }
}

struct SettingsTabView: View {
    @StateObject private var tgManager = TelegramManager.shared
    @State private var cacheSizeString: String = "Обчислення..."
    @State private var tdlibCacheSizeString: String = "Обчислення..." // 🚨 ДОДАНО: Для кешу Telegram
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 50, height: 50)
                            Text(initials).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundColor(.accentColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fullName).font(.headline)
                            Text("Telegram MTProto Session").font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            clearCacheManually()
                            clearTDLibCacheManually()
                            
                            // 🚨 ДОДАНО: Демонтуємо всі диски з Finder
                            NSFileProviderManager.removeAllDomains { error in
                                if let err = error {
                                    print("❌ Помилка демонтажу дисків при виході: \(err.localizedDescription)")
                                } else {
                                    print("🧹 Усі диски успішно демонтовано при виході з акаунта.")
                                }
                            }
                            
                            tgManager.logOut()
                        }) {
                            Text("Завершити сеанс")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                
                // 📦 КАРТКА 1: Локальний кеш UnlimBox (Черги)
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Кеш черги (UnlimBox)").font(.headline)
                            Text("Тимчасові файли завантажень").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(cacheSizeString).font(.system(.body, design: .monospaced)).foregroundColor(.primary).padding(.trailing, 8)
                        Button("Очистити") { clearCacheManually() }.buttonStyle(.bordered)
                    }
                }
                
                // 🤖 КАРТКА 2: Кеш самого ядра Telegram (TDLib)
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Кеш ядра Telegram").font(.headline)
                            Text("Завантажені медіа та документи").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(tdlibCacheSizeString).font(.system(.body, design: .monospaced)).foregroundColor(.primary).padding(.trailing, 8)
                        Button("Очистити") { clearTDLibCacheManually() }.buttonStyle(.bordered)
                    }
                }
                
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Скидання FileProvider").font(.headline)
                            Text("Видаляє всі диски з Finder. Використовуйте при зависаннях.").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Скинути диски") {
                            NSFileProviderManager.removeAllDomains { error in
                                if let err = error { print("❌ Помилка видалення: \(err.localizedDescription)") }
                                else { print("💣 СИСТЕМНИЙ КЕШ ОЧИЩЕНО! Усі диски видалено.") }
                            }
                        }.buttonStyle(.bordered).tint(.red)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text("Ваші дані захищені наскрізним шифруванням")
                }.font(.caption).foregroundColor(.secondary.opacity(0.8)).padding(.top, 10)
            }.padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { calculateCacheSize() }
    }
    
    private func calculateCacheSize() {
        DispatchQueue.global(qos: .background).async {
            // 1. Рахуємо кеш UnlimBox (Черги)
            var totalUnlimSize: Int64 = 0
            if let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") {
                let folders = ["UploadQueue", "DownloadQueue", "Downloads"]
                for folder in folders {
                    let folderURL = sharedContainer.appendingPathComponent(folder)
                    if let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey]) {
                        for case let fileURL as URL in enumerator {
                            if let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let size = attrs.fileSize { totalUnlimSize += Int64(size) }
                        }
                    }
                }
            }
            
            // 2. Рахуємо кеш TDLib (Файли Telegram)
            var totalTDLibSize: Int64 = 0
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            let tdlibURL = paths[0].appendingPathComponent("UnlimBoxTD_files") // Шлях до папки з файлами
            
            if let enumerator = FileManager.default.enumerator(at: tdlibURL, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let fileURL as URL in enumerator {
                    if let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let size = attrs.fileSize { totalTDLibSize += Int64(size) }
                }
            }
            
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            
            let unlimSizeStr = formatter.string(fromByteCount: totalUnlimSize)
            let tdlibSizeStr = formatter.string(fromByteCount: totalTDLibSize)
            
            DispatchQueue.main.async {
                self.cacheSizeString = unlimSizeStr
                self.tdlibCacheSizeString = tdlibSizeStr
            }
        }
    }
    
    // Очищення UnlimBox
    private func clearCacheManually() {
        self.cacheSizeString = "Очищення..."
        DispatchQueue.global(qos: .background).async { SettingsTabView.clearCacheFiles(); self.calculateCacheSize() }
    }
    
    // Очищення TDLib
    private func clearTDLibCacheManually() {
        self.tdlibCacheSizeString = "Очищення..."
        DispatchQueue.global(qos: .background).async { SettingsTabView.clearTDLibCacheFiles(); self.calculateCacheSize() }
    }
    
    // 🚨 ОНОВЛЕНО: Ядерне очищення кешу UnlimBox (Черги)
        static func clearCacheFiles() {
            guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else { return }
            let folders = ["UploadQueue", "DownloadQueue", "Downloads"]
            
            for folder in folders {
                let folderURL = sharedContainer.appendingPathComponent(folder)
                do {
                    // 1. Зносимо всю папку цілком
                    if FileManager.default.fileExists(atPath: folderURL.path) {
                        try FileManager.default.removeItem(at: folderURL)
                    }
                    // 2. Одразу створюємо нову, кристально чисту
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    print("🧹 [Cache] Папку \(folder) успішно знищено і перестворено!")
                } catch {
                    print("❌ [Cache-Error] Помилка очищення \(folder): \(error.localizedDescription)")
                }
            }
        }
        
        // 🚨 ОНОВЛЕНО: Ядерне очищення гігантського кешу TDLib
        static func clearTDLibCacheFiles() {
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            let tdlibURL = paths[0].appendingPathComponent("UnlimBoxTD_files")
            
            do {
                // 1. Жорстко видаляємо всю папку UnlimBoxTDV5_files
                if FileManager.default.fileExists(atPath: tdlibURL.path) {
                    try FileManager.default.removeItem(at: tdlibURL)
                }
                // 2. Створюємо її заново порожньою
                try FileManager.default.createDirectory(at: tdlibURL, withIntermediateDirectories: true)
                print("🗑✨ [Cache] Кеш TDLib успішно знищено і створено заново!")
            } catch {
                print("❌ [Cache-Error] Не вдалося видалити кеш TDLib: \(error.localizedDescription)")
            }
        }
    
    private var fullName: String {
        guard let user = tgManager.user else { return "Користувач" }
        return "\(user.firstName) \(user.lastName)".trimmingCharacters(in: .whitespaces)
    }
    private var initials: String {
        guard let user = tgManager.user else { return "U" }
        let first = user.firstName.first?.uppercased() ?? ""
        let last = user.lastName.first?.uppercased() ?? ""
        return "\(first)\(last)"
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(16).background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor))).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }
}


// 🚨 ПРЕМІАЛЬНИЙ ДИЗАЙН: Діалогове вікно для відновлення бази
struct RestoreBackupView: View {
    let storage: UBoxStorage
    @Environment(\.dismiss) var dismiss
    @StateObject private var tgManager = TelegramManager.shared

    @State private var backups: [BackupItem] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var selectedBackupId: Int64?
    
    // Стан для штучної затримки UI
    @State private var isUIProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            // 💎 ГАРНА ШАПКА
            VStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.blue)
                    .padding(.top, 15)
                
                Text("Історія відновлення")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Сховище: \(storage.name)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 20)
            
            Divider()

            // 📜 СПИСОК БЕКАПІВ У ВИГЛЯДІ КАРТОК
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(backups) { backup in
                        BackupRowCard(backup: backup, isSelected: selectedBackupId == backup.id)
                            .onTapGesture {
                                if !isUIProcessing { selectedBackupId = backup.id }
                            }
                            .onAppear {
                                if backup.id == backups.last?.id && hasMore {
                                    loadBackups(from: backup.messageId)
                                }
                            }
                    }
                    
                    if isLoading {
                        ProgressView().padding(.vertical, 20)
                    } else if backups.isEmpty && !isLoading {
                        VStack(spacing: 10) {
                            Image(systemName: "archivebox").font(.largeTitle).foregroundColor(.secondary.opacity(0.5))
                            Text("Бекапів ще немає").foregroundColor(.secondary)
                        }
                        .padding(.top, 40)
                    }
                }
                .padding(16)
            }
            .background(Color(NSColor.windowBackgroundColor)) // Системний фон для контрасту карток

            Divider()

            // 🎛 КНОПКИ ДІЙ
            HStack {
                Button("Скасувати") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isUIProcessing)
                
                Spacer()
                
                Button(action: startRestoreProcess) {
                    if isUIProcessing {
                        ProgressView().controlSize(.small).padding(.trailing, 4)
                        Text("Відновлення...")
                    } else {
                        Text("Відновити базу")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBackupId == nil || isUIProcessing)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 450, height: 550)
        .onAppear { loadBackups() }
    }
    
    // ⏳ ЛОГІКА ІЗ ЗАТРИМКОЮ МІНІМУМ 3 СЕКУНДИ
    private func startRestoreProcess() {
        guard let selectedId = selectedBackupId,
              let selectedBackup = backups.first(where: { $0.id == selectedId }) else { return }
        
        isUIProcessing = true
        let startTime = Date() // Фіксуємо час натискання
        
        tgManager.restoreDatabase(fileId: selectedBackup.fileId, storageName: storage.name) { success in
            // Вираховуємо, скільки часу зайняло реальне скачування
            let elapsed = Date().timeIntervalSince(startTime)
            // Якщо скачалося миттєво, чекаємо ще залишок від 3 секунд
            let delay = max(0, 3.0 - elapsed)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                isUIProcessing = false
                if success { dismiss() }
            }
        }
    }

    private func loadBackups(from messageId: Int64 = 0) {
        guard !isLoading && hasMore else { return }
        isLoading = true
        
        tgManager.fetchBackups(for: storage.id, fromMessageId: messageId) { newBackups in
            isLoading = false
            if newBackups.isEmpty { hasMore = false } else {
                let existingIds = Set(backups.map { $0.id })
                let uniqueBackups = newBackups.filter { !existingIds.contains($0.id) }
                backups.append(contentsOf: uniqueBackups)
                if newBackups.count < 10 { hasMore = false }
            }
        }
    }
}

// 🃏 ГАРНА КАРТКА БЕКАПУ
struct BackupRowCard: View {
    let backup: BackupItem
    let isSelected: Bool
    @StateObject private var tgManager = TelegramManager.shared
    
    var body: some View {
        HStack(spacing: 16) {
            // Іконка комп'ютера
            ZStack {
                Circle()
                    .fill(isSelected ? Color.blue : Color.blue.opacity(0.1))
                    .frame(width: 42, height: 42)
                
                Image(systemName: "macbook.and.iphone")
                    .foregroundColor(isSelected ? .white : .blue)
                    .font(.system(size: 16))
            }
            
            // Інформація
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.computerName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .blue : .primary)
                
                Text(backup.date.formatted(date: .long, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Розмір файлу
            Text(tgManager.formatBytes(backup.size))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            
            // Індикатор вибору
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .blue : .secondary.opacity(0.3))
                .font(.title2)
                .padding(.leading, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
        )
        // Маленька анімація при натисканні
        .scaleEffect(isSelected ? 0.98 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
    }
}
