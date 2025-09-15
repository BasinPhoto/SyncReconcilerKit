//
//  Protocols.swift
//  SyncReconcilerKit
//
//  Created by Sergey Basin on 15.09.2025.
//

import Foundation
import SwiftData

/// DTO from backend
public protocol RemoteStampedDTO: Sendable {
    associatedtype ID: Hashable & Sendable
    var id: ID { get }
    var updatedAt: Date { get }
}

/// Local syncable SwiftData-model
public protocol RemoteStampedModel: AnyObject {
    associatedtype RemoteID: Hashable & Sendable
    var remoteId: RemoteID { get set }
    var updatedAt: Date { get set }
}

/// SwiftData model that can apply DTO data
public protocol MergeAppliable {
    associatedtype DTO
    func apply(_ dto: DTO)
}

/// SwiftData-model can be constructed from DTO
public protocol InitFromDTO {
    associatedtype DTO: RemoteStampedDTO & Sendable
    init(dto: DTO)
}

/// SwiftData-model can be soft deleted by set deletedAt
public protocol SoftDeletable: AnyObject {
    var deletedAt: Date? { get set }
}

/// Delete policy
public enum DeletionPolicy: Sendable {
    case none
    case hardDeleteMissing
    case softDeleteMissing
}

/// Composite protocol: a SwiftData model that can be synced from a stamped DTO
/// and provides merge/init capabilities. This also ensures DTO/ID type consistency.
public protocol SyncableModel: PersistentModel, RemoteStampedModel, MergeAppliable, InitFromDTO
where
    DTO: RemoteStampedDTO & Sendable,
    DTO.ID == RemoteID
{ }
