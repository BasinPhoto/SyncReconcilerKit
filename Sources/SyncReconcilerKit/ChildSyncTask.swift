//
//  ChildSyncTask.swift
//  SyncReconcilerKit
//
//  Created by Sergey Basin on 15.09.2025.
//

import Foundation
import SwiftData

/// Sync task description children for concrete parent model
public struct ChildSyncTask<ParentDTO, ParentModel: PersistentModel, ChildModel> : Sendable
where
    ChildModel: PersistentModel & RemoteStampedModel & MergeAppliable & InitFromDTO,
    ChildModel.DTO: RemoteStampedDTO,
    ChildModel.DTO.ID == ChildModel.ID
{
    public typealias PDTO = ParentDTO
    public typealias PM = ParentModel
    public typealias CM = ChildModel
    public typealias CDTO = ChildModel.DTO

    /// Extract childred DTOs from parent DTO
    public let extract: @Sendable (PDTO) -> [CDTO]

    /// Get existed children by IDs set
    public let fetchExistingByIds: @Sendable (_ ids: Set<CM.ID>, _ context: ModelContext) throws -> [CM]

    /// Get children scope for deletion
    public let fetchScopeForDeletion: @Sendable (_ parent: PM, _ context: ModelContext) throws -> [CM]

    /// Extra task (set link to parrent)
    public let applyExtra: @Sendable (_ model: CM, _ dto: CDTO, _ parent: PM, _ context: ModelContext) -> Void

    /// Children delete policy
    public let deletionPolicy: DeletionPolicy

    public init(
        extract: @Sendable @escaping (PDTO) -> [CDTO],
        fetchExistingByIds: @Sendable @escaping (_ ids: Set<CM.ID>, _ context: ModelContext) throws -> [CM],
        fetchScopeForDeletion: @Sendable @escaping (_ parent: PM, _ context: ModelContext) throws -> [CM],
        applyExtra: @Sendable @escaping (_ model: CM, _ dto: CDTO, _ parent: PM, _ context: ModelContext) -> Void = { _,_,_,_ in },
        deletionPolicy: DeletionPolicy
    ) {
        self.extract = extract
        self.fetchExistingByIds = fetchExistingByIds
        self.fetchScopeForDeletion = fetchScopeForDeletion
        self.applyExtra = applyExtra
        self.deletionPolicy = deletionPolicy
    }
}

/// Type-erasure to keep different children types in one array
public struct AnyChildTask<ParentDTO, ParentModel: PersistentModel & RemoteStampedModel>: Sendable {
    private let _run: @Sendable (_ parentDTOs: [ParentDTO],
                       _ parentById: [ParentModel.ID: ParentModel],
                       _ extractParentId: @Sendable (ParentDTO) -> ParentModel.ID,
                       _ context: ModelContext) throws -> Void

    public init<ChildModel>(
        _ base: ChildSyncTask<ParentDTO, ParentModel, ChildModel>,
        parentId: @Sendable @escaping (ParentDTO) -> ParentModel.ID
    ) where
        ChildModel: PersistentModel & RemoteStampedModel & MergeAppliable & InitFromDTO,
        ChildModel.DTO: RemoteStampedDTO,
        ChildModel.DTO.ID == ChildModel.ID
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
                    parentById: [ParentModel.ID: ParentModel],
                    extractParentId: @Sendable (ParentDTO) -> ParentModel.ID,
                    in context: ModelContext) throws {
        try _run(parentDTOs, parentById, extractParentId, context)
    }
}

private func runConcrete<ParentDTO, ParentModel, ChildModel>(
    _ task: ChildSyncTask<ParentDTO, ParentModel, ChildModel>,
    parentDTOs: [ParentDTO],
    parentById: [ParentModel.ID: ParentModel],
    extractParentId: @Sendable (ParentDTO) -> ParentModel.ID,
    context: ModelContext
) throws
where
    ParentModel: PersistentModel & RemoteStampedModel,
    ChildModel: PersistentModel & RemoteStampedModel & MergeAppliable & InitFromDTO,
    ChildModel.DTO: RemoteStampedDTO,
    ChildModel.DTO.ID == ChildModel.ID
{
    // 1) Group children by parrent
    var grouped: [ParentModel.ID: [ChildModel.DTO]] = [:]
    var allChildIds = Set<ChildModel.ID>()

    for pDTO in parentDTOs {
        let items = task.extract(pDTO)
        let pid = extractParentId(pDTO)
        grouped[pid, default: []] += items
        allChildIds.formUnion(items.map { $0.id })
    }

    // 2) Get existed children
    let existingById: [ChildModel.ID: ChildModel] = try {
        guard !allChildIds.isEmpty else { return [:] }
        let existing = try task.fetchExistingByIds(allChildIds, context)
        return Dictionary(uniqueKeysWithValues: existing.map { ($0.remoteId, $0) })
    }()

    // 3) Upsert + reconcile per parent
    for (pid, childDTOs) in grouped {
        guard let parent = parentById[pid] else { continue }

        var touched = Set<ChildModel.ID>()

        for dto in childDTOs {
            let cid = dto.id
            if let found = existingById[cid] {
                if found.updatedAt < dto.updatedAt {
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

        // Remove not presented children in current parent scope
        if task.deletionPolicy == .hardDeleteMissing {
            let scope = try task.fetchScopeForDeletion(parent, context)
            let toDelete = scope.filter { !touched.contains($0.remoteId) }
            toDelete.forEach { context.delete($0) }
        }
    }
}
