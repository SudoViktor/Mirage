import FileProvider
import UniformTypeIdentifiers
import os.log

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let domainIdentifier: String
    private let logger = Logger(subsystem: "com.viktor.UnlimBox", category: "Enumerator")
    
    init(containerIdentifier: NSFileProviderItemIdentifier, domainIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.domainIdentifier = domainIdentifier
        super.init()
        StorageEngine.shared.switchDatabase(name: domainIdentifier)
    }
 
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if containerIdentifier == .workingSet {
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }

        let dbItems = StorageEngine.shared.getChildren(parentIdentifier: containerIdentifier.rawValue)
        
        let items = dbItems.map { dbItem in
            let contentType: UTType
            
            // 🚨 НАДІЙНА ПЕРЕВІРКА ТИПУ З БАЗИ
            if dbItem.isFolder {
                contentType = .folder
            } else {
                let ext = (dbItem.name as NSString).pathExtension.lowercased()
                contentType = UTType(filenameExtension: ext) ?? .data
            }
            
            return FileProviderItem(
                identifier: NSFileProviderItemIdentifier(dbItem.id),
                parentIdentifier: containerIdentifier,
                name: dbItem.name,
                type: contentType,
                size: dbItem.size,
                hasThumbnail: dbItem.thumbnailData != nil
            )
        }
        
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
        logger.info("✅ [Enum] Відображено \(items.count) елементів для \(self.containerIdentifier.rawValue)")
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchor = NSFileProviderSyncAnchor("1".data(using: .utf8)!)
        completionHandler(anchor)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
}
