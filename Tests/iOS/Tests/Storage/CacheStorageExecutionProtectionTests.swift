import Foundation
import XCTest
@testable import Cache

final class CacheStorageExecutionProtectionTests: XCTestCase {
    private enum Failure: Error { case denied, expired, transform }

    private final class Policy: @unchecked Sendable {
        private let lock = NSLock()
        private var denied = false
        private var expired = false
        private var acquisitions = 0
        private var releases = 0
        private var active = 0

        private func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
        var counts: (acquired: Int, released: Int, active: Int) {
            locked { (acquisitions, releases, active) }
        }
        func deny() { locked { denied = true } }
        func expire() { locked { expired = true } }
        func acquire() throws -> CacheStorageExecutionLease? {
            try locked {
                acquisitions += 1
                if denied { throw Failure.denied }
                active += 1
            }
            return CacheStorageExecutionLease(checkpoint: { [self] in
                try locked { if expired { throw Failure.expired } }
            }, release: { [self] in
                locked { releases += 1; active -= 1 }
            })
        }
    }

    private final class ExpiringFileManager: FileManager, @unchecked Sendable {
        let afterCreate: @Sendable () -> Void
        init(afterCreate: @escaping @Sendable () -> Void) {
            self.afterCreate = afterCreate
            super.init()
        }
        override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
            let result = super.createFile(atPath: path, contents: data, attributes: attr)
            afterCreate()
            return result
        }
    }

    /// Expires just after admitting metadata for the first enumerated URL.
    /// Further traversal must perform another admission before advancing.
    private final class EnumerationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var calls = 0
        private var expired = false
        private var releases = 0

        private func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
        func prepare(urls: [URL]) { locked { self.urls = urls } }
        var observations: (advances: Int, expired: Bool, releases: Int) {
            locked { (calls, expired, releases) }
        }
        func nextObject() -> Any? {
            locked {
                calls += 1
                return calls <= urls.count ? urls[calls - 1] : nil
            }
        }
        func acquire() -> CacheStorageExecutionLease {
            CacheStorageExecutionLease(checkpoint: { [self] in
                try locked {
                    if expired { throw Failure.expired }
                    // Permit this metadata admission, then expire the lease before
                    // the caller can request the next enumerator advancement.
                    if calls > 0 { expired = true }
                }
            }, release: { [self] in locked { releases += 1 } })
        }
    }

    private final class InstrumentedEnumerator: FileManager.DirectoryEnumerator {
        let probe: EnumerationProbe
        init(probe: EnumerationProbe) {
            self.probe = probe
            super.init()
        }
        override func nextObject() -> Any? { probe.nextObject() }
    }

    private final class EnumeratingFileManager: FileManager, @unchecked Sendable {
        let probe: EnumerationProbe
        init(probe: EnumerationProbe) {
            self.probe = probe
            super.init()
        }
        override func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                 options mask: FileManager.DirectoryEnumerationOptions = [],
                                 errorHandler handler: ((URL, Swift.Error) -> Bool)? = nil) -> FileManager.DirectoryEnumerator? {
            InstrumentedEnumerator(probe: probe)
        }
    }

    private var directory: URL!
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }
    private func disk(_ policy: Policy, transformer: Transformer<Data> = TransformerFactory.forData(), maxSize: UInt = 0) throws -> DiskStorage<String, Data> {
        try DiskStorage(config: DiskConfig(name: "execution", maxSize: maxSize, directory: directory),
                        transformer: transformer, acquireExecutionLease: { try policy.acquire() })
    }
    private func hybrid(_ disk: DiskStorage<String, Data>) -> HybridStorage<String, Data> {
        HybridStorage(memoryStorage: MemoryStorage(config: MemoryConfig()), diskStorage: disk)
    }

    func testCleanupChecksExpiredLeaseBeforeAdvancingEnumeratorAgain() throws {
        let probe = EnumerationProbe()
        let storage = try DiskStorage<String, Data>(
            config: DiskConfig(name: "execution", directory: directory),
            fileManager: EnumeratingFileManager(probe: probe),
            transformer: TransformerFactory.forData(), acquireExecutionLease: { probe.acquire() })
        try storage.setObject(Data([1]), forKey: "first", expiry: .date(.distantPast))
        try storage.setObject(Data([2]), forKey: "second", expiry: .date(.distantPast))
        probe.prepare(urls: ["first", "second"].map { URL(fileURLWithPath: storage.makeFilePath(for: $0)) })
        let releasesBefore = probe.observations.releases

        XCTAssertThrowsError(try storage.removeExpiredObjects()) { error in
            guard case Failure.expired = error else { return XCTFail("Expected expired execution lease, got \(error)") }
        }

        XCTAssertTrue(probe.observations.expired)
        XCTAssertEqual(probe.observations.advances, 1)
        XCTAssertEqual(probe.observations.releases, releasesBefore + 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path).count, 2)
    }

    func testTotalSizeChecksExpiredLeaseBeforeAdvancingEnumeratorAgain() throws {
        let probe = EnumerationProbe()
        let storage = try DiskStorage<String, Data>(
            config: DiskConfig(name: "execution", directory: directory),
            fileManager: EnumeratingFileManager(probe: probe),
            transformer: TransformerFactory.forData(), acquireExecutionLease: { probe.acquire() })
        try storage.setObject(Data([1]), forKey: "first")
        try storage.setObject(Data([2]), forKey: "second")
        probe.prepare(urls: ["first", "second"].map { URL(fileURLWithPath: storage.makeFilePath(for: $0)) })
        let releasesBefore = probe.observations.releases

        XCTAssertNil(storage.totalSize)

        XCTAssertTrue(probe.observations.expired)
        XCTAssertEqual(probe.observations.advances, 1)
        XCTAssertEqual(probe.observations.releases, releasesBefore + 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path).count, 2)
    }

    func testDeniedInitializationDoesNotCreateDirectory() {
        let policy = Policy()
        policy.deny()
        XCTAssertThrowsError(try disk(policy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(policy.counts.acquired, 1)
        XCTAssertEqual(policy.counts.released, 0)
    }

    func testDeniedWriteLeavesDiskUntouched() throws {
        let policy = Policy()
        let storage = try disk(policy)
        policy.deny()
        XCTAssertThrowsError(try storage.setObject(Data([1]), forKey: "key"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path), [])
        XCTAssertEqual(policy.counts.acquired, 2)
        XCTAssertEqual(policy.counts.released, 1)
    }

    func testSuccessfulAndFailedOperationsReleaseExactlyOnce() throws {
        let policy = Policy()
        let storage = try disk(policy)
        XCTAssertEqual(policy.counts.released, 1)
        try storage.setObject(Data([1]), forKey: "key")
        XCTAssertEqual(try storage.entry(forKey: "key").object, Data([1]))
        XCTAssertThrowsError(try storage.entry(forKey: "missing"))
        XCTAssertEqual(policy.counts.acquired, 4)
        XCTAssertEqual(policy.counts.released, 4)
        XCTAssertEqual(policy.counts.active, 0)
    }

    func testTransformerFailureReleasesAndDoesNotWrite() throws {
        let policy = Policy()
        let storage = try disk(policy, transformer: Transformer(toData: { _ in throw Failure.transform }, fromData: { $0 }))
        XCTAssertThrowsError(try storage.setObject(Data([1]), forKey: "key"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path), [])
        XCTAssertEqual(policy.counts.acquired, policy.counts.released)
    }

    func testExpiryDuringSerializationStopsLaterFilesystemEffects() throws {
        let policy = Policy()
        let storage = try disk(policy, transformer: Transformer(toData: { data in
            XCTAssertEqual(policy.counts.active, 1)
            policy.expire()
            return data
        }, fromData: { $0 }))
        XCTAssertThrowsError(try storage.setObject(Data([1]), forKey: "key"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path), [])
        XCTAssertEqual(policy.counts.acquired, policy.counts.released)
    }

    func testExpiryAfterFileCreationStopsExpiryAttributeWrite() throws {
        let policy = Policy()
        let manager = ExpiringFileManager { policy.expire() }
        let storage = try DiskStorage<String, Data>(
            config: DiskConfig(name: "execution", directory: directory), fileManager: manager,
            transformer: TransformerFactory.forData(), acquireExecutionLease: { try policy.acquire() })
        XCTAssertThrowsError(try storage.setObject(Data([1]), forKey: "key", expiry: .date(.distantPast)))
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.makeFilePath(for: "key"))
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertGreaterThan(modified, Date().addingTimeInterval(-60))
        XCTAssertEqual(policy.counts.acquired, policy.counts.released)
        XCTAssertEqual(policy.counts.active, 0)
    }

    func testFromFileTransformerRunsInsideLeaseAndExpiryRejectsMetadataRead() throws {
        let policy = Policy()
        let storage = try disk(policy)
        try storage.setObject(Data([1]), forKey: "key")
        let transformed = storage.transform(transformer: Transformer<Data>(toData: { $0 }, fromData: { $0 }, fromFile: { url in
            XCTAssertEqual(policy.counts.active, 1)
            let value = try Data(contentsOf: url)
            policy.expire()
            return value
        }))
        XCTAssertThrowsError(try transformed.entry(forKey: "key"))
        XCTAssertEqual(policy.counts.acquired, 3)
        XCTAssertEqual(policy.counts.acquired, policy.counts.released)
    }

    func testTransformedStorageRetainsAdmissionPolicy() throws {
        let policy = Policy()
        let storage = try disk(policy).transform(transformer: TransformerFactory.forData())
        policy.deny()
        XCTAssertThrowsError(try storage.setObject(Data([1]), forKey: "key"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path), [])
    }

    func testExpiryCleanupStopsAfterFirstRemovalAndReleases() throws {
        let policy = Policy()
        let storage = try disk(policy)
        for key in ["first", "second", "third"] {
            try storage.setObject(Data([1]), forKey: key, expiry: .date(.distantPast))
        }
        storage.onRemove = { _ in policy.expire() }
        XCTAssertThrowsError(try storage.removeExpiredObjects())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path).count, 2)
        XCTAssertEqual(policy.counts.acquired, policy.counts.released)
    }

    func testSizeEvictionStopsAfterFirstRemovalAndReleases() throws {
        let policy = Policy()
        let storage = try disk(policy, maxSize: 1)
        for key in ["first", "second", "third"] {
            try storage.setObject(Data(repeating: 1, count: 8192), forKey: key)
        }
        storage.onRemove = { _ in policy.expire() }
        XCTAssertThrowsError(try storage.removeExpiredObjects())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path).count, 2)
        XCTAssertEqual(policy.counts.acquired, policy.counts.released)
    }

    func testDeniedRemovalAndMetadataOperationsLeaveExistingFile() throws {
        let policy = Policy()
        let storage = try disk(policy)
        try storage.setObject(Data([1]), forKey: "key")
        policy.deny()
        XCTAssertThrowsError(try storage.entry(forKey: "key"))
        XCTAssertThrowsError(try storage.removeObject(forKey: "key"))
        XCTAssertThrowsError(try storage.removeObjectIfExpired(forKey: "key"))
        XCTAssertThrowsError(try storage.removeAll())
        XCTAssertThrowsError(try storage.removeExpiredObjects())
        XCTAssertThrowsError(try storage.createDirectory())
        XCTAssertThrowsError(try storage.setDirectoryAttributes([.modificationDate: Date()]))
        XCTAssertNil(storage.totalSize)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: storage.makeFilePath(for: "key"))), Data([1]))
        XCTAssertEqual(policy.counts.active, 0)
    }

    func testSyncStorageAcquiresAtDiskExecution() throws {
        let policy = Policy()
        let storage = SyncStorage(storage: hybrid(try disk(policy)), serialQueue: DispatchQueue(label: "cache.execution.sync.test"))
        try storage.setObject(Data([1]), forKey: "key")
        XCTAssertEqual(policy.counts.acquired, 2)
        XCTAssertEqual(policy.counts.released, 2)
    }

    func testQueuedCallbackAcquiresWhenWorkExecutes() throws {
        let policy = Policy()
        let disk = try disk(policy)
        let queue = DispatchQueue(label: "cache.execution.callback.test")
        let storage = AsyncStorage(storage: hybrid(disk), serialQueue: queue)
        let completed = expectation(description: "queued write rejected")
        queue.suspend()
        storage.setObject(Data([1]), forKey: "key") { result in
            if case .success = result { XCTFail("Denied disk write must fail") }
            XCTAssertEqual(policy.counts.active, 0)
            completed.fulfill()
        }
        XCTAssertEqual(policy.counts.acquired, 1)
        policy.deny()
        queue.resume()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(policy.counts.acquired, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.path), [])
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testAsyncStorageReleasesBeforeReturningAndHonorsDenial() async throws {
        let policy = Policy()
        let disk = try disk(policy)
        let storage = AsyncStorage(storage: hybrid(disk), serialQueue: DispatchQueue(label: "cache.execution.async.test"))
        try await storage.setObject(Data([1]), forKey: "key")
        XCTAssertEqual(policy.counts.active, 0)
        XCTAssertEqual(policy.counts.released, 2)
        policy.deny()
        do {
            try await storage.setObject(Data([2]), forKey: "other")
            XCTFail("Denied disk write must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.makeFilePath(for: "other")))
        XCTAssertEqual(policy.counts.active, 0)
    }

    func testMemoryHitAndMemoryOnlyRemovalDoNotAcquireDiskLease() throws {
        let policy = Policy()
        let storage = hybrid(try disk(policy))
        storage.memoryStorage.setObject(Data([1]), forKey: "key")
        policy.deny()
        XCTAssertEqual(try storage.entry(forKey: "key").object, Data([1]))
        try storage.removeInMemoryObject(forKey: "key")
        XCTAssertThrowsError(try storage.memoryStorage.entry(forKey: "key"))
        XCTAssertEqual(policy.counts.acquired, 1)
    }
}
