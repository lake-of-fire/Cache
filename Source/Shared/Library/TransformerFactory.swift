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
    
    /// Single-pass memory-mapped MD5 check, then decode.
    /// - `expectedChecksum`: MD5 hash of file
    /// - `toData`: custom serializer to Data (e.g. `cache.toCustomBinaryData()`)
    /// - `fromData`: fallback if `fromFile` not used
    public static func forMemoryMappedFileWithChecksum<T>(
        expectedChecksum: String,
        toData: @escaping (T) throws -> Data,
        fromData: @escaping (Data) throws -> T
    ) -> Transformer<T> {
        Transformer<T>(
            toData: { object in
                try toData(object)
            },
            fromData: { data in
                // Fallback MD5 check on in-memory data (hex match with `md5 -q`)
                let md5 = data.withUnsafeBytes { buf -> Insecure.MD5.Digest in
                    var ctx = Insecure.MD5()
                    ctx.update(bufferPointer: buf)
                    return ctx.finalize()
                }
                let actual = md5.map { String(format: "%02x", $0) }.joined()
                guard actual.lowercased() == expectedChecksum.lowercased() else {
                    throw NSError(domain: "TransformerFactory", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "MD5 mismatch. Expected \(expectedChecksum), got \(actual)"
                    ])
                }
                return try fromData(data)
            },
            fromFile: { fileURL in
                // 1) Open + mmap
                let fd = open(fileURL.path, O_RDONLY)
                guard fd >= 0 else {
                    throw NSError(domain: "TransformerFactory", code: 2, userInfo: nil)
                }
                defer { close(fd) }
                
                let fileLen = lseek(fd, 0, SEEK_END)
                guard fileLen > 0 else {
                    throw NSError(domain: "TransformerFactory", code: 3, userInfo: nil)
                }
                _ = lseek(fd, 0, SEEK_SET)
                
                let ptr = mmap(nil, Int(fileLen), PROT_READ, MAP_PRIVATE, fd, 0)
                guard ptr != MAP_FAILED else {
                    throw NSError(domain: "TransformerFactory", code: 4, userInfo: nil)
                }
                defer { munmap(ptr, Int(fileLen)) }
                
                // 2) MD5 on mapped bytes
                let buf = UnsafeRawBufferPointer(start: ptr, count: Int(fileLen))
                var md5 = Insecure.MD5()
                md5.update(bufferPointer: buf)
                let digest = md5.finalize()
                let actualHex = digest.map { String(format: "%02x", $0) }.joined()
                guard actualHex.lowercased() == expectedChecksum.lowercased() else {
                    throw NSError(domain: "TransformerFactory", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "MD5 mismatch. Expected \(expectedChecksum), got \(actualHex)"
                    ])
                }
                
                // 3) Decode from same bytes (no extra copy)
                // Ensure the pointer is non-nil before creating Data
                guard let baseAddress = ptr else {
                    throw NSError(domain: "TransformerFactory", code: 6, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to memory-map the file: null pointer"
                    ])
                }
                let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                                count: Int(fileLen),
                                deallocator: .none)
                
                // Decode the data
                
                return try fromData(data)
            }
        )
    }
}
