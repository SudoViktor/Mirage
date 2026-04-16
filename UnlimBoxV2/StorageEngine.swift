import Foundation
import FileProvider
import SQLite3
import os

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DBItem {
    let id: String
    let name: String
    let size: Int64
    let parentId: String
    let thumbnailData: Data?
    let chatId: Int64
    let realMessageId: Int64
    let isFolder: Bool // 🚨 ДОДАНО
}
 
class StorageEngine {
    static let shared = StorageEngine()
    private var db: OpaquePointer?
    private let groupName = "group.com.unlimbox.provider"
    private let logger = Logger(subsystem: "com.viktor.UnlimBox", category: "Enumerator")

    private let dbQueue = DispatchQueue(label: "com.unlimbox.dbQueue")
    
    init() {}
    
    private var currentDbName: String? = nil

    func switchDatabase(name: String) {
        dbQueue.sync {
            if currentDbName == name && db != nil { return }
            if db != nil { sqlite3_close(db); db = nil }
            currentDbName = name
            internalOpenDatabase(name: name)
        }
    }

    private func internalOpenDatabase(name: String) {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName) else { return }
        let dbURL = groupURL.appendingPathComponent(name.hasSuffix(".sqlite") ? name : "\(name).sqlite")
        
        if sqlite3_open(dbURL.path, &db) == SQLITE_OK {
            let createTableQuery = """
            CREATE TABLE IF NOT EXISTS Files(
                Id INTEGER PRIMARY KEY AUTOINCREMENT,
                Name TEXT,
                TelegramMessageID TEXT,
                ThumbnailData BLOB,
                Size INTEGER,
                ParentID TEXT,
                ChatID INTEGER,
                RealMessageID INTEGER,
                IsFolder INTEGER DEFAULT 0
            );
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, createTableQuery, -1, &statement, nil) == SQLITE_OK { sqlite3_step(statement) }
            sqlite3_finalize(statement)
            
            // Оновлюємо старі таблиці
            sqlite3_exec(db, "ALTER TABLE Files ADD COLUMN ChatID INTEGER DEFAULT 0;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE Files ADD COLUMN RealMessageID INTEGER DEFAULT 0;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE Files ADD COLUMN IsFolder INTEGER DEFAULT 0;", nil, nil, nil)
            
            // 🚨 МІГРАЦІЯ: Автоматично робимо старі папки справжніми папками за новою логікою
            sqlite3_exec(db, "UPDATE Files SET IsFolder = 1 WHERE TelegramMessageID LIKE 'folder_%';", nil, nil, nil)
        }
    }

    func getFile(identifier: String) -> DBItem? {
        return dbQueue.sync {
            var statement: OpaquePointer?
            let query = "SELECT Name, TelegramMessageID, Size, ParentID, ThumbnailData, ChatID, RealMessageID, IsFolder FROM Files WHERE TelegramMessageID = ?;"
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (identifier as NSString).utf8String, -1, nil)
                if sqlite3_step(statement) == SQLITE_ROW {
                    let name = String(cString: sqlite3_column_text(statement, 0))
                    let fId = String(cString: sqlite3_column_text(statement, 1))
                    let size = sqlite3_column_int64(statement, 2)
                    let pId = String(cString: sqlite3_column_text(statement, 3))
                    
                    var tData: Data? = nil
                    if let blob = sqlite3_column_blob(statement, 4) {
                        tData = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 4)))
                    }
                    
                    let chatId = sqlite3_column_int64(statement, 5)
                    let realMsgId = sqlite3_column_int64(statement, 6)
                    let isFolder = sqlite3_column_int(statement, 7) == 1 // 🚨 ДОДАНО
                    
                    sqlite3_finalize(statement)
                    return DBItem(id: fId, name: name, size: size, parentId: pId, thumbnailData: tData, chatId: chatId, realMessageId: realMsgId, isFolder: isFolder)
                }
            }
            sqlite3_finalize(statement)
            return nil
        }
    }

    func getChildren(parentIdentifier: String) -> [DBItem] {
        return dbQueue.sync {
            var items: [DBItem] = []
            var statement: OpaquePointer?
            let pIdToSearch = parentIdentifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? "NSFileProviderRootContainerItemIdentifier" : parentIdentifier
            
            let query = "SELECT Name, TelegramMessageID, Size, ParentID, ThumbnailData, ChatID, RealMessageID, IsFolder FROM Files WHERE ParentID = ?;"
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (pIdToSearch as NSString).utf8String, -1, nil)
                while sqlite3_step(statement) == SQLITE_ROW {
                    let name = String(cString: sqlite3_column_text(statement, 0))
                    let fId = String(cString: sqlite3_column_text(statement, 1))
                    let size = sqlite3_column_int64(statement, 2)
                    let pId = String(cString: sqlite3_column_text(statement, 3))
                    
                    var tData: Data? = nil
                    if let blob = sqlite3_column_blob(statement, 4) {
                        tData = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 4)))
                    }
                    
                    let chatId = sqlite3_column_int64(statement, 5)
                    let realMsgId = sqlite3_column_int64(statement, 6)
                    let isFolder = sqlite3_column_int(statement, 7) == 1 // 🚨 ДОДАНО
                    
                    items.append(DBItem(id: fId, name: name, size: size, parentId: pId, thumbnailData: tData, chatId: chatId, realMessageId: realMsgId, isFolder: isFolder))
                }
            }
            sqlite3_finalize(statement)
            return items
        }
    }

    func deleteFile(identifier: String) {
        dbQueue.sync {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM Files WHERE TelegramMessageID = ?;", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_text(st, 1, (identifier as NSString).utf8String, -1, nil)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
            print("deleteFile")
            didModifyDatabase()
        }
    }
    
    func deleteFileRecursively(identifier: String) {
        let children = getChildren(parentIdentifier: identifier)
        for child in children {
            deleteFileRecursively(identifier: child.id)
        }
        deleteFile(identifier: identifier)
    }
    
    func updateParent(identifier: String, newParentId: String) {
        dbQueue.sync {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE Files SET ParentID = ? WHERE TelegramMessageID = ?;", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_text(st, 1, (newParentId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(st, 2, (identifier as NSString).utf8String, -1, nil)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
            print("updateParent")
            didModifyDatabase()
        }
    }

    func updateName(identifier: String, newName: String) {
        dbQueue.sync {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE Files SET Name = ? WHERE TelegramMessageID = ?;", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_text(st, 1, (newName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(st, 2, (identifier as NSString).utf8String, -1, nil)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
            print("updateName")
            didModifyDatabase()
        }
    }
    
    // 🚨 ДОДАНО параметр isFolder
    func saveItem(name: String, messageId: String, size: Int64, parentId: String, thumbData: Data? = nil, chatId: Int64 = 0, realMessageId: Int64 = 0, isFolder: Bool = false) {
        dbQueue.sync {
            let query = "INSERT INTO Files (Name, TelegramMessageID, ThumbnailData, Size, ParentID, ChatID, RealMessageID, IsFolder) VALUES (?, ?, ?, ?, ?, ?, ?, ?);"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (messageId as NSString).utf8String, -1, nil)
                
                if let tData = thumbData {
                    tData.withUnsafeBytes { rawBuffer in
                        if let ptr = rawBuffer.baseAddress {
                            sqlite3_bind_blob(statement, 3, ptr, Int32(tData.count), SQLITE_TRANSIENT)
                        } else {
                            sqlite3_bind_null(statement, 3)
                        }
                    }
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                
                sqlite3_bind_int64(statement, 4, size)
                sqlite3_bind_text(statement, 5, (parentId as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(statement, 6, chatId)
                sqlite3_bind_int64(statement, 7, realMessageId)
                sqlite3_bind_int(statement, 8, isFolder ? 1 : 0) // 🚨 Записуємо 1 якщо папка
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }
    
    func updateRemoteId(oldId: String, newId: String) {
        dbQueue.sync {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE Files SET TelegramMessageID = ? WHERE TelegramMessageID = ?;", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_text(st, 1, (newId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(st, 2, (oldId as NSString).utf8String, -1, nil)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
            print("updateRemoteId")
            didModifyDatabase()
        }
    }
    
    func cleanUpOrphanedFiles() {
        dbQueue.sync {
            var st: OpaquePointer?
            let query = "DELETE FROM Files WHERE ChatID = 0 AND Size > 0 AND IsFolder = 0;"
            if sqlite3_prepare_v2(db, query, -1, &st, nil) == SQLITE_OK {
                sqlite3_step(st)
                print("🧹 [DB-Clean] Видалено файли-привиди з бази \(currentDbName ?? "Unknown")")
            }
            sqlite3_finalize(st)
            print("cleanUpOrphanedFiles")
        }
    }
    
    func updateSize(identifier: String, newSize: Int64) {
        dbQueue.sync {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE Files SET Size = ? WHERE TelegramMessageID = ?;", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_int64(st, 1, newSize)
                sqlite3_bind_text(st, 2, (identifier as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
            print("updateSize")
            didModifyDatabase()
        }
    }
    
    // 🚨 ДОДАНО: Функція для фіналізації завантаження БЕЗ зміни унікального ID
        func finalizeUploadedFile(identifier: String, thumbData: Data?, chatId: Int64, realMessageId: Int64) {
            dbQueue.sync {
                var st: OpaquePointer?
                let query = "UPDATE Files SET ChatID = ?, RealMessageID = ?, ThumbnailData = ? WHERE TelegramMessageID = ?;"
                if sqlite3_prepare_v2(db, query, -1, &st, nil) == SQLITE_OK {
                    sqlite3_bind_int64(st, 1, chatId)
                    sqlite3_bind_int64(st, 2, realMessageId)
                    
                    if let tData = thumbData {
                        tData.withUnsafeBytes { rawBuffer in
                            if let ptr = rawBuffer.baseAddress {
                                sqlite3_bind_blob(st, 3, ptr, Int32(tData.count), SQLITE_TRANSIENT)
                            } else {
                                sqlite3_bind_null(st, 3)
                            }
                        }
                    } else {
                        sqlite3_bind_null(st, 3)
                    }
                    
                    sqlite3_bind_text(st, 4, (identifier as NSString).utf8String, -1, nil)
                    sqlite3_step(st)
                }
                sqlite3_finalize(st)
                print("finalizeUploadedFile")
                didModifyDatabase()
            }
        }
    
    // 🚨 ДОДАНО: Примусове збереження всіх кешів SQLite перед копіюванням бази
        func createSafeBackup(from sourceURL: URL, to destURL: URL) {
            dbQueue.sync {
                // Змушуємо SQLite перенести всі дані з -wal файлу в основний файл
                sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)

                try? FileManager.default.removeItem(at: destURL)
                try? FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
        }
    
    private func didModifyDatabase() {
            guard let dbName = currentDbName else { return }
            
            DispatchQueue.global(qos: .background).async {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name("com.unlimbox.databaseModified"),
                    object: dbName, // 👈 ПЕРЕДАЄМО ІМ'Я ТУТ (це дозволено Sandbox'ом)
                    userInfo: nil,  // 👈 БІЛЬШЕ НІЯКИХ ЗАБОРОНЕНИХ СЛОВНИКІВ
                    deliverImmediately: true
                )
            }
        }
}
