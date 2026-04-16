import FileProvider
import UniformTypeIdentifiers

class FileProviderItem: NSObject, NSFileProviderItem {
    let identifier: NSFileProviderItemIdentifier
    let parentIdentifier: NSFileProviderItemIdentifier
    let name: String
    let type: UTType
    let size: Int64?
    let hasThumbnail: Bool
 
    // 🚨 ВИДАЛЕНО isItemUploaded
    init(identifier: NSFileProviderItemIdentifier, parentIdentifier: NSFileProviderItemIdentifier, name: String, type: UTType, size: Int64? = nil, hasThumbnail: Bool = false) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.name = name
        self.type = type
        self.size = size
        self.hasThumbnail = hasThumbnail
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier { identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { parentIdentifier }
    var filename: String { name }
    var contentType: UTType { type }
    
    var documentSize: NSNumber? {
        if type.conforms(to: .folder) || type.conforms(to: .directory) { return nil }
        if let actualSize = size { return NSNumber(value: actualSize) }
        return nil
    }
    
    var capabilities: NSFileProviderItemCapabilities {
        if identifier == .rootContainer { return [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems] }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsTrashing, .allowsContentEnumerating]
    }
    
    var itemVersion: NSFileProviderItemVersion {
        let versionString = "\(size ?? 0)"
        let versionData = versionString.data(using: .utf8)!
        return NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
    }
    
    var thumbnailIdentifier: String? { return hasThumbnail ? "thumb_\(identifier.rawValue)" : nil }
}
