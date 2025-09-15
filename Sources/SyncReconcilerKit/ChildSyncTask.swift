//
//  ChildSyncTask.swift
//  SyncReconcilerKit
//
//  Created by Sergey Basin on 15.09.2025.
//

import Foundation
import SwiftData

/// Sync task that describes how to sync children for a concrete parent model
public struct ChildSyncTask<ParentDTO, ParentModel, ChildModel>: Sendable
where
    ParentDTO: Sendable,
    ParentModel: PersistentModel & RemoteStampedModel,
    ChildModel: SyncableModel
{
    public typealias PDTO = ParentDTO
    public typealias PM = ParentModel
    public typealias CM = ChildModel
    public typealias CDTO = ChildModel.DTO

    /// Extract children DTOs from parent DTO
    public let extract: @Sendable (PDTO) -> [CDTO]

    /// Get existed children by IDs set
    public let fetchExistingByIds: @Sendable (_ ids: Set<CM.RemoteID>, _ context: ModelContext) throws -> [CM]

    /// Get children scope for deletion
    public let fetchScopeForDeletion: @Sendable (_ parent: PM, _ context: ModelContext) throws -> [CM]

    /// Extra work (e.g., set link to parent)
    public let applyExtra: @Sendable (_ model: CM, _ dto: CDTO, _ parent: PM, _ context: ModelContext) -> Void

    /// Children delete policy
    public let deletionPolicy: DeletionPolicy
    
    ///
    public let requireNonEmptyChildSlice: Bool

    public init(
        extract: @Sendable @escaping (PDTO) -> [CDTO],
        fetchExistingByIds: @Sendable @escaping (_ ids: Set<CM.RemoteID>, _ context: ModelContext) throws -> [CM],
        fetchScopeForDeletion: @Sendable @escaping (_ parent: PM, _ context: ModelContext) throws -> [CM],
        applyExtra: @Sendable @escaping (_ model: CM, _ dto: CDTO, _ parent: PM, _ context: ModelContext) -> Void = { _,_,_,_ in },
        deletionPolicy: DeletionPolicy,
        requireNonEmptyChildSlice: Bool = false
    ) {
        self.extract = extract
        self.fetchExistingByIds = fetchExistingByIds
        self.fetchScopeForDeletion = fetchScopeForDeletion
        self.applyExtra = applyExtra
        self.deletionPolicy = deletionPolicy
        self.requireNonEmptyChildSlice = requireNonEmptyChildSlice
    }
}

/// Type-erasure to keep different children types in one array
public struct AnyChildTask<ParentDTO, ParentModel>: Sendable
where
    ParentDTO: Sendable,
    ParentModel: PersistentModel & RemoteStampedModel
{
    private let _run: @Sendable (_ parentDTOs: [ParentDTO],
                       _ parentById: [ParentModel.RemoteID: ParentModel],
                       _ extractParentId: @Sendable (ParentDTO) -> ParentModel.RemoteID,
                       _ context: ModelContext) throws -> Void

    public init<ChildModel>(
        _ base: ChildSyncTask<ParentDTO, ParentModel, ChildModel>,
        parentId: @Sendable @escaping (ParentDTO) -> ParentModel.RemoteID
    ) where
        ChildModel: SyncableModel
    {
        self._run = { parentDTOs, parentById, extractParentId, context in
            try runConcrete(base,
                            parentDTOs: parentDTOs,
                            parentById: parentById,
                            extractParentId: extractParentId,
                            context: context)
        }
    }

    public func run(parentDTOs: [ParentDTO],
                    parentById: [ParentModel.RemoteID: ParentModel],
                    extractParentId: @Sendable (ParentDTO) -> ParentModel.RemoteID,
                    in context: ModelContext) throws {
        try _run(parentDTOs, parentById, extractParentId, context)
    }
}

private func runConcrete<ParentDTO, ParentModel, ChildModel>(
    _ task: ChildSyncTask<ParentDTO, ParentModel, ChildModel>,
    parentDTOs: [ParentDTO],
    parentById: [ParentModel.RemoteID: ParentModel],
    extractParentId: @Sendable (ParentDTO) -> ParentModel.RemoteID,
    context: ModelContext
) throws
where
    ParentDTO: Sendable,
    ParentModel: PersistentModel & RemoteStampedModel,
    ChildModel: SyncableModel
{
    // 1) Group children by parent
    var grouped: [ParentModel.RemoteID: [ChildModel.DTO]] = [:]
    var allChildIds = Set<ChildModel.RemoteID>()

    for pDTO in parentDTOs {
        let items = task.extract(pDTO)
        let pid = extractParentId(pDTO)
        grouped[pid, default: []] += items
        allChildIds.formUnion(items.map { $0.id })
    }

    // 2) Get existed children
    let existingById: [ChildModel.RemoteID: ChildModel] = try {
        guard !allChildIds.isEmpty else { return [:] }
        let existing = try task.fetchExistingByIds(allChildIds, context)
        return Dictionary(uniqueKeysWithValues: existing.map { ($0.remoteId, $0) })
    }()

    // 3) Upsert + reconcile per parent
    for (pid, childDTOs) in grouped {
        guard let parent = parentById[pid] else { continue }

        var touched = Set<ChildModel.RemoteID>()

        for dto in childDTOs {
            let cid = dto.id
            if let found = existingById[cid] {
                if found.updatedAt < dto.updatedAt {
                    if let deletable = found as? (any SoftDeletable & AnyObject), deletable.deletedAt != nil {
                        deletable.deletedAt = nil
                    }
                    found.apply(dto)
                    found.updatedAt = dto.updatedAt
                    task.applyExtra(found, dto, parent, context)
                }
                touched.insert(cid)
            } else {
                let newModel = ChildModel(dto: dto)
                newModel.remoteId = cid
                newModel.updatedAt = dto.updatedAt
                task.applyExtra(newModel, dto, parent, context)
                context.insert(newModel)
                touched.insert(cid)
            }
        }

        // Remove or soft-delete missing children from the current parent scope
        switch task.deletionPolicy {
        case .none:
            break
        case .hardDeleteMissing:
            do {
                guard !task.requireNonEmptyChildSlice || !childDTOs.isEmpty else { continue }
                let scope = try task.fetchScopeForDeletion(parent, context)
                let toDelete = scope.filter { !touched.contains($0.remoteId) }
                toDelete.forEach { context.delete($0) }
            }
        case .softDeleteMissing:
            do {
                guard !task.requireNonEmptyChildSlice || !childDTOs.isEmpty else { continue }
                let scope = try task.fetchScopeForDeletion(parent, context)
                let toReconcile = scope.filter { !touched.contains($0.remoteId) }
                for item in toReconcile {
                    if let deletable = item as? (any SoftDeletable & AnyObject), deletable.deletedAt == nil {
                        deletable.deletedAt = Date()
                    } else {
                        context.delete(item)
                    }
                }
            }
        }
    }
}
