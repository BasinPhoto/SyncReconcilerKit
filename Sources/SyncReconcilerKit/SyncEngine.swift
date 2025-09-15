//
//  SyncEngine.swift
//  SyncReconcilerKit
//
//  Created by Sergey Basin on 15.09.2025.
//

import Foundation
import SwiftData

@ModelActor
public actor SyncEngine {
    
    public struct SyncSummary<RID: Hashable & Sendable>: Sendable {
        public let touchedIDs: [RID]
        public let inserted: Int
        public let updated: Int
        public let deleted: Int
    }
    
    /// Convenience overload for models that conform to `SyncableModel`.
    /// Uses `PM.DTO` as the parent DTO type, and automatically wires `init(dto:)` and `apply(_:)`.
    @discardableResult
    public func upsertCollection<PM>(
        from parentDTOs: [PM.DTO],
        model: PM.Type = PM.self,
        fetchExistingByIds: @Sendable (_ ids: Set<PM.RemoteID>, _ context: ModelContext) throws -> [PM],
        deletionPolicy: DeletionPolicy = .none,
        childTasks: [AnyChildTask<PM.DTO, PM>] = [],
        extractParentIdForChildren: @Sendable (PM.DTO) -> PM.RemoteID,
        fetchParentScopeForDeletion: (@Sendable (ModelContext) throws -> [PM])? = nil,
        requireNonEmptyFullSlice: Bool = false
    ) throws -> SyncSummary<PM.RemoteID> where PM: SyncableModel {
        try upsertCollection(
            from: parentDTOs,
            model: PM.self,
            id: \.id,
            updatedAt: \.updatedAt,
            fetchExistingByIds: fetchExistingByIds,
            deletionPolicy: deletionPolicy,
            apply: { (model: PM, dto: PM.DTO, _ ctx: ModelContext) in
                model.apply(dto)
            },
            makeNew: { (dto: PM.DTO, _ ctx: ModelContext) in
                PM(dto: dto)
            },
            childTasks: childTasks,
            extractParentIdForChildren: extractParentIdForChildren,
            fetchParentScopeForDeletion: fetchParentScopeForDeletion,
            requireNonEmptyFullSlice: requireNonEmptyFullSlice
        )
    }
    
    @discardableResult
    public func upsertCollection<PDTO, PM>(
        from parentDTOs: [PDTO],
        model: PM.Type,
        id: KeyPath<PDTO, PM.RemoteID>,
        updatedAt: KeyPath<PDTO, Date>,
        fetchExistingByIds: @Sendable (_ ids: Set<PM.RemoteID>, _ context: ModelContext) throws -> [PM],
        deletionPolicy: DeletionPolicy = .none,
        apply: @Sendable (_ model: PM, _ dto: PDTO, _ context: ModelContext) -> Void,
        makeNew: @Sendable (_ dto: PDTO, _ context: ModelContext) -> PM,
        childTasks: [AnyChildTask<PDTO, PM>] = [],
        extractParentIdForChildren: @Sendable (PDTO) -> PM.RemoteID,
        fetchParentScopeForDeletion: (@Sendable (ModelContext) throws -> [PM])? = nil,
        requireNonEmptyFullSlice: Bool = false
    ) throws -> SyncSummary<PM.RemoteID>
    where
    PDTO: Sendable,
    PM: PersistentModel & RemoteStampedModel,
    PM.RemoteID: Hashable & Sendable
    {
        let ctx = ModelContext(modelContainer)
        var touchedIDs: [PM.RemoteID] = []
        var inserted = 0, updated = 0, deleted = 0
        
        try ctx.transaction {
            // 1) Indexes
            let ids = Set(parentDTOs.map { $0[keyPath: id] })
            
            // 2) Existing
            let existing = try fetchExistingByIds(ids, ctx)
            var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.remoteId, $0) })
            
            // 3) Upsert parents
            var touched = Set<PM.RemoteID>()
            var parents: [PM] = []
            parents.reserveCapacity(parentDTOs.count)
            
            for dto in parentDTOs {
                let pid = dto[keyPath: id]
                let pUpdated = dto[keyPath: updatedAt]
                
                let obj: PM
                if let found = byId[pid] {
                    if found.updatedAt < pUpdated {
                        if let deletable = found as? (any SoftDeletable & AnyObject), deletable.deletedAt != nil {
                            deletable.deletedAt = nil
                        }
                        apply(found, dto, ctx)
                        found.updatedAt = pUpdated
                        updated += 1
                    }
                    obj = found
                } else {
                    obj = makeNew(dto, ctx)
                    obj.remoteId = pid
                    obj.updatedAt = pUpdated
                    ctx.insert(obj)
                    byId[pid] = obj
                    inserted += 1
                }
                
                touched.insert(pid)
                touchedIDs.append(pid)
                parents.append(obj)
            }
            
            // 4) Delete/soft-delete missing (full slice)
            // Optionally scope the parent deletion set and protect against accidental mass-deletes
            switch deletionPolicy {
            case .none:
                break
            case .hardDeleteMissing, .softDeleteMissing:
                // If required, do not perform deletion when server returned an empty slice
                guard !requireNonEmptyFullSlice || !parentDTOs.isEmpty else { /* skip deletion */ return }
                
                // Use caller-provided scope if available; otherwise reconcile against the entire parent set
                let fullScope: [PM] = try (fetchParentScopeForDeletion?(ctx) ?? ctx.fetch(FetchDescriptor<PM>()))
                let toReconcile = fullScope.filter { !touched.contains($0.remoteId) }
                
                if deletionPolicy == .hardDeleteMissing {
                    toReconcile.forEach { ctx.delete($0) }
                } else {
                    // Soft-delete when the model supports it; otherwise fallback to hard delete (safe default)
                    for item in toReconcile {
                        if let deletable = item as? (any SoftDeletable & AnyObject), deletable.deletedAt == nil {
                            deletable.deletedAt = Date()
                        } else {
                            ctx.delete(item)
                        }
                    }
                }
                deleted += toReconcile.count
            }
            
            // 5) Children
            let parentById = Dictionary(uniqueKeysWithValues: parents.map { ($0.remoteId, $0) })
            for task in childTasks {
                try task.run(
                    parentDTOs: parentDTOs,
                    parentById: parentById,
                    extractParentId: extractParentIdForChildren,
                    in: ctx
                )
            }
        }
        
        return .init(touchedIDs: touchedIDs, inserted: inserted, updated: updated, deleted: deleted)
    }
}
