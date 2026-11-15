import Foundation

/// Host-owned execution for one synchronous disk operation. Cache has no platform dependency.
public struct CacheStorageExecutionLease: Sendable {
    public let checkpoint: @Sendable () throws -> Void
    public let release: @Sendable () -> Void

    public init(checkpoint: @escaping @Sendable () throws -> Void, release: @escaping @Sendable () -> Void) {
        self.checkpoint = checkpoint
        self.release = release
    }
}

public enum CacheStorageExecutionProtection {
    public typealias Acquisition = @Sendable () throws -> CacheStorageExecutionLease?

    private final class Policy: @unchecked Sendable {
        let lock = NSLock()
        var acquisition: Acquisition?
    }
    private static let policy = Policy()

    /// Install before starting application workers. Extensions may keep their own execution owner.
    public static func installDefaultAcquisition(_ acquisition: @escaping Acquisition) {
        policy.lock.lock()
        policy.acquisition = acquisition
        policy.lock.unlock()
    }

    static func acquire() throws -> CacheStorageExecutionLease? {
        policy.lock.lock()
        let acquisition = policy.acquisition
        policy.lock.unlock()
        return try acquisition?()
    }

    static func withLease<Result>(
        acquisition: Acquisition?,
        operation: (() throws -> Void) throws -> Result
    ) throws -> Result {
        let lease: CacheStorageExecutionLease?
        if let acquisition {
            lease = try acquisition()
        } else {
            lease = try acquire()
        }
        defer { lease?.release() }
        let checkpoint: () throws -> Void = { try lease?.checkpoint() }
        try checkpoint()
        return try operation(checkpoint)
    }
}
