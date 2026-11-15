import Foundation

/// Save objects to file on disk
final public class DiskStorage<Key: Hashable, Value> {
    enum Error: Swift.Error {
        case fileEnumeratorFailed
    }
    
    /// File manager to read/write to the disk
    public let fileManager: FileManager
    /// Configuration
    private let config: DiskConfig
    /// The computed path `directory+name`
    public let path: String
    /// The closure to be called when single file has been removed
    var onRemove: ((String) -> Void)?
    
    // Per-storage enumeration boundary; configure before sharing the storage.
    // Nil preserves FileManager's resource prefetch, options and error handling.
    typealias EnumerationFactory = (URL, [URLResourceKey]?, FileManager.DirectoryEnumerationOptions,
                                    ((URL, Swift.Error) -> Bool)?) -> NSEnumerator?
    var enumerationFactory: EnumerationFactory?

    private let acquireExecutionLease: CacheStorageExecutionProtection.Acquisition?
    private let transformer: Transformer<Value>
    private let hasher = Hasher.constantAccrossExecutions()
    
    // MARK: - Initialization
    public convenience init(config: DiskConfig, fileManager: FileManager = FileManager.default, transformer: Transformer<Value>, acquireExecutionLease: CacheStorageExecutionProtection.Acquisition? = nil) throws {
        let execution: CacheStorageExecutionLease?
        if let acquireExecutionLease {
            execution = try acquireExecutionLease()
        } else {
            execution = try CacheStorageExecutionProtection.acquire()
        }
        defer { execution?.release() }
        let checkpoint: () throws -> Void = { try execution?.checkpoint() }
        try checkpoint()
        let url: URL
        if let directory = config.directory {
            url = directory
        } else {
            url = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        
        // path
        let path = url.appendingPathComponent(config.name, isDirectory: true).path
        
        self.init(config: config, fileManager: fileManager, path: path, transformer: transformer, acquireExecutionLease: acquireExecutionLease)
        
        try createDirectory(checkpoint: checkpoint)
        
        if let protectionType = config.protectionType {
            try checkpoint()
            try fileManager.setAttributes([FileAttributeKey.protectionKey: protectionType], ofItemAtPath: path)
        }
    }
    
    public required init(config: DiskConfig, fileManager: FileManager = FileManager.default, path: String, transformer: Transformer<Value>, acquireExecutionLease: CacheStorageExecutionProtection.Acquisition? = nil) {
        self.acquireExecutionLease = acquireExecutionLease
        self.config = config
        self.fileManager = fileManager
        self.path = path
        self.transformer = transformer
    }
}

extension DiskStorage: StorageAware {
    public var allKeys: [Key] { [] }
    
    public var allObjects: [Value] { [] }
    
    public func entry(forKey key: Key) throws -> Entry<Value> {
        return try withExecutionProtection { checkpoint in
            let filePath = makeFilePath(for: key)
            let fileURL = URL(fileURLWithPath: filePath, isDirectory: false)
            
            try checkpoint()
            let object: Value
            if let fromFile = transformer.fromFile {
                // Let the Transformer do direct on-disk MD5, memory-mapping, etc.
                object = try fromFile(fileURL)
            } else {
                // Fallback to reading all data into memory
                let data = try Data(contentsOf: fileURL)
                object = try transformer.fromData(data)
            }
            
            try checkpoint()
            let attributes = try fileManager.attributesOfItem(atPath: filePath)
            guard let date = attributes[.modificationDate] as? Date else {
                throw StorageError.malformedFileAttributes
            }
            
            return Entry(object: object, expiry: Expiry.date(date), filePath: filePath)
        }
    }
    
    public func setObject(_ object: Value, forKey key: Key, expiry: Expiry? = nil) throws {
        return try withExecutionProtection { checkpoint in
            let expiry = expiry ?? config.expiry
            let data = try transformer.toData(object)
            try checkpoint()
            let filePath = makeFilePath(for: key)
            try createDirectory(checkpoint: checkpoint)
            try checkpoint()
            _ = fileManager.createFile(atPath: filePath, contents: data, attributes: nil)
            try checkpoint()
            try fileManager.setAttributes([.modificationDate: expiry.date], ofItemAtPath: filePath)
        }
    }
    
    public func removeObject(forKey key: Key) throws {
        return try withExecutionProtection { checkpoint in
            let filePath = makeFilePath(for: key)
            try checkpoint()
            try fileManager.removeItem(atPath: filePath)
            onRemove?(filePath)
        }
    }
    
    public func removeAll() throws {
        return try withExecutionProtection { checkpoint in
            try checkpoint()
            try fileManager.removeItem(atPath: path)
            try createDirectory(checkpoint: checkpoint)
        }
    }
    
    public func removeExpiredObjects() throws {
        return try withExecutionProtection { checkpoint in
            let storageURL = URL(fileURLWithPath: path, isDirectory: true)
            let resourceKeys: [URLResourceKey] = [
                .isDirectoryKey,
                .contentModificationDateKey,
                .totalFileAllocatedSizeKey
            ]
            var resourceObjects = [ResourceObject]()
            var filesToDelete = [URL]()
            var totalSize: UInt = 0
            try checkpoint()
            let fileEnumerator = makeEnumerator(
                at: storageURL,
                includingPropertiesForKeys: resourceKeys,
                options: .skipsHiddenFiles,
                errorHandler: nil
            )
            
            guard let fileEnumerator else {
                throw Error.fileEnumeratorFailed
            }
            
            while true {
                try checkpoint()
                guard let object = fileEnumerator.nextObject() else { break }
                guard let url = object as? URL else { continue }
                try checkpoint()
                let resourceValues = try url.resourceValues(forKeys: Set(resourceKeys))
                guard resourceValues.isDirectory != true else {
                    continue
                }
                
                if let expiryDate = resourceValues.contentModificationDate, expiryDate.inThePast {
                    filesToDelete.append(url)
                    continue
                }
                
                if let fileSize = resourceValues.totalFileAllocatedSize {
                    totalSize += UInt(fileSize)
                    resourceObjects.append((url: url, resourceValues: resourceValues))
                }
            }
            
            // Remove expired objects
            for url in filesToDelete {
                try checkpoint()
                try fileManager.removeItem(at: url)
                onRemove?(url.path)
            }
            
            // Remove objects if storage size exceeds max size
            try removeResourceObjects(resourceObjects, totalSize: totalSize, checkpoint: checkpoint)
        }
    }
    
    public func removeInMemoryObject(forKey key: Key) throws { }
}

extension DiskStorage {
    /**
     Sets attributes on the disk cache folder.
     - Parameter attributes: Directory attributes
     */
    func setDirectoryAttributes(_ attributes: [FileAttributeKey: Any]) throws {
        return try withExecutionProtection { checkpoint in
            try checkpoint()
            try fileManager.setAttributes(attributes, ofItemAtPath: path)
        }
    }
}

typealias ResourceObject = (url: Foundation.URL, resourceValues: URLResourceValues)

extension DiskStorage {
    /**
     Builds file name from the key.
     - Parameter key: Unique key to identify the object in the cache
     - Returns: A md5 string
     */
    func makeFileName(for key: Key) -> String {
        if let key = key as? String {
            let fileExtension = (key as NSString).pathExtension
            let fileName = MD5(key)
            
            switch fileExtension.isEmpty {
            case true:
                return fileName
            case false:
                return "\(fileName).\(fileExtension)"
            }
        }
        
        var hasher = self.hasher
        key.hash(into: &hasher)
        return String(hasher.finalize())
    }
    
    /**
     Builds file path from the key.
     - Parameter key: Unique key to identify the object in the cache
     - Returns: A string path based on key
     */
    func makeFilePath(for key: Key) -> String {
        if config.keysAsFilenames, let keyStr = key as? String {
            return "\(path)/\(key)"
        }
        return "\(path)/\(makeFileName(for: key))"
    }
    
    func createDirectory() throws {
        try withExecutionProtection { try createDirectory(checkpoint: $0) }
    }

    private func createDirectory(checkpoint: () throws -> Void) throws {
        try checkpoint()
        guard !fileManager.fileExists(atPath: path) else {
            return
        }
        
        try checkpoint()
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true,
                                        attributes: nil)
    }
    
    /**
     Removes objects if storage size exceeds max size.
     - Parameter objects: Resource objects to remove
     - Parameter totalSize: Total size
     */
    func removeResourceObjects(_ objects: [ResourceObject], totalSize: UInt) throws {
        try withExecutionProtection { try removeResourceObjects(objects, totalSize: totalSize, checkpoint: $0) }
    }

    private func removeResourceObjects(_ objects: [ResourceObject], totalSize: UInt, checkpoint: () throws -> Void) throws {
        guard config.maxSize > 0 && totalSize > config.maxSize else {
            return
        }
        
        var totalSize = totalSize
        let targetSize = config.maxSize / 2
        
        let sortedFiles = objects.sorted {
            if let time1 = $0.resourceValues.contentModificationDate?.timeIntervalSinceReferenceDate,
               let time2 = $1.resourceValues.contentModificationDate?.timeIntervalSinceReferenceDate {
                return time1 < time2
            } else {
                return false
            }
        }
        
        for file in sortedFiles {
            try checkpoint()
            try fileManager.removeItem(at: file.url)
            onRemove?(file.url.path)
            
            if let fileSize = file.resourceValues.totalFileAllocatedSize {
                totalSize -= UInt(fileSize)
            }
            
            if totalSize < targetSize {
                break
            }
        }
    }
    
    /**
     Removes the object from the cache if it's expired.
     - Parameter key: Unique key to identify the object in the cache
     */
    func removeObjectIfExpired(forKey key: Key) throws {
        return try withExecutionProtection { checkpoint in
            let filePath = makeFilePath(for: key)
            try checkpoint()
            let attributes = try fileManager.attributesOfItem(atPath: filePath)
            if let expiryDate = attributes[.modificationDate] as? Date, expiryDate.inThePast {
                try checkpoint()
                try fileManager.removeItem(atPath: filePath)
                onRemove?(filePath)
            }
        }
    }
}

public extension DiskStorage {
    func transform<U>(transformer: Transformer<U>) -> DiskStorage<Key, U> {
        let storage = DiskStorage<Key, U>(
            config: config,
            fileManager: fileManager,
            path: path,
            transformer: transformer,
            acquireExecutionLease: acquireExecutionLease
        )
        
        storage.enumerationFactory = enumerationFactory
        return storage
    }
}

public extension DiskStorage {
    /// Calculates the total size of the cache directory in bytes.
    var totalSize: Int? {
        try? withExecutionProtection { checkpoint -> Int? in
            guard let directory = URL(string: self.path),
                  let enumerator = makeEnumerator(at: directory, includingPropertiesForKeys: [], options: [], errorHandler: { _, _ in false }) else { return nil }
            var size = 0
            while true {
                try checkpoint()
                guard let object = enumerator.nextObject() else { break }
                guard let url = object as? URL else { continue }
                try checkpoint()
                size += url.fileSize ?? 0
            }
            return size
        }
    }
}

private extension DiskStorage {
    func makeEnumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                        options: FileManager.DirectoryEnumerationOptions,
                        errorHandler: ((URL, Swift.Error) -> Bool)?) -> NSEnumerator? {
        if let enumerationFactory {
            return enumerationFactory(url, keys, options, errorHandler)
        }
        return fileManager.enumerator(at: url, includingPropertiesForKeys: keys,
                                      options: options, errorHandler: errorHandler)
    }

    func withExecutionProtection<Result>(_ operation: (() throws -> Void) throws -> Result) throws -> Result {
        try CacheStorageExecutionProtection.withLease(acquisition: acquireExecutionLease, operation: operation)
    }
}
