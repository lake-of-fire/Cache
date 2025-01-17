#if canImport(UIKit)
import UIKit
#endif

import Foundation
import CryptoKit

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
    
    /// Checksum is MD5.
    public static func forMemoryMappedFile<U: Codable>(
        ofType: U.Type,
        expectedChecksum: String
    ) -> Transformer<U> {
        let toData: (U) throws -> Data = { object in
            let wrapper = TypeWrapper<U>(object: object)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try encoder.encode(wrapper)
        }
        
        let fromData: (Data) throws -> U = { data in
            let decoder = PropertyListDecoder()
            return try decoder.decode(TypeWrapper<U>.self, from: data).object
        }
        
        let fromFile: (URL) throws -> U = { url in
            let bufferSize = 16 * 1024 // 16 KB buffer size for file reading
            
            // Calculate the file's checksum
            guard let actualChecksum = checksumForFile(at: url, bufferSize: bufferSize) else {
                throw NSError(
                    domain: "TransformerFactory",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to calculate MD5 checksum."]
                )
            }
            
            guard actualChecksum == expectedChecksum else {
                throw NSError(
                    domain: "TransformerFactory",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Checksum mismatch. Expected \(expectedChecksum), got \(actualChecksum)."
                    ]
                )
            }
            
            // Load the file using memory mapping
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try fromData(data)
        }
        
        let toFile: (U, URL) throws -> Void = { object, url in
            let data = try toData(object)
            try data.write(to: url, options: .atomic)
        }
        
        return Transformer<U>(
            toData: toData,
            fromData: fromData
        )
    }
    
    private static func checksumForFile(at url: URL, bufferSize: Int) -> String? {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { file.closeFile() }
            
            var md5 = Insecure.MD5()
            while autoreleasepool(invoking: {
                let data = file.readData(ofLength: bufferSize)
                if !data.isEmpty {
                    md5.update(data: data)
                    return true
                }
                return false
            }) {}
            
            let digest = md5.finalize()
            return Data(digest).base64EncodedString()
        } catch {
            print("Error calculating checksum: \(error)")
            return nil
        }
    }
}
