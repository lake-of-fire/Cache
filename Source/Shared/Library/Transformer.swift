import Foundation

public class Transformer<T> {
    let toData: (T) throws -> Data
    let fromData: (Data) throws -> T
    let fromFile: ((URL) throws -> T)?
    
    public init(
        toData: @escaping (T) throws -> Data,
        fromData: @escaping (Data) throws -> T,
        fromFile: ((URL) throws -> T)? = nil
    ) {
        self.toData = toData
        self.fromData = fromData
        self.fromFile = fromFile
    }
}
