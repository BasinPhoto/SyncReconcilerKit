//
//  Protocols.swift
//  SyncReconcilerKit
//
//  Created by Sergey Basin on 15.09.2025.
//

import Foundation
import SwiftData

/// DTO from backend
public protocol RemoteStampedDTO {
    associatedtype ID: Hashable
    var id: ID { get }
    var updatedAt: Date { get }
}

/// Local syncable SwiftData-model
public protocol RemoteStampedModel: AnyObject {
    associatedtype ID: Hashable
    var remoteId: ID { get set }
    var updatedAt: Date { get set }
}

/// SwifData-model than can apply DTO data
public protocol MergeAppliable {
    associatedtype DTO
    func apply(_ dto: DTO)
}

/// SwiftData-model can be constructed from DTO
public protocol InitFromDTO {
    associatedtype DTO
    init(dto: DTO)
}

/// Delete policy
public enum DeletionPolicy: Sendable {
    case none              // no need to delete (for pagination responses)
    case hardDeleteMissing // delete local data than not represented in server response
}
