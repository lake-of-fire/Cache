import XCTest
@testable import Cache

final class HybridStorageTests: XCTestCase {
  private let cacheName = "WeirdoCache"
  private let key = "alongweirdkey"
  private let testObject = User(firstName: "John", lastName: "Targaryen")
  private var storage: HybridStorage<String, User>!
  private let fileManager = FileManager()

  override func setUp() {
    super.setUp()
    let memory = MemoryStorage<String, User>(config: MemoryConfig())
    let disk = try! DiskStorage<String, User>(config: DiskConfig(name: "HybridDisk"), transformer: TransformerFactory.forCodable(ofType: User.self))

    storage = HybridStorage(memoryStorage: memory, diskStorage: disk)
  }

  override func tearDown() {
    try? storage.removeAll()
    super.tearDown()
  }

  func testFailedSerializationPreservesPreviousMemoryAndDiskValue() throws {
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    let transformer = Transformer<Data>(
      toData: { value in
        guard value != Data("rejected".utf8) else { throw StorageError.transformerFail }
        return value
      },
      fromData: { $0 }
    )
    let disk = try DiskStorage<String, Data>(
      config: DiskConfig(name: "SerializationFailure", directory: directory),
      transformer: transformer
    )
    let memory = MemoryStorage<String, Data>(config: MemoryConfig())
    let cache = HybridStorage(memoryStorage: memory, diskStorage: disk)
    let original = Data("original".utf8)
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    try cache.setObject(original, forKey: "entry", expiry: .date(expiry))
    var storageNotifications = 0
    var keyNotifications = 0
    cache.addStorageObserver(self) { _, _, _ in storageNotifications += 1 }
    cache.addObserver(self, forKey: "entry") { _, _, _ in keyNotifications += 1 }

    XCTAssertThrowsError(try cache.setObject(Data("rejected".utf8), forKey: "entry"))
    XCTAssertEqual(try cache.object(forKey: "entry"), original)
    XCTAssertEqual(try disk.object(forKey: "entry"), original)
    XCTAssertEqual(try memory.entry(forKey: "entry").expiry.date, expiry)
    XCTAssertEqual(storageNotifications, 0)
    XCTAssertEqual(keyNotifications, 0)
  }

  func testFailedDiskWriteDoesNotPublishMemoryOrNotifications() throws {
    let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fileManager.removeItem(at: directory) }
    let disk = try DiskStorage<String, Data>(
      config: DiskConfig(name: "DiskFailure", directory: directory),
      transformer: TransformerFactory.forData()
    )
    let memory = MemoryStorage<String, Data>(config: MemoryConfig())
    let cache = HybridStorage(memoryStorage: memory, diskStorage: disk)
    let destination = URL(fileURLWithPath: disk.makeFilePath(for: "entry"))
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let sentinel = destination.appendingPathComponent("keep")
    try Data("existing directory".utf8).write(to: sentinel)
    var storageNotifications = 0
    var keyNotifications = 0
    cache.addStorageObserver(self) { _, _, _ in storageNotifications += 1 }
    cache.addObserver(self, forKey: "entry") { _, _, _ in keyNotifications += 1 }

    XCTAssertThrowsError(try cache.setObject(Data("unwritten".utf8), forKey: "entry"))
    XCTAssertFalse(memory.objectExists(forKey: "entry"))
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing directory".utf8))
    XCTAssertEqual(storageNotifications, 0)
    XCTAssertEqual(keyNotifications, 0)
  }

  func testSetObject() throws {
    try when("set to storage") {
      try storage.setObject(testObject, forKey: key)
      let cachedObject = try storage.object(forKey: key)
      XCTAssertEqual(cachedObject, testObject)
    }

    try then("it is set to memory too") {
      let memoryObject = try storage.memoryStorage.object(forKey: key)
      XCTAssertNotNil(memoryObject)
    }

    try then("it is set to disk too") {
      let diskObject = try storage.diskStorage.object(forKey: key)
      XCTAssertNotNil(diskObject)
    }
  }

  func testEntry() throws {
    let expiryDate = Date()
    try storage.setObject(testObject, forKey: key, expiry: .date(expiryDate))
    let entry = try storage.entry(forKey: key)

    XCTAssertEqual(entry.object, testObject)
    XCTAssertEqual(entry.expiry.date, expiryDate)
  }

  /// Should resolve from disk and set in-memory cache if object not in-memory
  func testObjectCopyToMemory() throws {
    try when("set to disk only") {
      try storage.diskStorage.setObject(testObject, forKey: key)
      let cachedObject: User = try storage.object(forKey: key)
      XCTAssertEqual(cachedObject, testObject)
    }

    try then("there is no object in memory") {
      let inMemoryCachedObject = try storage.memoryStorage.object(forKey: key)
      XCTAssertEqual(inMemoryCachedObject, testObject)
    }
  }
  
  func testEntityExpiryForObjectCopyToMemory() throws {
    let date = Date().addingTimeInterval(3)
    try when("set to disk only") {
      try storage.diskStorage.setObject(testObject, forKey: key, expiry: .seconds(3))
      let entry = try storage.entry(forKey: key)
      //accuracy for slow disk processes
      XCTAssertEqual(entry.expiry.date.timeIntervalSinceReferenceDate,
                     date.timeIntervalSinceReferenceDate,
                     accuracy: 1.0)
    }
    
    try then("there is no object in memory") {
      let entry = try storage.memoryStorage.entry(forKey: key)
      //accuracy for slow disk processes
      XCTAssertEqual(entry.expiry.date.timeIntervalSinceReferenceDate,
                     date.timeIntervalSinceReferenceDate,
                     accuracy: 1.0)
    }
  }

  /// Removes cached object from memory and disk
  func testRemoveObject() throws {
    try given("set to storage") {
      try storage.setObject(testObject, forKey: key)
      XCTAssertNotNil(try storage.object(forKey: key))
    }

    try when("remove object from storage") {
      try storage.removeObject(forKey: key)
      let cachedObject = try? storage.object(forKey: key)
      XCTAssertNil(cachedObject)
    }

    then("there is no object in memory") {
      let memoryObject = try? storage.memoryStorage.object(forKey: key)
      XCTAssertNil(memoryObject)
    }

    then("there is no object on disk") {
      let diskObject = try? storage.diskStorage.object(forKey: key)
      XCTAssertNil(diskObject)
    }
  }

  /// Clears memory and disk cache
  func testClear() throws {
    try when("set and remove all") {
      try storage.setObject(testObject, forKey: key)
      try storage.removeAll()
      XCTAssertNil(try? storage.object(forKey: key))
    }

    then("there is no object in memory") {
      let memoryObject = try? storage.memoryStorage.object(forKey: key)
      XCTAssertNil(memoryObject)
    }

    then("there is no object on disk") {
      let diskObject = try? storage.diskStorage.object(forKey: key)
      XCTAssertNil(diskObject)
    }
  }

  func testDiskEmptyAfterClear() throws {
    try storage.setObject(testObject, forKey: key)
    try storage.removeAll()

    then("the disk directory is empty") {
      let contents = try? fileManager.contentsOfDirectory(atPath: storage.diskStorage.path)
      XCTAssertEqual(contents?.count, 0)
    }
  }

  /// Clears expired objects from memory and disk cache
  func testClearExpired() throws {
    let expiry1: Expiry = .date(Date().addingTimeInterval(-10))
    let expiry2: Expiry = .date(Date().addingTimeInterval(10))
    let key1 = "key1"
    let key2 = "key2"

    try when("save 2 objects with different keys and expiry") {
      try storage.setObject(testObject, forKey: key1, expiry: expiry1)
      try storage.setObject(testObject, forKey: key2, expiry: expiry2)
    }

    try when("remove expired objects") {
      try storage.removeExpiredObjects()
    }

    then("object with key2 survived") {
      XCTAssertNil(try? storage.object(forKey: key1))
      XCTAssertNotNil(try? storage.object(forKey: key2))
    }
  }

  // MARK: - Storage observers

  func testAddStorageObserver() throws {
    var changes = [StorageChange<String>]()
    storage.addStorageObserver(self) { _, _, change in
      changes.append(change)
    }

    try storage.setObject(testObject, forKey: "user1")
    XCTAssertEqual(changes, [StorageChange.add(key: "user1")])
    XCTAssertEqual(storage.storageObservations.count, 1)

    storage.addStorageObserver(self) { _, _, _ in }
    XCTAssertEqual(storage.storageObservations.count, 2)
  }

  func testRemoveStorageObserver() {
    let token = storage.addStorageObserver(self) { _, _, _ in }
    XCTAssertEqual(storage.storageObservations.count, 1)

    token.cancel()
    XCTAssertTrue(storage.storageObservations.isEmpty)
  }

  func testRemoveAllStorageObservers() {
    storage.addStorageObserver(self) { _, _, _ in }
    storage.addStorageObserver(self) { _, _, _ in }
    XCTAssertEqual(storage.storageObservations.count, 2)

    storage.removeAllStorageObservers()
    XCTAssertTrue(storage.storageObservations.isEmpty)
  }

  // MARK: - Key observers

  func testAddObserverForKey() throws {
    var changes = [KeyChange<User>]()
    storage.addObserver(self, forKey: "user1") { _, _, change in
      changes.append(change)
    }

    XCTAssertEqual(storage.keyObservations.count, 1)

    try storage.setObject(testObject, forKey: "user1")
    XCTAssertEqual(changes, [KeyChange.edit(before: nil, after: testObject)])

    storage.addObserver(self, forKey: "user1") { _, _, _ in }
    XCTAssertEqual(storage.keyObservations.count, 1)

    storage.addObserver(self, forKey: "user2") { _, _, _ in }
    XCTAssertEqual(storage.keyObservations.count, 2)
  }

  func testRemoveKeyObserver() {
    // Test remove for key
    storage.addObserver(self, forKey: "user1") { _, _, _ in }
    XCTAssertEqual(storage.keyObservations.count, 1)

    storage.removeObserver(forKey: "user1")
    XCTAssertTrue(storage.storageObservations.isEmpty)

    // Test remove by token
    let token = storage.addObserver(self, forKey: "user2") { _, _, _ in }
    XCTAssertEqual(storage.keyObservations.count, 1)

    token.cancel()
    XCTAssertTrue(storage.storageObservations.isEmpty)
  }

  func testRemoveAllKeyObservers() {
    storage.addObserver(self, forKey: "user1") { _, _, _ in }
    storage.addObserver(self, forKey: "user2") { _, _, _ in }
    XCTAssertEqual(storage.keyObservations.count, 2)

    storage.removeAllKeyObservers()
    XCTAssertTrue(storage.keyObservations.isEmpty)
  }

  func testSupersededKeyObserverTokenCannotCancelReplacement() throws {
    var oldEvents = 0
    var currentEvents = 0
    let predecessor = storage.addObserver(self, forKey: "reused") { _, _, _ in
      oldEvents += 1
    }
    let successor = storage.addObserver(self, forKey: "reused") { _, _, _ in
      currentEvents += 1
    }

    predecessor.cancel()
    try storage.setObject(testObject, forKey: "reused")
    XCTAssertEqual(oldEvents, 0)
    XCTAssertEqual(currentEvents, 1)

    successor.cancel()
    try storage.setObject(testObject, forKey: "reused")
    XCTAssertEqual(currentEvents, 1)
  }

  func testNamedDiskFilenameRemovalNotifiesTheRegisteredKey() throws {
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("named-observer-" + UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }
    let disk = try DiskStorage<String, User>(
      config: DiskConfig(name: "NamedDisk", directory: directory, keysAsFilenames: true),
      transformer: TransformerFactory.forCodable(ofType: User.self)
    )
    let cache = HybridStorage(
      memoryStorage: MemoryStorage<String, User>(config: MemoryConfig()),
      diskStorage: disk
    )
    var changes = [KeyChange<User>]()
    cache.addObserver(self, forKey: "entry.json") { _, _, change in
      changes.append(change)
    }

    try disk.setObject(testObject, forKey: "entry.json")
    try disk.removeObject(forKey: "entry.json")
    XCTAssertEqual(changes, [.remove])
  }

  func testDiskRemovalDoesNotMatchUnrelatedKeyHashInDirectory() throws {
    let watchedKey = "watched-key"
    // The parent path contains the watched key's hash, but the removed file
    // belongs to a different key. Substring-based matching falsely notified it.
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("hash-observer-" + UUID().uuidString + "-" + MD5(watchedKey), isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }
    let disk = try DiskStorage<String, User>(
      config: DiskConfig(name: "ScopedDisk", directory: directory),
      transformer: TransformerFactory.forCodable(ofType: User.self)
    )
    let cache = HybridStorage(
      memoryStorage: MemoryStorage<String, User>(config: MemoryConfig()),
      diskStorage: disk
    )
    var removalCount = 0
    cache.addObserver(self, forKey: watchedKey) { _, _, _ in
      removalCount += 1
    }

    try disk.setObject(testObject, forKey: "different-key")
    try disk.removeObject(forKey: "different-key")
    XCTAssertEqual(removalCount, 0)
  }

  func testExpiredObserverCallbackCannotRemoveReplacementRegistration() throws {
    var oldObserver: NSObject? = NSObject()
    let predecessor = storage.addObserver(oldObserver!, forKey: "reentrant") { _, _, _ in
      XCTFail("Retired observer must not receive events")
    }
    let retiredCallback = try XCTUnwrap(storage.keyObservations["reentrant"])
    oldObserver = nil

    var delivered = 0
    let successor = storage.addObserver(self, forKey: "reentrant") { _, _, _ in
      delivered += 1
    }
    retiredCallback(storage, .remove)
    XCTAssertEqual(storage.keyObservations.count, 1)

    try storage.setObject(testObject, forKey: "reentrant")
    XCTAssertEqual(delivered, 1)
    predecessor.cancel()
    XCTAssertEqual(storage.keyObservations.count, 1)
    successor.cancel()
    XCTAssertTrue(storage.keyObservations.isEmpty)
  }

}
