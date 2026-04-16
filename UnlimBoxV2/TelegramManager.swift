import Foundation
import TDLibKit
import os
import SwiftUI
import Combine
import FileProvider

enum AppScreen {
    case initializing, welcome, enterPhone, enterCode, enterPassword, mainMenu
}

struct UBoxStorage: Identifiable, Hashable {
    let id: Int64
    let name: String
}

// 🚨 ДОДАНО: computerName для гарного інтерфейсу
struct BackupItem: Identifiable, Hashable {
    let id: Int64
    let messageId: Int64
    let fileId: Int
    let date: Foundation.Date
    let name: String
    let computerName: String // 👈 ДОДАЙ ЦЕ
    let size: Int64
}

// 🚨 ОНОВЛЕНО: Додали байти для підрахунку МБ
struct TransferTask: Identifiable {
    let id: String
    let fileName: String
    let isUpload: Bool
    var progress: Int
    var totalBytes: Int64 = 0
    var completedBytes: Int64 = 0
}

class TelegramManager: ObservableObject {
    static let shared = TelegramManager()
    
    private let clientManager = TDLibClientManager()
    private var client: TDLibClient!
    private let logger = Logger(subsystem: "com.viktor.UnlimBox", category: "Telegram")
    
    @Published var currentScreen: AppScreen = .initializing
    @Published var user: User?
    @Published var isLoading: Bool = false
    @Published var isLoadingStorage: Bool = true
    @Published var isReadyForPhone = false
    @Published var errorMessage: String? = nil
    @Published var storages: [UBoxStorage] = []
    
    @Published var activeTransfers: [TransferTask] = []
    // 🚨 ДОДАНО: Словник для зберігання таймерів авто-бекапу
    private var autoBackupWorkItems: [String: DispatchWorkItem] = [:]
    
    @Published var isRestoringDatabase: Bool = false
    private var pendingDBRestores: [Int: (storageName: String, completion: (Bool) -> Void)] = [:]
    
    // 🚨 ГЛОБАЛЬНИЙ ПЛАНУВАЛЬНИК ЗАТРИМОК
    private var nextDownloadApiTime = Date()
    private let downloadSchedulerQueue = DispatchQueue(label: "com.unlimbox.downloadScheduler")
    
    // MARK: - 🚨 Математика для відокремленого прогресу (МБ та Файли)
    var uploadTransfers: [TransferTask] { activeTransfers.filter { $0.isUpload } }
    var downloadTransfers: [TransferTask] { activeTransfers.filter { !$0.isUpload } }
    
    var totalUploadProgress: Int {
        guard !uploadTransfers.isEmpty else { return 0 }
        return uploadTransfers.reduce(0) { $0 + $1.progress } / uploadTransfers.count
    }
    var totalDownloadProgress: Int {
        guard !downloadTransfers.isEmpty else { return 0 }
        return downloadTransfers.reduce(0) { $0 + $1.progress } / downloadTransfers.count
    }
    
    // Статистика відправки
    var uploadTotalFiles: Int { uploadTransfers.count }
    var uploadCompletedFiles: Int { uploadTransfers.filter { $0.progress >= 100 }.count }
    var uploadTotalBytes: Int64 { uploadTransfers.reduce(0) { $0 + $1.totalBytes } }
    var uploadCompletedBytes: Int64 { uploadTransfers.reduce(0) { $0 + $1.completedBytes } }

    // Статистика скачування
    var downloadTotalFiles: Int { downloadTransfers.count }
    var downloadCompletedFiles: Int { downloadTransfers.filter { $0.progress >= 100 }.count }
    var downloadTotalBytes: Int64 { downloadTransfers.reduce(0) { $0 + $1.totalBytes } }
    var downloadCompletedBytes: Int64 { downloadTransfers.reduce(0) { $0 + $1.completedBytes } }

    // Конвертер байтів у читабельний вигляд (МБ, ГБ)
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var activeUploadPaths: [String: String] = [:]
    private var activeDownloadIds: [Int: String] = [:]
    
    private var activeUploads: Set<String> = []
    private var activeDownloads: Set<String> = []
    
    private var isAppJustStarted = true
    
    private let apiId: Int = 2681851
    private let apiHash: String = "8b90fbb1bf11ce17bf6b9bdb7adc1353"

    init() {
        recreateClient()
        setupInterProcessCommunication()
        clearLocalCache()
    }

    private func recreateClient() {
        self.client = clientManager.createClient(updateHandler: { [weak self] data, _ in
            self?.handleUpdate(data)
        })
        try? client.setLogVerbosityLevel(newVerbosityLevel: 1) { _ in }
    }

    private func setupInterProcessCommunication() {
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.unlimbox.newFileArrived"), object: nil, queue: .main) { [weak self] _ in
            self?.processIncomingFiles()
        }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.unlimbox.downloadRequest"), object: nil, queue: .main) { [weak self] _ in
            self?.processDownloadRequests()
        }
        
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.unlimbox.databaseModified"), object: nil, queue: .main) { [weak self] notification in
            // Витягуємо ім'я бази з об'єкта
            if let dbName = notification.object as? String {
                print("👂 [MainApp] Почув сигнал від Storage! Заводжу таймер для \(dbName)")
                self?.scheduleAutoBackup(for: dbName)
            }
        }
    }

    private func checkAndClearQueue() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.activeTransfers.isEmpty && self.activeTransfers.allSatisfy({ $0.progress >= 100 }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if self.activeTransfers.allSatisfy({ $0.progress >= 100 }) {
                        self.activeTransfers.removeAll()
                    }
                }
            }
        }
    }

    private func processIncomingFiles() {
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else { return }
        let uploadQueueURL = sharedContainer.appendingPathComponent("UploadQueue")
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: uploadQueueURL, includingPropertiesForKeys: nil) else { return }
        
        for metadataURL in files where metadataURL.pathExtension == "json" {
            let jsonFileName = metadataURL.lastPathComponent
            
            if jsonFileName.hasPrefix("msg_") || jsonFileName.hasPrefix("processing_") { continue }
            
            guard let data = try? Data(contentsOf: metadataURL),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let itemType = json["type"],
                  let realFileName = json["fileName"],
                  let storageName = json["storageName"] else { continue }
            
            if itemType == "folder" {
                try? FileManager.default.removeItem(at: metadataURL)
                continue
            }
            
            guard let tempID = json["tempID"] else { continue }
            
            let processingURL = uploadQueueURL.appendingPathComponent("processing_\(tempID).json")
            do { try FileManager.default.moveItem(at: metadataURL, to: processingURL) }
            catch { continue }
            
            if activeUploads.contains(tempID) { continue }
            activeUploads.insert(tempID)
            
            let chatId = self.storages.first(where: { $0.name == storageName })?.id ?? 0
            if chatId == 0 {
                try? FileManager.default.moveItem(at: processingURL, to: metadataURL)
                activeUploads.remove(tempID)
                continue
            }

            let dataURL = uploadQueueURL.appendingPathComponent("\(tempID).dat")
            let tempFolderURL = uploadQueueURL.appendingPathComponent(tempID + "_folder")
            try? FileManager.default.createDirectory(at: tempFolderURL, withIntermediateDirectories: true)
            let realFileURL = tempFolderURL.appendingPathComponent(realFileName)
            
            if FileManager.default.fileExists(atPath: dataURL.path) {
                try? FileManager.default.moveItem(at: dataURL, to: realFileURL)
            }
            
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: realFileURL.path)[.size] as? Int64) ?? 0
            json["size"] = "\(fileSize)"

            DispatchQueue.main.async { [weak self] in
                self?.activeUploadPaths[realFileURL.path] = tempID
                if !(self?.activeTransfers.contains(where: { $0.id == tempID }) ?? false) {
                    // 🚨 ОНОВЛЕНО: Передаємо fileSize одразу при старті
                    self?.activeTransfers.append(TransferTask(id: tempID, fileName: realFileName, isUpload: true, progress: 0, totalBytes: fileSize, completedBytes: 0))
                }
            }

            self.uploadFileToChat(fileURL: realFileURL, chatId: chatId) { [weak self] messageId in
                if let mId = messageId {
                    let finalMetadataURL = uploadQueueURL.appendingPathComponent("msg_\(mId).json")
                    if let updatedData = try? JSONSerialization.data(withJSONObject: json) {
                        try? updatedData.write(to: finalMetadataURL)
                        try? FileManager.default.removeItem(at: processingURL)
                    }
                } else {
                    try? FileManager.default.moveItem(at: processingURL, to: metadataURL)
                    DispatchQueue.main.async {
                        self?.activeUploads.remove(tempID)
                        self?.activeUploadPaths.removeValue(forKey: realFileURL.path)
                        self?.activeTransfers.removeAll(where: { $0.id == tempID })
                        self?.checkAndClearQueue()
                    }
                }
            }
        }
    }

    func selectAndUploadFile(for storage: UBoxStorage) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.title = "Виберіть файл для відправки в \(storage.name)"
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                let fileName = url.lastPathComponent
                let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider")
                let chatIdStr = sharedDefaults?.string(forKey: "ChatId_\(storage.name)") ?? "0"
                let chatId = Int64(chatIdStr) ?? 0
                
                self?.uploadFileToChat(fileURL: url, chatId: chatId) { messageId in
                    DispatchQueue.main.async {
                        if let mId = messageId {
                            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                            StorageEngine.shared.switchDatabase(name: storage.name)
                            StorageEngine.shared.saveItem(name: fileName, messageId: mId, size: fileSize, parentId: "rootContainer")
                            if let domain = NSFileProviderManager(for: .init(identifier: .init(storage.name), displayName: "")) {
                                domain.signalEnumerator(for: .rootContainer) { _ in }
                            }
                        }
                    }
                }
            }
        }
    }
        
    private func uploadFileToChat(fileURL: URL, chatId: Int64, completion: @escaping (String?) -> Void) {
        let canAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if canAccess { fileURL.stopAccessingSecurityScopedResource() } }
        
        let inputFile = InputFileLocal(path: fileURL.path)
        let document = InputMessageDocument(caption: nil, disableContentTypeDetection: false, document: .inputFileLocal(inputFile), thumbnail: nil)
        
        try? client.sendMessage(chatId: chatId, inputMessageContent: .inputMessageDocument(document), options: nil, replyMarkup: nil, replyTo: nil, topicId: nil) { result in
            if case .success(let message) = result {
                completion("\(message.id)")
            } else {
                completion(nil)
            }
        }
    }
    
    private func handleUpdate(_ data: Data) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["@type"] as? String else { return }
                        

            if type == "updateFile" {
                self.trackUIProgress(json: json)
            }

            if type == "updateAuthorizationState" {
                if let state = json["authorization_state"] as? [String: Any],
                   let stateType = state["@type"] as? String {
                    DispatchQueue.main.async { self.handleAuthState(type: stateType) }
                }
            }
            
            if type == "updateMessageSendSucceeded" {
                // 🚨 ВИТЯГУЄМО НОВІ ДАНІ: chatId та справжній newMsgId
                guard let oldMsgId = json["old_message_id"] as? Int64,
                      let message = json["message"] as? [String: Any],
                      let newMsgId = message["id"] as? Int64,
                      let chatId = message["chat_id"] as? Int64,
                      let content = message["content"] as? [String: Any] else { return }
                
                var finalRemoteId = ""
                var thumbnailFileId: Int? = nil
                
                if let document = content["document"] as? [String: Any],
                   let doc = document["document"] as? [String: Any] {
                    if let remote = doc["remote"] as? [String: Any] { finalRemoteId = remote["id"] as? String ?? "" }
                    if let thumb = document["thumbnail"] as? [String: Any], let file = thumb["file"] as? [String: Any] {
                        thumbnailFileId = file["id"] as? Int
                    }
                } else if let photoObj = content["photo"] as? [String: Any],
                          let sizes = photoObj["sizes"] as? [[String: Any]],
                          let lastSize = sizes.last,
                          let photo = lastSize["photo"] as? [String: Any] {
                    if let remote = photo["remote"] as? [String: Any] { finalRemoteId = remote["id"] as? String ?? "" }
                    if let firstSize = sizes.first, let pFile = firstSize["photo"] as? [String: Any] {
                        thumbnailFileId = pFile["id"] as? Int
                    }
                }
                
                if !finalRemoteId.isEmpty {
                    if let tId = thumbnailFileId {
                        try? self.client.downloadFile(fileId: tId, limit: 0, offset: 0, priority: 32, synchronous: true) { [weak self] res in
                            var thumbData: Data? = nil
                            if case .success(let tFile) = res, !tFile.local.path.isEmpty {
                                thumbData = try? Data(contentsOf: URL(fileURLWithPath: tFile.local.path))
                            }
                            // 🚨 Передаємо в базу
                            self?.processFinalDatabaseEntry(oldId: oldMsgId, remoteId: finalRemoteId, thumbData: thumbData, chatId: chatId, realMsgId: newMsgId)
                        }
                    } else {
                        // 🚨 Передаємо в базу
                        self.processFinalDatabaseEntry(oldId: oldMsgId, remoteId: finalRemoteId, thumbData: nil, chatId: chatId, realMsgId: newMsgId)
                    }
                }
            }
        }
                
    // 🚨 ОНОВЛЕНО: Додані chatId та realMsgId у параметри + Затримка 1.5 сек для Finder
    private func processFinalDatabaseEntry(oldId: Int64, remoteId: String, thumbData: Data? = nil, chatId: Int64, realMsgId: Int64) {
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else { return }
        let queueURL = sharedContainer.appendingPathComponent("UploadQueue")
        let metadataURL = queueURL.appendingPathComponent("msg_\(oldId).json")
        
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            guard let metaData = try? Data(contentsOf: metadataURL),
                  let metaJson = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
                  let fileName = metaJson["fileName"],
                  let storageName = metaJson["storageName"],
                  let tempID = metaJson["tempID"] else { return }
            
            let parentID = metaJson["parentID"] ?? "NSFileProviderRootContainerItemIdentifier"
            let fileSize = Int64(metaJson["size"] ?? "0") ?? 0
            
            // 🚨 1. ЖОРСТКО СТАВИМО 100% ДЛЯ FINDER (щоб він закрив кружечок)
            if let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider") {
                let safeSize = fileSize > 0 ? fileSize : 100
                sharedDefaults.set(safeSize, forKey: "UL_Progress_\(tempID)")
                sharedDefaults.set(safeSize, forKey: "UL_Total_\(tempID)")
                sharedDefaults.synchronize()
            }
            
            // 🚨 2. ДАЄМО ФАЙНДЕРУ 1.5 СЕКУНДИ НА АНІМАЦІЮ ПЕРЕД ВИДАЛЕННЯМ ТА ОНОВЛЕННЯМ БАЗИ
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.5) { [weak self] in
                
                StorageEngine.shared.switchDatabase(name: storageName)
                
                // ЗБЕРІГАЄМО В БАЗУ ДАННИХ
                StorageEngine.shared.finalizeUploadedFile(identifier: tempID, thumbData: thumbData, chatId: chatId, realMessageId: realMsgId)
                
                try? FileManager.default.removeItem(at: metadataURL)
                
                let successFileURL = queueURL.appendingPathComponent("success_\(tempID).txt")
                try? remoteId.write(to: successFileURL, atomically: true, encoding: .utf8)
                
                if let domain = NSFileProviderManager(for: .init(identifier: .init(storageName), displayName: "")) {
                    domain.signalEnumerator(for: .init(rawValue: parentID)) { _ in }
                }
                
                DispatchQueue.main.async {
                    self?.activeUploads.remove(tempID)
                    if let pathKey = self?.activeUploadPaths.first(where: { $1 == tempID })?.key {
                        self?.activeUploadPaths.removeValue(forKey: pathKey)
                    }
                    
                    if let idx = self?.activeTransfers.firstIndex(where: { $0.id == tempID }) {
                        self?.activeTransfers[idx].progress = 100
                        self?.activeTransfers[idx].completedBytes = self?.activeTransfers[idx].totalBytes ?? 0 // Для ідеальної картинки
                    }
                    self?.checkAndClearQueue()
                }
            }
        }
    }
    
    
    
    private func trackUIProgress(json: [String: Any]) {
            guard let file = json["file"] as? [String: Any],
                  let fileId = file["id"] as? Int,
                  let expectedSize = file["expected_size"] as? Int64, expectedSize > 0,
                  let remote = file["remote"] as? [String: Any],
                  let local = file["local"] as? [String: Any] else { return }

            let localPath = local["path"] as? String ?? ""

        if let isUploading = remote["is_uploading_active"] as? Bool, isUploading,
                       let uploaded = remote["uploaded_size"] as? Int64 {
                        let percentage = Int((Double(uploaded) / Double(expectedSize)) * 100)
                        DispatchQueue.main.async { [weak self] in
                            if let tempID = self?.activeUploadPaths[localPath] {
                                
                                // 🚨 ТРАНСЛЮЄМО ПРОГРЕС ВІДВАНТАЖЕННЯ ДЛЯ FINDER
                                self?.publishUploadProgress(id: tempID, uploaded: uploaded, total: expectedSize)
                                
                                if let idx = self?.activeTransfers.firstIndex(where: { $0.id == tempID }) {
                                    self?.activeTransfers[idx].progress = percentage
                                    self?.activeTransfers[idx].totalBytes = expectedSize
                                    self?.activeTransfers[idx].completedBytes = uploaded
                                }
                            }
                        }
                    }

            if let isDownloading = local["is_downloading_active"] as? Bool, isDownloading,
               let downloaded = local["downloaded_size"] as? Int64 {
                let percentage = Int((Double(downloaded) / Double(expectedSize)) * 100)
                DispatchQueue.main.async { [weak self] in
                    if let remoteId = self?.activeDownloadIds[fileId] {
                        
                        // 🚨 ТРАНСЛЮЄМО ФАЙНДЕРУ
                        self?.publishDownloadProgress(id: remoteId, downloaded: downloaded, total: expectedSize)
                        
                        if let idx = self?.activeTransfers.firstIndex(where: { $0.id == remoteId }) {
                            self?.activeTransfers[idx].progress = percentage
                            self?.activeTransfers[idx].totalBytes = expectedSize
                            self?.activeTransfers[idx].completedBytes = downloaded
                        }
                    }
                }
            }
        if let isCompleted = local["is_downloading_completed"] as? Bool, isCompleted {
            DispatchQueue.main.async { [weak self] in
                if let _ = self?.pendingDBRestores[fileId] {
                    self?.processDatabaseRestore(fileId: fileId, localPath: localPath, storageName: self?.pendingDBRestores[fileId]?.storageName ?? "", completion: self?.pendingDBRestores[fileId]?.completion ?? { _ in })
                }
            }
        }
        }
    
    // 🚨 ТРАНСЛЯЦІЯ ПРОГРЕСУ ВІДВАНТАЖЕННЯ ДЛЯ FINDER
        private func publishUploadProgress(id: String, uploaded: Int64, total: Int64) {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider") {
                sharedDefaults.set(uploaded, forKey: "UL_Progress_\(id)")
                sharedDefaults.set(total, forKey: "UL_Total_\(id)")
                sharedDefaults.synchronize()
            }
        }
    
    // 🚨 ТРАНСЛЯЦІЯ ПРОГРЕСУ ДЛЯ FINDER (з примусовим записом на диск)
        private func publishDownloadProgress(id: String, downloaded: Int64, total: Int64) {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider") {
                sharedDefaults.set(downloaded, forKey: "DL_Progress_\(id)")
                sharedDefaults.set(total, forKey: "DL_Total_\(id)")
                sharedDefaults.synchronize()
            }
        }
            
    
    private func handleAuthState(type: String) {
        switch type {
        case "authorizationStateWaitTdlibParameters": sendTdlibParameters()
        case "authorizationStateWaitPhoneNumber": isReadyForPhone = true; isAppJustStarted = false; if currentScreen != .enterPhone { withAnimation(.spring()) { isLoading = false; currentScreen = .welcome } } else { isLoading = false }
        case "authorizationStateWaitCode": if isAppJustStarted { cancelLogin() } else { if currentScreen != .enterCode { withAnimation(.spring()) { isLoading = false; currentScreen = .enterCode } } else { isLoading = false } }
        case "authorizationStateWaitPassword": if isAppJustStarted { cancelLogin() } else { if currentScreen != .enterPassword { withAnimation(.spring()) { isLoading = false; currentScreen = .enterPassword } } else { isLoading = false } }
        case "authorizationStateReady": isAppJustStarted = false; fetchMe(); loadChatsAndStorages(); if currentScreen != .mainMenu { withAnimation(.spring()) { isLoading = false; currentScreen = .mainMenu } } else { isLoading = false }
        case "authorizationStateLoggingOut": user = nil; clearLocalCache(); storages = []; isReadyForPhone = false; withAnimation(.spring()) { currentScreen = .welcome }
        case "authorizationStateClosed": isLoading = false; recreateClient()
        default: break
        }
    }

    private func sendTdlibParameters() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("UnlimBoxTD").path
        try? client.setTdlibParameters(apiHash: apiHash, apiId: apiId, applicationVersion: "2.0", databaseDirectory: dir, databaseEncryptionKey: Data(), deviceModel: "MacBook Air", filesDirectory: dir + "_files", systemLanguageCode: "uk", systemVersion: "macOS", useChatInfoDatabase: true, useFileDatabase: true, useMessageDatabase: true, useSecretChats: false, useTestDc: false) { _ in }
    }

    private func loadChatsAndStorages() {
        try? client.loadChats(chatList: .chatListMain, limit: 100) { [weak self] _ in self?.fetchStorages() }
    }
    
    func fetchStorages() {
        DispatchQueue.main.async { self.storages = []; self.isLoadingStorage = true }
        try? client.getChats(chatList: .chatListMain, limit: 100) { [weak self] result in
            guard let self = self, let chatIds = try? result.get().chatIds else { DispatchQueue.main.async { self?.isLoadingStorage = false }; return }
            var processedCount = 0
            for id in chatIds {
                try? self.client.getChat(chatId: id) { chatResult in
                    if let chat = try? chatResult.get(), chat.title.hasPrefix("UBox:") {
                        let cleanName = chat.title.replacingOccurrences(of: "UBox:", with: "").trimmingCharacters(in: .whitespaces)
                        let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider")
                        sharedDefaults?.set("\(chat.id)", forKey: "ChatId_\(cleanName)")
                        let newStorage = UBoxStorage(id: chat.id, name: cleanName)
                        DispatchQueue.main.async {
                            if !self.storages.contains(where: { $0.id == newStorage.id }) {
                                self.storages.append(newStorage)
                                self.storages.sort(by: { $0.name < $1.name })
                            }
                        }
                    }
                    processedCount += 1
                    if processedCount == chatIds.count {
                        DispatchQueue.main.async {
                            self.isLoadingStorage = false
                            self.processIncomingFiles()
                        }
                    }
                }
            }
        }
    }

    func createStorage(name: String) {
        isLoading = true
        try? client.createNewSupergroupChat(description: "Сховище файлів UnlimBox", forImport: false, isChannel: true, isForum: false, location: nil, messageAutoDeleteTime: 0, title: "UBox: \(name)") { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                if case .success(let chat) = result {
                    let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider")
                    sharedDefaults?.set("\(chat.id)", forKey: "ChatId_\(name)")
                    sharedDefaults?.synchronize()
                    self?.fetchStorages()
                } else if case .failure(let error) = result {
                    self?.errorMessage = "Не вдалося створити сховище: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func extractRemoteId(from content: MessageContent) -> String? {
            switch content {
            case .messageDocument(let doc):
                return doc.document.document.remote.id
            case .messagePhoto(let photo):
                return photo.photo.sizes.last?.photo.remote.id
            default:
                return nil
            }
        }

    private func processDownloadRequests() {
            guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else { return }
            let queueURL = sharedContainer.appendingPathComponent("DownloadQueue")
            let downloadsURL = sharedContainer.appendingPathComponent("Downloads")
            
            guard let requests = try? FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: nil) else { return }
            
            for reqURL in requests where reqURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: reqURL),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let originalFinderId = json["fileId"],
                      let name = json["fileName"],
                      let storageName = json["storageName"] else { continue }
                
                if activeDownloads.contains(originalFinderId) { continue }
                activeDownloads.insert(originalFinderId)
                
                // 1. МИТТЄВО ДОДАЄМО В ІНТЕРФЕЙС
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if !self.activeTransfers.contains(where: { $0.id == originalFinderId }) {
                        self.activeTransfers.append(TransferTask(id: originalFinderId, fileName: name, isUpload: false, progress: 0, totalBytes: 0, completedBytes: 0))
                    }
                }
                
                // 2. ГЛОБАЛЬНИЙ ТАЙМЕР
                downloadSchedulerQueue.async { [weak self] in
                    guard let self = self else { return }
                    
                    let now = Date()
                    if self.nextDownloadApiTime < now {
                        self.nextDownloadApiTime = now
                    }
                    
                    self.nextDownloadApiTime.addTimeInterval(0.15)
                    let delay = self.nextDownloadApiTime.timeIntervalSince(now)
                    
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self else { return }
                        
                        print("\n⏳ [Scheduler] Старт обробки: \(name) (Чекав у черзі: \(String(format: "%.2f", delay)) сек)")
                        
                        // 3. ШУКАЄМО КООРДИНАТИ ФАЙЛУ В БАЗІ
                        StorageEngine.shared.switchDatabase(name: storageName)
                        guard let dbItem = StorageEngine.shared.getFile(identifier: originalFinderId) else {
                            print("❌ [Download] Критична помилка: Файл не знайдено в SQLite: \(name)")
                            try? FileManager.default.removeItem(at: reqURL)
                            DispatchQueue.main.async {
                                self.activeDownloads.remove(originalFinderId)
                                self.activeTransfers.removeAll(where: { $0.id == originalFinderId })
                                self.checkAndClearQueue()
                            }
                            return
                        }
                        
                        print("📡 [Telegram-Request] Йдемо за свіжим повідомленням (Chat: \(dbItem.chatId), Msg: \(dbItem.realMessageId))")
                        
                        // 4. ЙДЕМО В ТЕЛЕГРАМ ЗА СВІЖИМ ID
                        try? self.client.getMessage(chatId: dbItem.chatId, messageId: dbItem.realMessageId) { [weak self] result in
                            guard let self = self else { return }
                            
                            var actualRemoteId = originalFinderId
                            
                            if case .success(let message) = result {
                                if let newId = self.extractRemoteId(from: message.content) {
                                    
                                    // 🔥 ВИВОДИМО ПОРІВНЯННЯ В КОНСОЛЬ
                                    print("==================================================")
                                    print("🔍 [ID-CHECK] Файл: \(name)")
                                    print("📂 [СТАРИЙ ID з бази]: \(originalFinderId)")
                                    print("🌐 [НОВИЙ ID з Telegram]: \(newId)")
                                    
                                    if newId != originalFinderId {
                                        print("🔄 ВИСНОВОК: ID РІЗНІ! Ключ протух. Оновлюємо в базі та качаємо по-новому.")
                                        actualRemoteId = newId
                                    } else {
                                        print("✅ ВИСНОВОК: ID ОДНАКОВІ! Ключ ще живий.")
                                    }
                                    print("==================================================")
                                    
                                } else {
                                    print("⚠️ [ID-CHECK] У повідомленні немає файлу. Використовуємо старий ID.")
                                }
                            } else if case .failure(let error) = result {
                                print("⚠️ [ID-CHECK] Не вдалося оновити повідомлення (\(error.localizedDescription)). Пробуємо старий ID.")
                            }
                            
                            print("🚀 [Download] Запускаємо скачування по ID: \(actualRemoteId.prefix(15))...")
                            
                            // 5. СКАЧУЄМО ПО АКТУАЛЬНОМУ ID
                            try? self.client.getRemoteFile(fileType: nil, remoteFileId: actualRemoteId) { [weak self] getFileResult in
                                guard let self = self else { return }
                                
                                if case .success(let file) = getFileResult {
                                    DispatchQueue.main.async {
                                        self.activeDownloadIds[file.id] = originalFinderId
                                    }
                                    
                                    try? self.client.downloadFile(fileId: file.id, limit: 0, offset: 0, priority: 32, synchronous: true) { downloadResult in
                                        if case .success(let downloadedFile) = downloadResult {
                                            guard downloadedFile.local.isDownloadingCompleted else {
                                                print("❌ [Download] Файл \(name) не докачався.")
                                                DispatchQueue.main.async {
                                                    self.activeDownloads.remove(originalFinderId)
                                                    self.activeDownloadIds.removeValue(forKey: file.id)
                                                    self.activeTransfers.removeAll(where: { $0.id == originalFinderId })
                                                    self.checkAndClearQueue()
                                                }
                                                return
                                            }
                                            
                                            let localPath = downloadedFile.local.path
                                            if !localPath.isEmpty {
                                                let tempLocation = downloadsURL.appendingPathComponent("temp_\(originalFinderId)_\(name)")
                                                let finalLocation = downloadsURL.appendingPathComponent("\(originalFinderId)_\(name)")
                                                
                                                try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
                                                try? FileManager.default.removeItem(at: tempLocation)
                                                try? FileManager.default.copyItem(at: URL(fileURLWithPath: localPath), to: tempLocation)
                                                try? FileManager.default.removeItem(at: finalLocation)
                                                try? FileManager.default.moveItem(at: tempLocation, to: finalLocation)
                                                
                                                try? FileManager.default.removeItem(at: reqURL)
                                                
                                                if let domain = NSFileProviderManager(for: .init(identifier: .init(storageName), displayName: "")) {
                                                    domain.signalEnumerator(for: .init(rawValue: originalFinderId)) { _ in }
                                                }
                                                print("🎯 [Success] Файл \(name) успішно передано Файндеру!")
                                            }
                                            
                                            DispatchQueue.main.async {
                                                self.activeDownloads.remove(originalFinderId)
                                                self.activeDownloadIds.removeValue(forKey: file.id)
                                                if let idx = self.activeTransfers.firstIndex(where: { $0.id == originalFinderId }) {
                                                    self.activeTransfers[idx].progress = 100
                                                    self.activeTransfers[idx].completedBytes = self.activeTransfers[idx].totalBytes
                                                }
                                                self.checkAndClearQueue()
                                            }
                                            
                                        } else {
                                            print("❌ [Download] Telegram повернув помилку завантаження для \(name)")
                                            DispatchQueue.main.async {
                                                self.activeDownloads.remove(originalFinderId)
                                                self.activeDownloadIds.removeValue(forKey: file.id)
                                                self.activeTransfers.removeAll(where: { $0.id == originalFinderId })
                                                self.checkAndClearQueue()
                                            }
                                        }
                                    }
                                } else {
                                    print("❌ [Download] getRemoteFile не знайшов файл на серверах Telegram: \(name)")
                                    try? FileManager.default.removeItem(at: reqURL)
                                    DispatchQueue.main.async {
                                        self.activeDownloads.remove(originalFinderId)
                                        self.activeTransfers.removeAll(where: { $0.id == originalFinderId })
                                        self.checkAndClearQueue()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    
    private func clearLocalCache() {
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else { return }
        let foldersToClear = ["UploadQueue", "DownloadQueue", "Downloads"]
        for folder in foldersToClear {
            let folderURL = sharedContainer.appendingPathComponent(folder)
            guard let files = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) else { continue }
            for fileURL in files { try? FileManager.default.removeItem(at: fileURL) }
        }
    }
    // MARK: - 🚨 СКАСУВАННЯ ЧЕРГИ ТА ХАРД-РЕСЕТ ДИСКІВ
        
    private func hardResetMountedDomains() {
            // Отримуємо всі активні диски
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                // 🚨 ВИПРАВЛЕНО: domains не є Optional, тому просто перевіряємо, чи масив не порожній
                guard !domains.isEmpty else { return }
                
                for domain in domains {
                    // 1. Жорстко відключаємо диск (Finder миттєво зупиняє всі копіювання та завислі черги)
                    NSFileProviderManager.remove(domain) { _ in
                        // 2. Одразу підключаємо його назад, щоб користувач не втратив доступ
                        NSFileProviderManager.add(domain) { error in
                            if let err = error {
                                print("❌ [App] Помилка перепідключення диска \(domain.displayName): \(err.localizedDescription)")
                            } else {
                                print("🔄 [App] Диск \(domain.displayName) успішно перезавантажено (Hard Reset)")
                            }
                        }
                    }
                }
            }
        }
    
    // 🚨 ОНОВЛЕНО: Тепер ми передаємо chatId напряму, щоб він ніколи не губився
        func performDatabaseBackup(storageName: String, chatId: Int64, completion: @escaping () -> Void) {
            guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else {
                completion()
                return
            }

            let dbURL = sharedContainer.appendingPathComponent(storageName.hasSuffix(".sqlite") ? storageName : "\(storageName).sqlite")
            
            if let files = try? FileManager.default.contentsOfDirectory(at: sharedContainer, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("backup_\(storageName)") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            
            let computerName = Host.current().localizedName ?? "Mac"
                    // Очищаємо ім'я від пробілів та спецсимволів для безпеки файлової системи
            let safeComputerName = computerName.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")

            let backupFileName = "backup_\(safeComputerName)_\(storageName)_\(UUID().uuidString.prefix(8)).sqlite"
            let backupURL = sharedContainer.appendingPathComponent(backupFileName)

            StorageEngine.shared.createSafeBackup(from: dbURL, to: backupURL)

            // 🚨 Перевіряємо, чи валідний chatId
            guard chatId != 0 else {
                print("❌ [DB-Sync] ChatId дорівнює нулю, скасовуємо відправку.")
                completion()
                return
            }

            let inputFile = InputFileLocal(path: backupURL.path)
            let caption = FormattedText(entities: [], text: "#db_sync")
            let document = InputMessageDocument(caption: caption, disableContentTypeDetection: true, document: .inputFileLocal(inputFile), thumbnail: nil)

            try? client.sendMessage(
                        chatId: chatId,
                        inputMessageContent: .inputMessageDocument(document),
                        options: nil,
                        replyMarkup: nil,
                        replyTo: nil,
                        topicId: nil
            ) { result in
                if case .success(_) = result {
                    print("📤 [DB-Sync] Почалося відвантаження бази \(storageName)...")
                }
                DispatchQueue.main.async { completion() }
            }
        }
    
    // 🚨 ОНОВЛЕНО: Беремо ChatId ПРЯМО з оперативної пам'яті програми, ніяких UserDefaults!
        func scheduleAutoBackup(for rawStorageName: String) {
            // 1. Відрізаємо .sqlite для точного пошуку
            let storageName = rawStorageName.replacingOccurrences(of: ".sqlite", with: "")
            
            // 🚨 2. БЕРЕМО CHAT ID НАПРЯМУ З ТВОГО МАСИВУ СХОВИЩ
            guard let storage = self.storages.first(where: { $0.name == storageName }) else {
                print("❌ [Auto-Backup] Помилка! Сховище '\(storageName)' не знайдено в пам'яті. Таймер скасовано.")
                return
            }
            
            let chatId = storage.id

            // 3. Скасовуємо попередній таймер
            autoBackupWorkItems[storageName]?.cancel()
            
            print("⏱ [Auto-Backup] Таймер на 10 сек ЗАПУЩЕНО для \(storageName)! (ChatID: \(chatId))")

            // 4. Створюємо завдання
            let workItem = DispatchWorkItem { [weak self] in
                print("⏳ [Auto-Backup] Минуло 10 секунд! Запускаю відправку для \(storageName)...")
                self?.performDatabaseBackup(storageName: storageName, chatId: chatId) { }
            }

            autoBackupWorkItems[storageName] = workItem
            
            // 5. Запускаємо з високим пріоритетом
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0, execute: workItem)
        }
        
    func cancelAllUploads() {
            DispatchQueue.main.async { [weak self] in
                // 1. Очищаємо інтерфейс миттєво
                self?.activeTransfers.removeAll { $0.isUpload }
                self?.activeUploads.removeAll()
                self?.activeUploadPaths.removeAll()
                
                // 2. Вбиваємо всі файли з черги на диску ТА чистимо базу даних
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else { return }
                    let uploadQueueURL = sharedContainer.appendingPathComponent("UploadQueue")
                    
                    if let files = try? FileManager.default.contentsOfDirectory(at: uploadQueueURL, includingPropertiesForKeys: nil) {
                        for file in files {
                            
                            // 🚨 МАГІЯ ТУТ: Перед тим як видалити завдання, читаємо його і видаляємо "привида" з бази даних
                            if file.pathExtension == "json" {
                                if let data = try? Data(contentsOf: file),
                                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                                   let tempID = json["tempID"],
                                   let storageName = json["storageName"] {
                                    
                                    StorageEngine.shared.switchDatabase(name: storageName)
                                    StorageEngine.shared.deleteFile(identifier: tempID)
                                    print("🧹 [App] Видалено тимчасовий файл-привид з бази: \(tempID)")
                                }
                            }
                            
                            // Тепер безпечно видаляємо сам файл з черги
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                    print("🛑 [App] Папку UploadQueue повністю очищено.")
                    
                    // 3. Робимо Хард-Ресет дисків
                    self?.hardResetMountedDomains()
                }
            }
        }
        
        func cancelAllDownloads() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // 1. Зупиняємо процес прямо в TDLib
                for fileId in self.activeDownloadIds.keys {
                    try? self.client.cancelDownloadFile(fileId: fileId, onlyIfPending: false) { _ in }
                }
                
                // 2. Очищаємо інтерфейс
                self.activeTransfers.removeAll { !$0.isUpload }
                self.activeDownloads.removeAll()
                self.activeDownloadIds.removeAll()
                
                // 3. Очищаємо папку запитів Finder
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else { return }
                    let queueURL = sharedContainer.appendingPathComponent("DownloadQueue")
                    
                    // Жорстко видаляємо АБСОЛЮТНО ВСЕ в папці DownloadQueue
                    if let files = try? FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: nil) {
                        for file in files {
                            try? FileManager.default.removeItem(at: file)
                        }
                    }
                    print("🛑 [App] Папку DownloadQueue повністю очищено.")
                    
                    // 4. 🚨 Робимо Хард-Ресет дисків
                    self?.hardResetMountedDomains()
                }
            }
        }
    
    // 🚨 ДОДАНО: Безпечне вимкнення TDLib (щоб не було крашу EXC_BAD_ACCESS)
        func shutDownSafely() {
            print("🛑 Відправляємо команду Close в TDLib...")
            try? client.close { _ in
                print("✅ TDLib успішно зупинено!")
            }
        }
    
    // MARK: - 🚨 РОБОТА З БЕКАПАМИ (Відновлення)
        func fetchBackups(for chatId: Int64, fromMessageId: Int64 = 0, limit: Int = 10, completion: @escaping ([BackupItem]) -> Void) {
            
            try? client.searchChatMessages(
                chatId: chatId,
                filter: .searchMessagesFilterDocument,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: 0,
                query: "", // 🚨 ПУСТИЙ ЗАПИТ! Тепер ми не чекаємо індексації хештегів Telegram
                senderId: nil,
                topicId: nil
            ) { result in
                
                if case .success(let messages) = result {
                    var items: [BackupItem] = []
                    
                    for msg in messages.messages {
                        guard case .messageDocument(let docContent) = msg.content else { continue }
                        
                        let doc = docContent.document
                        let fileId = doc.document.id
                        let caption = docContent.caption.text
                        let date = Foundation.Date(timeIntervalSince1970: TimeInterval(msg.date))
                        
                        // 🚨 ЛОКАЛЬНИЙ ФІЛЬТР: Беремо тільки файли, що є бекапами
                        guard doc.fileName.hasPrefix("backup_") || caption.contains("#db_sync") else { continue }
                        
                        // 🚨 ВИТЯГУЄМО ІМ'Я КОМП'ЮТЕРА з тексту "[MacBook] 14:20"
                        var computerName = "Невідомий пристрій"
                        if let startIdx = caption.firstIndex(of: "["), let endIdx = caption.firstIndex(of: "]") {
                            let innerStart = caption.index(after: startIdx)
                            computerName = String(caption[innerStart..<endIdx])
                        } else if let parsedName = doc.fileName.components(separatedBy: "_").dropFirst().first {
                            computerName = parsedName // Резервний варіант з імені файлу
                        }
                        
                        let size = Int64(doc.document.size)
                        
                        items.append(BackupItem(id: msg.id, messageId: msg.id, fileId: fileId, date: date, name: doc.fileName, computerName: computerName, size: size))
                    }
                    
                    DispatchQueue.main.async { completion(items) }
                } else {
                    DispatchQueue.main.async { completion([]) }
                }
            }
        }
    // MARK: - 🚨 ЛОГІКА ВІДНОВЛЕННЯ БАЗИ
        func restoreDatabase(fileId: Int, storageName: String, completion: @escaping (Bool) -> Void) {
            
            // 🚨 1. ЗАПИСУЄМО МИТТЄВО: Без DispatchQueue.main.async, щоб TDLib не встиг "обігнати" нас
            self.isRestoringDatabase = true
            self.pendingDBRestores[fileId] = (storageName, completion)
            
            // Запитуємо завантаження файлу
            try? client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 32, synchronous: true) { [weak self] result in
                // Якщо файл ВЖЕ був скачаний раніше і лежить у кеші
                if case .success(let file) = result, file.local.isDownloadingCompleted {
                    // 🚨 2. Повертаємо виклик на головний потік, щоб безпечно прочитати словник
                    DispatchQueue.main.async {
                        self?.processDatabaseRestore(fileId: fileId, localPath: file.local.path, storageName: storageName, completion: completion)
                    }
                }
            }
        }
        
        // Внутрішня функція безпечної підміни файлу
        func processDatabaseRestore(fileId: Int, localPath: String, storageName: String, completion: @escaping (Bool) -> Void) {
            
            // 🚨 3. Читаємо словник на головному потоці (безпечно)
            guard let task = pendingDBRestores[fileId] else { return }
            pendingDBRestores.removeValue(forKey: fileId)
            
            // 🚨 4. Перекидаємо ВАЖКУ роботу з файлами на фоновий потік, щоб не "заморожувати" анімацію UI
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else {
                    DispatchQueue.main.async { self?.isRestoringDatabase = false; completion(false) }
                    return
                }

                let dbURL = sharedContainer.appendingPathComponent(storageName.hasSuffix(".sqlite") ? storageName : "\(storageName).sqlite")
                let downloadedFileURL = URL(fileURLWithPath: localPath)

                // Відключаємо поточну базу, щоб зняти "блок" з файлу
                StorageEngine.shared.switchDatabase(name: "temp_dummy_db")

                do {
                    // Жорстко видаляємо стару базу ТА ЇЇ КЕШІ
                    try? FileManager.default.removeItem(at: dbURL)
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
                    
                    // Копіюємо новий бекап на її місце
                    try FileManager.default.copyItem(at: downloadedFileURL, to: dbURL)

                    // Підключаємо базу назад
                    StorageEngine.shared.switchDatabase(name: storageName)

                    // Кажемо Finder'у "Онови вікно!"
                    if let domain = NSFileProviderManager(for: .init(identifier: .init(storageName), displayName: "")) {
                        domain.signalEnumerator(for: .rootContainer) { _ in }
                    }

                    print("✅ [DB-Restore] Базу \(storageName) успішно відновлено!")
                    // Повертаємо результат в UI
                    DispatchQueue.main.async { self?.isRestoringDatabase = false; completion(true) }
                    
                } catch {
                    print("❌ [DB-Restore] Помилка: \(error.localizedDescription)")
                    StorageEngine.shared.switchDatabase(name: storageName)
                    DispatchQueue.main.async { self?.isRestoringDatabase = false; completion(false) }
                }
            }
        }
    
    func startAuthFlow() { errorMessage = nil; if isReadyForPhone { withAnimation { currentScreen = .enterPhone } } else { isLoading = true } }
    func setPhoneNumber(_ phone: String) { isLoading = true; errorMessage = nil; try? client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil) { [weak self] r in DispatchQueue.main.async { if case .failure(_) = r { self?.isLoading = false; self?.errorMessage = "Помилка номеру" } } } }
    func checkCode(_ code: String) { isLoading = true; errorMessage = nil; try? client.checkAuthenticationCode(code: code) { [weak self] r in DispatchQueue.main.async { if case .failure(_) = r { self?.isLoading = false; self?.errorMessage = "Невірний код" } } } }
    func checkPassword(_ pwd: String) { isLoading = true; errorMessage = nil; try? client.checkAuthenticationPassword(password: pwd) { [weak self] r in DispatchQueue.main.async { if case .failure(_) = r { self?.isLoading = false; self?.errorMessage = "Невірний пароль" } } } }
    func fetchMe() { try? client.getMe { [weak self] r in if let u = try? r.get() { DispatchQueue.main.async { self?.user = u } } } }
    func cancelLogin() { isLoading = true; errorMessage = nil; try? client.logOut { _ in } }
    func logOut() { isLoading = true; try? client.logOut { _ in } }
}
