import Foundation
import CoreData
import CloudKit

@objc(Book)
class Book: NSManagedObject {
    @NSManaged var readState: BookReadState
    @NSManaged var startedReading: Date?
    @NSManaged var finishedReading: Date?

    @NSManaged var isbn13: String?
    @NSManaged var googleBooksId: String?
    @NSManaged var manualBookId: String?

    @NSManaged var title: String
    @NSManaged private(set) var authors: [Author]
    @NSManaged private(set) var authorSort: String // Calculated sort helper

    @NSManaged var pageCount: NSNumber?
    @NSManaged var publicationDate: Date?
    @NSManaged var bookDescription: String?
    @NSManaged var coverImage: Data?
    @NSManaged var notes: String?
    @NSManaged var rating: NSNumber? // Valid values are 1-5.
    @NSManaged var languageCode: String? // ISO 639.1: two-digit language code
    @NSManaged var currentPage: NSNumber?
    @NSManaged var sort: NSNumber?

    @NSManaged var subjects: Set<Subject>
    @NSManaged private(set) var lists: Set<List>

    // Raw value of a BookKey option set. Represents the keys which have been modified locally but
    // not uploaded to a remote store.
    @NSManaged private var keysPendingRemoteUpdate: Int32

    func addPendingRemoteUpdateKeys(_ keys: [BookCKRecordKey]) {
        let newKeysPendingRemoteUpdate = BookCKRecordKey.Bitmask.unionAll(keys.map { $0.bitmask })
        let newValue = BookCKRecordKey.Bitmask(rawValue: keysPendingRemoteUpdate).union(newKeysPendingRemoteUpdate).rawValue
        if keysPendingRemoteUpdate != newValue {
            keysPendingRemoteUpdate = newValue
        }
    }

    func removePendingRemoteUpdateKeys(_ keys: [BookCKRecordKey]) {
        let newKeysNotPendingRemoteUpdate = BookCKRecordKey.Bitmask.unionAll(keys.map { $0.bitmask })
        var newValue = BookCKRecordKey.Bitmask(rawValue: keysPendingRemoteUpdate)
        newValue.remove(newKeysNotPendingRemoteUpdate)
        if keysPendingRemoteUpdate != newValue.rawValue {
            keysPendingRemoteUpdate = newValue.rawValue
        }
    }

    static let pendingRemoteUpdatesPredicate = NSPredicate(format: "%K != 0", #keyPath(Book.keysPendingRemoteUpdate))

    @NSManaged var remoteIdentifier: String?
    @NSManaged private var ckRecordEncodedSystemFields: Data?

    convenience init(context: NSManagedObjectContext, readState: BookReadState) {
        self.init(context: context)
        self.readState = readState
        if readState == .reading {
            startedReading = Date()
        }
        if readState == .finished {
            startedReading = Date()
            finishedReading = Date()
        }
    }

    override func willSave() {
        super.willSave()

        // The sort manipulation should be in a method which allows setting of dates
        if readState == .toRead && sort == nil {
            let maxSort = Book.maxSort(fromContext: managedObjectContext!) ?? 0
            self.sort = (maxSort + 1).nsNumber
        }

        // Sort is not (yet) supported for non To Read books
        if readState != .toRead && sort != nil {
            self.sort = nil
        }

        // Update the modified keys record for Books which have a remote identifier, but only
        // on the viewContext.
        if managedObjectContext == PersistentStoreManager.container.viewContext && remoteIdentifier != nil {
            let keysPendingRemoteUpdate = changedValues().keys.compactMap { BookCKRecordKey.from(coreDataKey: $0) }.distinct()
            addPendingRemoteUpdateKeys(keysPendingRemoteUpdate)
            print("Updated bitmask: \(keysPendingRemoteUpdate.map { $0.rawValue }.joined(separator: ", "))")
        }
    }

    override func prepareForDeletion() {
        super.prepareForDeletion()
        for orphanedSubject in subjects.filter({ $0.books.count == 1 }) {
            orphanedSubject.delete()
        }

        if managedObjectContext == PersistentStoreManager.container.viewContext,
            let existingRemoteRecord = self.storedCKRecordSystemFields() {
            PendingRemoteDeletionItem(context: managedObjectContext!, ckRecordID: existingRemoteRecord.recordID)
        }
    }
}

extension Book {

    func setAuthors(_ authors: [Author]) {
        self.authors = authors
        self.authorSort = Author.authorSort(authors)
    }

    // FUTURE: make a convenience init which takes a fetch result?
    func populate(fromFetchResult fetchResult: FetchResult) {
        googleBooksId = fetchResult.id
        title = fetchResult.title
        populateAuthors(fromStrings: fetchResult.authors)
        bookDescription = fetchResult.description
        subjects = Set(fetchResult.subjects.map { Subject.getOrCreate(inContext: self.managedObjectContext!, withName: $0) })
        coverImage = fetchResult.coverImage
        pageCount = fetchResult.pageCount?.nsNumber
        publicationDate = fetchResult.publishedDate
        isbn13 = fetchResult.isbn13
        languageCode = fetchResult.languageCode
    }

    func populate(fromSearchResult searchResult: SearchResult, withCoverImage coverImage: Data? = nil) {
        googleBooksId = searchResult.id
        title = searchResult.title
        populateAuthors(fromStrings: searchResult.authors)
        isbn13 = searchResult.isbn13
        self.coverImage = coverImage
    }

    private func populateAuthors(fromStrings authors: [String]) {
        let authorNames: [(String?, String)] = authors.map {
            if let range = $0.range(of: " ", options: .backwards) {
                let firstNames = $0[..<range.upperBound].trimming()
                let lastName = $0[range.lowerBound...].trimming()

                return (firstNames: firstNames, lastName: lastName)
            } else {
                return (firstNames: nil, lastName: $0)
            }
        }

        self.setAuthors(authorNames.map { Author(lastName: $0.1, firstNames: $0.0) })
    }

    static func get(fromContext context: NSManagedObjectContext, googleBooksId: String? = nil, isbn: String? = nil) -> Book? {
        // if both are nil, leave early
        guard googleBooksId != nil || isbn != nil else { return nil }

        // First try fetching by google books ID
        if let googleBooksId = googleBooksId {
            let googleBooksfetch = NSManagedObject.fetchRequest(Book.self, limit: 1)
            googleBooksfetch.predicate = NSPredicate(format: "%K == %@", #keyPath(Book.googleBooksId), googleBooksId)
            googleBooksfetch.returnsObjectsAsFaults = false
            if let result = (try! context.fetch(googleBooksfetch)).first { return result }
        }

        // then try fetching by ISBN
        if let isbn = isbn {
            let isbnFetch = NSManagedObject.fetchRequest(Book.self, limit: 1)
            isbnFetch.predicate = NSPredicate(format: "%K == %@", #keyPath(Book.isbn13), isbn)
            isbnFetch.returnsObjectsAsFaults = false
            return (try! context.fetch(isbnFetch)).first
        }

        return nil
    }

    static func maxSort(fromContext context: NSManagedObjectContext) -> Int32? {
        // FUTURE: Could use a fetch expression to just return the max value
        let fetchRequest = NSManagedObject.fetchRequest(Book.self, limit: 1)
        fetchRequest.predicate = NSPredicate(format: "%K == %ld", #keyPath(Book.readState), BookReadState.toRead.rawValue)
        fetchRequest.sortDescriptors = [NSSortDescriptor(\Book.sort, ascending: false)]
        fetchRequest.returnsObjectsAsFaults = false
        return (try! context.fetch(fetchRequest)).first?.sort?.int32
    }

    @objc func validateAuthors(_ value: AutoreleasingUnsafeMutablePointer<AnyObject?>) throws {
        // nil authors property will be validated by the validation set on the model
        guard let authors = value.pointee as? [Author] else { return }
        if authors.isEmpty {
            throw BookValidationError.noAuthors.NSError()
        }
    }

    @objc func validateTitle(_ value: AutoreleasingUnsafeMutablePointer<AnyObject?>) throws {
        // nil title property will be validated by the validation set on the model
        guard let title = value.pointee as? String else { return }
        if title.isEmptyOrWhitespace {
            throw BookValidationError.missingTitle.NSError()
        }
    }

    @objc func validateIsbn13(_ value: AutoreleasingUnsafeMutablePointer<AnyObject?>) throws {
        guard let isbn13 = value.pointee as? String else { return }
        if ISBN13(isbn13) == nil {
            throw BookValidationError.invalidIsbn.NSError()
        }
    }

    @objc func validateLanguageCode(_ value: AutoreleasingUnsafeMutablePointer<AnyObject?>) throws {
        guard let languageCode = value.pointee as? String else { return }
        if Language.byIsoCode[languageCode] == nil {
            throw BookValidationError.invalidLanguageCode.NSError()
        }
    }

    override func validateForUpdate() throws {
        try super.validateForUpdate()
        try interPropertyValiatation()
    }

    override func validateForInsert() throws {
        try super.validateForInsert()
        try interPropertyValiatation()
    }

    func interPropertyValiatation() throws {
        // FUTURE: Check read state with current page
        switch readState {
        case .toRead:
            if startedReading != nil || finishedReading != nil {
                throw BookValidationError.invalidReadDates.NSError()
            }
        case .reading:
            if startedReading == nil || finishedReading != nil {
                throw BookValidationError.invalidReadDates.NSError()
            }
        case .finished:
            if startedReading == nil || finishedReading == nil {
                throw BookValidationError.invalidReadDates.NSError()
            }
        }

        if googleBooksId == nil && manualBookId == nil {
            throw BookValidationError.missingIdentifier.NSError()
        }
        if googleBooksId != nil && manualBookId != nil {
            throw BookValidationError.conflictingIdentifiers.NSError()
        }

        if keysPendingRemoteUpdate != 0 && remoteIdentifier == nil {
            throw BookValidationError.bitmaskPresentWithoutRemoteIdentifier.NSError()
	      }
    }

    func startReading() {
        guard readState == .toRead else {
            #if DEBUG
            fatalError("Attempted to start a book in state \(readState)")
            #else
            return
            #endif
        }
        readState = .reading
        startedReading = Date()
    }

    func finishReading() {
        guard readState == .reading else {
            #if DEBUG
            fatalError("Attempted to finish a book in state \(readState)")
            #else
            return
            #endif
        }
        readState = .finished
        finishedReading = Date()
    }

    func updateReadState() {
        if startedReading == nil {
            readState = .toRead
        } else if finishedReading == nil {
            readState = .reading
        } else {
            readState = .finished
        }
    }
}

extension Book {

    func storedCKRecordSystemFields() -> CKRecord? {
        guard let systemFieldsData = ckRecordEncodedSystemFields else { return nil }
        return CKRecord(systemFieldsData: systemFieldsData)!
    }

    func storeCKRecordSystemFields(_ ckRecord: CKRecord?) {
        ckRecordEncodedSystemFields = ckRecord?.encodedSystemFields()
    }

    func CKRecordForInsert(zoneID: CKRecordZoneID) -> CKRecord {
        guard remoteIdentifier == nil && ckRecordEncodedSystemFields == nil else { fatalError("Unexpected attempt to insert a record which already exists.") }
        let recordName = googleBooksId ?? manualBookId!
        let ckRecord = CKRecord(recordType: "Book", recordID: CKRecordID(recordName: recordName, zoneID: zoneID))
        for key in BookCKRecordKey.all {
            ckRecord[key] = key.value(from: self)
        }
        return ckRecord
    }

    func CKRecordForDifferentialUpdate() -> CKRecord {
        guard let ckRecord = storedCKRecordSystemFields() else { fatalError("No stored CKRecord to use for differential update") }
        let changedKeys = BookCKRecordKey.Bitmask(rawValue: keysPendingRemoteUpdate)
        for key in BookCKRecordKey.all.filter({ changedKeys.contains($0.bitmask) }) {
            ckRecord[key] = key.value(from: self)
        }
        return ckRecord
    }

    func updateFrom(serverRecord: CKRecord) {
        if let existingCKRecordSystemFields = storedCKRecordSystemFields(), existingCKRecordSystemFields.recordChangeTag == serverRecord.recordChangeTag {
            print("CKRecord has same change tag; skipping update")
            return
        }

        if remoteIdentifier != serverRecord.recordID.recordName {
            print("Updating remoteIdentifier for book")
            remoteIdentifier = serverRecord.recordID.recordName
        }

        storeCKRecordSystemFields(serverRecord)

        for key in BookCKRecordKey.all {
            key.setValue(serverRecord[key], for: self)
        }
    }

    static func withRemoteIdentifier(_ id: String) -> NSPredicate {
        return NSPredicate(format: "%K == %@", #keyPath(Book.remoteIdentifier), id)
    }

    static func withRemoteIdentifiers(_ ids: [String]) -> NSPredicate {
        return NSPredicate(format: "%K in %@", #keyPath(Book.remoteIdentifier), ids)
    }
}

enum BookValidationError: Int {
    case missingTitle = 1
    case invalidIsbn = 2
    case invalidReadDates = 3
    case invalidLanguageCode = 4
    case missingIdentifier = 5
    case conflictingIdentifiers = 6
    case noAuthors = 7
    case bitmaskPresentWithoutRemoteIdentifier = 8
}

extension BookValidationError {
    var description: String {
        switch self {
        case .missingTitle: return "Title must be non-empty or whitespace"
        case .invalidIsbn: return "Isbn13 must be a valid ISBN"
        case .invalidReadDates: return "StartedReading and FinishedReading must align with ReadState"
        case .invalidLanguageCode: return "LanguageCode must be an ISO-639.1 value"
        case .conflictingIdentifiers: return "GoogleBooksId and ManualBooksId cannot both be non nil"
        case .missingIdentifier: return "GoogleBooksId and ManualBooksId cannot both be nil"
        case .noAuthors: return "Authors array must be non-empty"
        case .bitmaskPresentWithoutRemoteIdentifier: return "A bitmask must not be present on a record without a remote identifier"
        }
    }

    func NSError() -> NSError {
        return Foundation.NSError(domain: "BookErrorDomain", code: self.rawValue, userInfo: [NSLocalizedDescriptionKey: self.description])
    }
}
