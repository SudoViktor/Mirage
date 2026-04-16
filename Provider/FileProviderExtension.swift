import FileProvider
import UniformTypeIdentifiers

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    let domain: NSFileProviderDomain
    
    required init(domain: NSFileProviderDomain) { self.domain = domain; super.init() }
    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(FileProviderItem(identifier: .rootContainer, parentIdentifier: .rootContainer, name: "UnlimBox", type: .folder), nil)
            return Progress()
        }
        
        StorageEngine.shared.switchDatabase(name: domain.identifier.rawValue)
        if let dbItem = StorageEngine.shared.getFile(identifier: identifier.rawValue) {
            let ext = (dbItem.name as NSString).pathExtension
            let finalType: UTType
            
            if dbItem.isFolder {
                finalType = .folder
            } else {
                finalType = UTType(filenameExtension: ext) ?? .data
            }
            
            completionHandler(FileProviderItem(
                identifier: identifier,
                parentIdentifier: NSFileProviderItemIdentifier(dbItem.parentId),
                name: dbItem.name,
                type: finalType,
                size: dbItem.size,
                hasThumbnail: dbItem.thumbnailData != nil
            ), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func enumerator(for container: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        return FileProviderEnumerator(containerIdentifier: container, domainIdentifier: domain.identifier.rawValue)
    }

    // --- DOWNLOAD ---
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        
        if itemIdentifier.rawValue.hasPrefix("phantom_") {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 100)
        }
        
        StorageEngine.shared.switchDatabase(name: domain.identifier.rawValue)
        guard let dbItem = StorageEngine.shared.getFile(identifier: itemIdentifier.rawValue) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress(totalUnitCount: 100)
        }
        
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else {
            return Progress(totalUnitCount: 100)
        }
        
        let downloadDir = sharedContainer.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let localURL = downloadDir.appendingPathComponent("\(dbItem.id)_\(dbItem.name)")
        
        let ext = (dbItem.name as NSString).pathExtension
        let itemType: UTType = dbItem.isFolder ? .folder : (UTType(filenameExtension: ext) ?? .data)
        
        if itemType.conforms(to: .folder) || itemType.conforms(to: .directory) {
            try? FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            let providerItem = FileProviderItem(identifier: itemIdentifier, parentIdentifier: NSFileProviderItemIdentifier(dbItem.parentId), name: dbItem.name, type: itemType, size: dbItem.size, hasThumbnail: false)
            
            let progress = Progress(totalUnitCount: 100)
            progress.completedUnitCount = 100
            completionHandler(localURL, providerItem, nil)
            return progress
        }
        
        if dbItem.size == 0 && !dbItem.isFolder {
            FileManager.default.createFile(atPath: localURL.path, contents: Data(), attributes: nil)
            let providerItem = FileProviderItem(identifier: itemIdentifier, parentIdentifier: NSFileProviderItemIdentifier(dbItem.parentId), name: dbItem.name, type: itemType, size: dbItem.size, hasThumbnail: false)
            
            let progress = Progress(totalUnitCount: 100)
            progress.completedUnitCount = 100
            completionHandler(localURL, providerItem, nil)
            return progress
        }
        
        let expectedSize = dbItem.size > 0 ? dbItem.size : 100
        let progress = Progress(totalUnitCount: expectedSize)
        progress.completedUnitCount = 0
        progress.isCancellable = true
        
        if FileManager.default.fileExists(atPath: localURL.path) {
            let providerItem = FileProviderItem(identifier: itemIdentifier, parentIdentifier: NSFileProviderItemIdentifier(dbItem.parentId), name: dbItem.name, type: itemType, size: dbItem.size, hasThumbnail: dbItem.thumbnailData != nil)
            progress.completedUnitCount = expectedSize
            completionHandler(localURL, providerItem, nil)
            return progress
        }
        
        let queueURL = sharedContainer.appendingPathComponent("DownloadQueue")
        try? FileManager.default.createDirectory(at: queueURL, withIntermediateDirectories: true)
        let requestURL = queueURL.appendingPathComponent("\(dbItem.id).json")
        
        let reqData: [String: String] = ["fileId": dbItem.id, "fileName": dbItem.name, "storageName": domain.identifier.rawValue]
        if let json = try? JSONSerialization.data(withJSONObject: reqData) { try? json.write(to: requestURL) }
        
        if let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider") {
            sharedDefaults.removeObject(forKey: "DL_Progress_\(dbItem.id)")
            sharedDefaults.removeObject(forKey: "DL_Total_\(dbItem.id)")
            sharedDefaults.synchronize()
        }
        
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.unlimbox.downloadRequest"), object: nil, userInfo: nil, deliverImmediately: true)
        
        let fileId = dbItem.id
        
        // 🚨 ВИПРАВЛЕННЯ: Використовуємо глобальну чергу замість створення сотень нових потоків!
        let progressTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // 🚨 Збільшили інтервал до 0.5s, щоб не душити UserDefaults
        progressTimer.schedule(deadline: .now(), repeating: 0.5)
        
        progressTimer.setEventHandler {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider") {
                sharedDefaults.synchronize()
                let downloaded = sharedDefaults.object(forKey: "DL_Progress_\(fileId)") as? Int64 ?? 0
                let total = sharedDefaults.object(forKey: "DL_Total_\(fileId)") as? Int64 ?? expectedSize
                let safeTotal = total > 0 ? total : 100
                let safeDownloaded = downloaded > safeTotal ? safeTotal : downloaded
                
                progress.totalUnitCount = safeTotal
                progress.completedUnitCount = safeDownloaded
                if safeDownloaded >= safeTotal && safeDownloaded > 0 { progressTimer.cancel() }
            }
        }
        progressTimer.resume()
        
        let wrappedCompletion: (URL?, NSFileProviderItem?, Error?) -> Void = { url, item, error in
            progressTimer.cancel()
            completionHandler(url, item, error)
        }
        
        // 🚨 ВИПРАВЛЕННЯ: Змінено ліміт з 240 на 86400 (12 годин), щоб великі черги не відвалювались по тайм-ауту
        waitForFile(at: localURL, itemIdentifier: itemIdentifier, dbItem: dbItem, itemType: itemType, attemptsLeft: 86400, completionHandler: wrappedCompletion)
        return progress
    }
    
    private func waitForFile(at localURL: URL, itemIdentifier: NSFileProviderItemIdentifier, dbItem: DBItem, itemType: UTType, attemptsLeft: Int, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) {
        if FileManager.default.fileExists(atPath: localURL.path) {
            let providerItem = FileProviderItem(identifier: itemIdentifier, parentIdentifier: NSFileProviderItemIdentifier(dbItem.parentId), name: dbItem.name, type: itemType, size: dbItem.size, hasThumbnail: dbItem.thumbnailData != nil)
            completionHandler(localURL, providerItem, nil)
            return
        }
        if attemptsLeft <= 0 {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            return
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.5) {
            self.waitForFile(at: localURL, itemIdentifier: itemIdentifier, dbItem: dbItem, itemType: itemType, attemptsLeft: attemptsLeft - 1, completionHandler: completionHandler)
        }
    }
    
    // --- UPLOAD ---
    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        
        let fileName = itemTemplate.filename
        let storageName = domain.identifier.rawValue
        let parentID = itemTemplate.parentItemIdentifier.rawValue
        
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return Progress()
        }
        
        let uploadQueueURL = sharedContainer.appendingPathComponent("UploadQueue")
        try? FileManager.default.createDirectory(at: uploadQueueURL, withIntermediateDirectories: true, attributes: nil)
        
        let isFolder = itemTemplate.contentType == .folder || (url == nil && !fields.contains(.contents))

        if isFolder {
            let folderID = "folder_\(UUID().uuidString)"
            StorageEngine.shared.switchDatabase(name: storageName)
            StorageEngine.shared.saveItem(name: fileName, messageId: folderID, size: 0, parentId: parentID, isFolder: true)
            
            completionHandler(FileProviderItem(identifier: NSFileProviderItemIdentifier(folderID), parentIdentifier: itemTemplate.parentItemIdentifier, name: fileName, type: .folder), [], false, nil)
            return Progress()
        }
        
        guard let fileURL = url else {
            completionHandler(FileProviderItem(identifier: NSFileProviderItemIdentifier(UUID().uuidString), parentIdentifier: itemTemplate.parentItemIdentifier, name: itemTemplate.filename, type: .data), [], false, nil)
            return Progress()
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        
        if fileSize == 0 {
            let emptyID = "empty_\(UUID().uuidString)"
            StorageEngine.shared.switchDatabase(name: storageName)
            StorageEngine.shared.saveItem(name: fileName, messageId: emptyID, size: 0, parentId: parentID, isFolder: false)
            
            let fileExt = (fileName as NSString).pathExtension
            let fileType = UTType(filenameExtension: fileExt) ?? .data
            
            let item = FileProviderItem(identifier: NSFileProviderItemIdentifier(emptyID), parentIdentifier: itemTemplate.parentItemIdentifier, name: fileName, type: fileType, size: 0, hasThumbnail: false)
            
            completionHandler(item, [], false, nil)
            let p = Progress(totalUnitCount: 100)
            p.completedUnitCount = 100
            return p
        }
        
        let tempID = "temp_\(UUID().uuidString)"
        let destinationURL = uploadQueueURL.appendingPathComponent("\(tempID).dat")
        let metadataURL = uploadQueueURL.appendingPathComponent("\(tempID).json")
        
        let canAccess = fileURL.startAccessingSecurityScopedResource()
        try? FileManager.default.moveItem(at: fileURL, to: destinationURL)
        if canAccess { fileURL.stopAccessingSecurityScopedResource() }
        
        var attrs = [FileAttributeKey: Any]()
        attrs[.posixPermissions] = 0o666
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: destinationURL.path)
        
        StorageEngine.shared.switchDatabase(name: storageName)
        StorageEngine.shared.saveItem(name: fileName, messageId: tempID, size: fileSize, parentId: parentID, isFolder: false)
        
        let metadata: [String: String] = ["type": "file", "fileName": fileName, "storageName": storageName, "tempID": tempID, "parentID": parentID]
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadata) { try? jsonData.write(to: metadataURL) }
        
        if let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider") {
            sharedDefaults.removeObject(forKey: "UL_Progress_\(tempID)")
            sharedDefaults.removeObject(forKey: "UL_Total_\(tempID)")
            sharedDefaults.synchronize()
        }
        
        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.unlimbox.newFileArrived"), object: nil, userInfo: nil, deliverImmediately: true)
        
        let expectedSize = fileSize > 0 ? fileSize : 100
        let progress = Progress(totalUnitCount: expectedSize)
        
        progress.kind = .file
        progress.fileOperationKind = .copying
        progress.completedUnitCount = 0
        progress.isCancellable = true
        
        // 🚨 ВИПРАВЛЕННЯ: Глобальна черга + збільшений інтервал (як і для скачування)
        let progressTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        progressTimer.schedule(deadline: .now(), repeating: 0.5)
        
        progressTimer.setEventHandler {
            if let sharedDefaults = UserDefaults(suiteName: "group.com.unlimbox.provider") {
                sharedDefaults.synchronize()
                let uploaded = sharedDefaults.object(forKey: "UL_Progress_\(tempID)") as? Int64 ?? 0
                let total = sharedDefaults.object(forKey: "UL_Total_\(tempID)") as? Int64 ?? expectedSize
                let safeTotal = total > 0 ? total : 100
                let safeUploaded = uploaded > safeTotal ? safeTotal : uploaded
                
                progress.totalUnitCount = safeTotal
                progress.completedUnitCount = safeUploaded
                if safeUploaded >= safeTotal && safeUploaded > 0 { progressTimer.cancel() }
            }
        }
        progressTimer.resume()
        
        let wrappedCompletion: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void = { item, flds, b, err in
            progressTimer.cancel()
            completionHandler(item, flds, b, err)
        }
        
        waitForUpload(tempID: tempID, fileName: fileName, itemTemplate: itemTemplate, uploadQueueURL: uploadQueueURL, fileSize: fileSize, attemptsLeft: 86400, completionHandler: wrappedCompletion)
        
        return progress
    }
    
    private func waitForUpload(tempID: String, fileName: String, itemTemplate: NSFileProviderItem, uploadQueueURL: URL, fileSize: Int64, attemptsLeft: Int, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) {
        
        let successURL = uploadQueueURL.appendingPathComponent("success_\(tempID).txt")
        
        if FileManager.default.fileExists(atPath: successURL.path) {
            if let _ = try? String(contentsOf: successURL, encoding: .utf8) {
                try? FileManager.default.removeItem(at: successURL)
                
                let fileExt = (fileName as NSString).pathExtension
                let fileType = UTType(filenameExtension: fileExt) ?? .data
                let finalItem = FileProviderItem(identifier: NSFileProviderItemIdentifier(tempID), parentIdentifier: itemTemplate.parentItemIdentifier, name: fileName, type: fileType, size: fileSize, hasThumbnail: false)
                
                completionHandler(finalItem, [], false, nil)
                return
            }
        }
        
        if attemptsLeft <= 0 {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return
        }
        
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.5) {
            self.waitForUpload(tempID: tempID, fileName: fileName, itemTemplate: itemTemplate, uploadQueueURL: uploadQueueURL, fileSize: fileSize, attemptsLeft: attemptsLeft - 1, completionHandler: completionHandler)
        }
    }
    
    // MARK: - Інші обов'язкові методи
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        StorageEngine.shared.switchDatabase(name: domain.identifier.rawValue)
        
        for identifier in itemIdentifiers {
            if let dbItem = StorageEngine.shared.getFile(identifier: identifier.rawValue),
               let thumbData = dbItem.thumbnailData {
                perThumbnailCompletionHandler(identifier, thumbData, nil)
            } else {
                perThumbnailCompletionHandler(identifier, nil, NSFileProviderError(.noSuchItem))
            }
            progress.completedUnitCount += 1
        }
        completionHandler(nil)
        return progress
    }
    
    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        StorageEngine.shared.switchDatabase(name: domain.identifier.rawValue)
        StorageEngine.shared.deleteFileRecursively(identifier: identifier.rawValue)
        completionHandler(nil)
        return Progress()
    }
    
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
            
            StorageEngine.shared.switchDatabase(name: domain.identifier.rawValue)
            let fileID = item.itemIdentifier.rawValue
            
            var currentSize: Int64 = 0
            var isFolder = false
            
            if let dbItem = StorageEngine.shared.getFile(identifier: fileID) {
                currentSize = dbItem.size
                isFolder = dbItem.isFolder
            }
            
            if changedFields.contains(.parentItemIdentifier) {
                if item.parentItemIdentifier == .trashContainer {
                    StorageEngine.shared.deleteFileRecursively(identifier: fileID)
                    NSFileProviderManager(for: self.domain)?.signalEnumerator(for: item.parentItemIdentifier) { _ in }
                    completionHandler(item, [], false, nil)
                    return Progress()
                } else {
                    StorageEngine.shared.updateParent(identifier: fileID, newParentId: item.parentItemIdentifier.rawValue)
                }
            }
            
            if changedFields.contains(.filename) {
                StorageEngine.shared.updateName(identifier: fileID, newName: item.filename)
            }
            
            if changedFields.contains(.contents), let fileURL = newContents {
                let canAccess = fileURL.startAccessingSecurityScopedResource()
                
                var newSize: Int64 = currentSize
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                    if let sizeNum = attrs[.size] as? NSNumber { newSize = sizeNum.int64Value }
                    else if let sizeInt = attrs[.size] as? Int64 { newSize = sizeInt }
                }
                
                if newSize == 0 || newSize == currentSize {
                    if let data = try? Data(contentsOf: fileURL) {
                        newSize = Int64(data.count)
                    }
                }
                
                currentSize = newSize
                StorageEngine.shared.updateSize(identifier: fileID, newSize: currentSize)
                
                if let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.unlimbox.provider") {
                    let downloadDir = sharedContainer.appendingPathComponent("Downloads")
                    try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
                    let localCacheURL = downloadDir.appendingPathComponent("\(fileID)_\(item.filename)")
                    
                    try? FileManager.default.removeItem(at: localCacheURL)
                    try? FileManager.default.copyItem(at: fileURL, to: localCacheURL)
                    
                    if currentSize > 0 {
                        let uploadQueueURL = sharedContainer.appendingPathComponent("UploadQueue")
                        try? FileManager.default.createDirectory(at: uploadQueueURL, withIntermediateDirectories: true)
                        
                        let uploadDataURL = uploadQueueURL.appendingPathComponent("\(fileID).dat")
                        let uploadMetaURL = uploadQueueURL.appendingPathComponent("\(fileID).json")
                        
                        try? FileManager.default.removeItem(at: uploadDataURL)
                        try? FileManager.default.removeItem(at: uploadMetaURL)
                        try? FileManager.default.copyItem(at: fileURL, to: uploadDataURL)
                        
                        let metadata: [String: String] = [
                            "type": "file",
                            "fileName": item.filename,
                            "storageName": domain.identifier.rawValue,
                            "tempID": fileID,
                            "parentID": item.parentItemIdentifier.rawValue,
                            "size": "\(currentSize)"
                        ]
                        
                        if let jsonData = try? JSONSerialization.data(withJSONObject: metadata) {
                            try? jsonData.write(to: uploadMetaURL)
                        }
                        
                        DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.unlimbox.newFileArrived"), object: nil, userInfo: nil, deliverImmediately: true)
                    }
                }
                
                if canAccess { fileURL.stopAccessingSecurityScopedResource() }
            }
            
            let finalType: UTType = isFolder ? .folder : (UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data)
            
            let updatedItem = FileProviderItem(
                identifier: item.itemIdentifier,
                parentIdentifier: item.parentItemIdentifier,
                name: item.filename,
                type: finalType,
                size: currentSize,
                hasThumbnail: false
            )
            
            if let manager = NSFileProviderManager(for: self.domain) {
                manager.signalEnumerator(for: item.itemIdentifier) { _ in }
                manager.signalEnumerator(for: item.parentItemIdentifier) { _ in }
            }
            
            completionHandler(updatedItem, [], false, nil)
            return Progress()
        }
}
