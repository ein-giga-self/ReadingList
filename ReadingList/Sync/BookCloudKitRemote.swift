import Foundation
import CoreData
import CloudKit

class BookCloudKitRemote {
    let bookZoneName = "BookZone"

    private let userRecordNameKey = "CK_UserRecordName"

    private(set) var userRecordName: String!
    private(set) var bookZoneID: CKRecordZone.ID!

    var privateDB: CKDatabase {
        return CKContainer.default().privateCloudDatabase
    }

    var isInitialised: Bool {
        return bookZoneID != nil
    }

    func initialise(completion: @escaping (Error?) -> Void) {
        if let userRecordName = UserDefaults.standard.string(forKey: userRecordNameKey) {
            createZoneAndSubscription(userRecordName: userRecordName, completion: completion)
        } else {
            CKContainer.default().fetchUserRecordID { ckRecordID, error in
                if let error = error {
                    completion(error)
                } else {
                    UserDefaults.standard.set(ckRecordID!.recordName, forKey: self.userRecordNameKey)
                    self.createZoneAndSubscription(userRecordName: ckRecordID!.recordName, completion: completion)
                }
            }
        }
    }

    private func createZoneAndSubscription(userRecordName: String, completion: @escaping (Error?) -> Void) {
        self.userRecordName = userRecordName
        self.bookZoneID = CKRecordZone.ID(zoneName: bookZoneName, ownerName: userRecordName)

        // Create the book zone (TODO: Do not create if already exists?)
        let bookZone = CKRecordZone(zoneID: bookZoneID)
        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [bookZone], recordZoneIDsToDelete: nil)
        createZoneOperation.modifyRecordZonesCompletionBlock = { zone, zoneID, error in
            if let error = error { completion(error) }
        }
        createZoneOperation.qualityOfService = .userInitiated
        privateDB.add(createZoneOperation)

        // Subscribe to changes
        let subscription = CKRecordZoneSubscription(zoneID: bookZone.zoneID, subscriptionID: "BookChanges")
        subscription.notificationInfo = {
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            return info
        }()
        let modifySubscriptionOperation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
        modifySubscriptionOperation.addDependency(createZoneOperation)
        modifySubscriptionOperation.qualityOfService = .userInitiated
        modifySubscriptionOperation.modifySubscriptionsCompletionBlock = { _, _, error in
            if let error = error {
                completion(error)
            } else {
                print("Subscription modified")
                completion(nil)
            }
        }
        privateDB.add(modifySubscriptionOperation)
    }

    func fetchRecordChanges(changeToken: CKServerChangeToken?, completion: @escaping (Error?, CKChangeCollection?) -> Void) {
        print("Fetching record changes since change token \(String(describing: changeToken))")

        var changedRecords = [CKRecord]()
        var deletedRecordIDs = [CKRecord.ID]()

        let options = CKFetchRecordZoneChangesOperation.ZoneOptions()
        options.previousServerChangeToken = changeToken

        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [bookZoneID], optionsByRecordZoneID: [bookZoneID: options])
        operation.qualityOfService = .userInitiated
        operation.recordChangedBlock = { changedRecords.append($0) }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedRecordIDs.append(recordID)
        }
        operation.recordZoneChangeTokensUpdatedBlock = { _, changeToken, _ in
            print("Change token reported updated to \(String(describing: changeToken))")
        }
        operation.recordZoneFetchCompletionBlock = { _, changeToken, _, _, error in
            print("Record change fetch batch operation complete")
            if let error = error {
                completion(error, nil)
                return
            }
            guard let changeToken = changeToken else { fatalError("Unexpectedly missing change token") }
            let changes = CKChangeCollection(changedRecords: changedRecords, deletedRecordIDs: deletedRecordIDs, newChangeToken: changeToken)
            completion(nil, changes)
        }
        privateDB.add(operation)
    }

    func upload(_ records: [CKRecord], completion: @escaping (Error?) -> Void) {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.qualityOfService = .userInitiated
        operation.modifyRecordsCompletionBlock = { _, _, error in
            completion(error)
        }
        CKContainer.default().privateCloudDatabase.add(operation)
    }

    func remove(_ recordIDs: [CKRecord.ID], completion: @escaping (Error?) -> Void) {
        let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
        operation.qualityOfService = .userInitiated
        operation.modifyRecordsCompletionBlock = { _, _, error in
            completion(error)
        }
        CKContainer.default().privateCloudDatabase.add(operation)
    }
}

class CKChangeCollection {
    let changedRecords: [CKRecord]
    let deletedRecordIDs: [CKRecord.ID]
    let newChangeToken: CKServerChangeToken

    init(changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], newChangeToken: CKServerChangeToken) {
        self.changedRecords = changedRecords
        self.deletedRecordIDs = deletedRecordIDs
        self.newChangeToken = newChangeToken
    }

    var isEmpty: Bool {
        return changedRecords.isEmpty && deletedRecordIDs.isEmpty
    }
}