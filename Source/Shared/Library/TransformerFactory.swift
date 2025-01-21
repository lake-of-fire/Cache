#if canImport(UIKit)
import UIKit
#endif

import Foundation
import CommonCrypto // Faster for SHA-1 hashing than CryptoKit (maybe)

public class TransformerFactory {
    public static func forData() -> Transformer<Data> {
        let toData: (Data) throws -> Data = { $0 }
        
        let fromData: (Data) throws -> Data = { $0 }
        
        return Transformer<Data>(toData: toData, fromData: fromData)
    }
    
    public static func forImage() -> Transformer<Image> {
        let toData: (Image) throws -> Data = { image in
            return try image.cache_toData().unwrapOrThrow(error: StorageError.transformerFail)
        }
        
        let fromData: (Data) throws -> Image = { data in
            return try Image(data: data).unwrapOrThrow(error: StorageError.transformerFail)
        }
        
        return Transformer<Image>(toData: toData, fromData: fromData)
    }
    
    public static func forCodable<U: Codable>(ofType: U.Type) -> Transformer<U> {
        let toData: (U) throws -> Data = { object in
            let wrapper = TypeWrapper<U>(object: object)
            let encoder = JSONEncoder()
            return try encoder.encode(wrapper)
        }
        
        let fromData: (Data) throws -> U = { data in
            let decoder = JSONDecoder()
            return try decoder.decode(TypeWrapper<U>.self, from: data).object
        }
        
        return Transformer<U>(toData: toData, fromData: fromData)
    }
    
    /// Single-pass memory-mapped SHA-1 check, then decode.
    /// - `expectedChecksum`: SHA-1 hash of file
    /// - `toData`: custom serializer to Data (e.g. `cache.toCustomBinaryData()`)
    /// - `fromData`: fallback if `fromFile` not used
    public static func forMemoryMappedFileWithChecksum<T>(
        expectedChecksum: String,
        toData: @escaping (T) throws -> Data,
        fromData: @escaping (Data) throws -> T
    ) -> Transformer<T> {
        let expectedChecksum = expectedChecksum.lowercased()
        return Transformer<T>(
            toData: { object in
                try toData(object)
            },
            fromData: { data in
                fatalError("TransformFactory.forMemoryMappedFileWithChecksum requires fromFile")
            },
            fromFile: { fileURL in
                // Calculate the SHA-1 checksum directly from the file
                let actualHex = try sha1Checksum(for: fileURL)
                
                guard actualHex == expectedChecksum else {
                    print("TransformerFactory.forMemoryMappedFileWithChecksum: SHA-1 mismatch. Expected \(expectedChecksum), got \(actualHex)")
                    throw NSError(domain: "TransformerFactory", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "SHA-1 mismatch. Expected \(expectedChecksum), got \(actualHex)"
                    ])
                }
                
                // Read the file content into memory-mapped data
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                return try fromData(data)
            }
        )
    }
}

/// Computes the SHA-1 checksum for a file, mimicking the behavior of the `sha1` CLI tool.
///
/// - Parameter fileURL: The URL of the file to hash.
/// - Returns: The hexadecimal SHA-1 checksum string.
/// - Throws: An error if the file cannot be read.
fileprivate func sha1Checksum(for fileURL: URL) throws -> String {
    let bufferSize = 64 * 1024 // 64 KB buffer size
    
    // Open the file
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { fileHandle.closeFile() }
    
    // Initialize the SHA-1 context
    var context = CC_SHA1_CTX()
    CC_SHA1_Init(&context)
    
    // Read the file in chunks and update the hash
    while autoreleasepool(invoking: {
        let data = fileHandle.readData(ofLength: bufferSize)
        guard !data.isEmpty else { return false }
        
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1_Update(&context, buffer.baseAddress, CC_LONG(buffer.count))
        }
        return true
    }) {}
    
    // Finalize the hash
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    CC_SHA1_Final(&digest, &context)
    
    // Convert the digest to a hexadecimal string
    return digest.map { String(format: "%02x", $0) }.joined()
}
