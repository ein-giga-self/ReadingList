//
//  book.swift
//  books
//
//  Created by Andrew Bennet on 09/11/2015.
//  Copyright © 2015 Andrew Bennet. All rights reserved.
//

import Foundation
import CoreData

@objc(Book)
class Book: NSManagedObject {
    // Book Metadata
    @NSManaged fileprivate(set) var title: String
    @NSManaged fileprivate(set) var subtitle: String?
    @NSManaged fileprivate(set) var authorList: String?
    @NSManaged fileprivate(set) var isbn13: String?
    @NSManaged fileprivate(set) var pageCount: NSNumber?
    @NSManaged fileprivate(set) var publishedDate: Date?
    @NSManaged fileprivate(set) var bookDescription: String?
    @NSManaged fileprivate(set) var coverImage: Data?
    
    // Reading Information
    @NSManaged var readState: BookReadState
    @NSManaged var startedReading: Date?
    @NSManaged var finishedReading: Date?
    
    // Other Metadata
    @NSManaged var sort: NSNumber?
    
    func Populate(_ metadata: BookMetadata) {
        title = metadata.title
        authorList = metadata.authorList
        isbn13 = metadata.isbn13
        pageCount = metadata.pageCount as NSNumber?
        publishedDate = metadata.publishedDate
        bookDescription = metadata.bookDescription
        coverImage = metadata.coverImage
    }
    
    func Populate(_ readingInformation: BookReadingInformation) {
        readState = readingInformation.readState
        startedReading = readingInformation.startedReading
        finishedReading = readingInformation.finishedReading
        // Wipe out the sort if we have moved out of this section
        if readState != .toRead {
            sort = nil
        }
    }
}



/// A mutable, non-persistent representation of a Book object.
/// Useful for maintaining in-creation books, or books being edited.
class BookMetadata {
    var title: String!
    var subtitle: String?
    var isbn13: String?
    var authorList: String?
    var pageCount: Int?
    var publishedDate: Date?
    var bookDescription: String?
    var coverUrl: URL?
    var coverImage: Data?
}

class BookReadingInformation {
    var readState: BookReadState!
    var startedReading: Date?
    var finishedReading: Date?
}

/// The availale reading progress states
@objc enum BookReadState : Int32, CustomStringConvertible {
    case reading = 1
    case toRead = 2
    case finished = 3
    
    var description: String {
        switch self{
        case .reading:
            return "Reading"
        case .toRead:
            return "To Read"
        case .finished:
            return "Finished"
        }
    }
}
