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

    public struct SyncSummary<ID: Hashable & Sendable>: Sendable {
        public let touchedIDs: [ID]
        public let inserted: Int
        public let updated: Int
        public let deleted: Int
    }

    @discardableResult
    public func upsertCollection<PDTO, PM>(
        from parentDTOs: [PDTO],
        model: PM.Type,
        id: KeyPath<PDTO, PM.ID>,
        updatedAt: KeyPath<PDTO, Date>,
        fetchExistingByIds: @Sendable (_ ids: Set<PM.ID>, _ context: ModelContext) throws -> [PM],
        deletionPolicy: DeletionPolicy = .none,
        apply: @Sendable (_ model: PM, _ dto: PDTO, _ context: ModelContext) -> Void,
        makeNew: @Sendable (_ dto: PDTO, _ context: ModelContext) -> PM,
        childTasks: [AnyChildTask<PDTO, PM>] = [],
        extractParentIdForChildren: @Sendable (PDTO) -> PM.ID
    ) throws -> SyncSummary<PM.ID>
    where
        PDTO: Sendable,
        PM: PersistentModel & RemoteStampedModel,
        PM.ID: Hashable & Sendable
    {
        let ctx = ModelContext(modelContainer)
        var touchedIDs: [PM.ID] = []
        var inserted = 0, updated = 0, deleted = 0

        try ctx.transaction {
            // 1) Indexes
            let ids = Set(parentDTOs.map { $0[keyPath: id] })

            // 2) Existing
            let existing = try fetchExistingByIds(ids, ctx)
            var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.remoteId, $0) })

            // 3) Upsert parents
            var touched = Set<PM.ID>()
            var parents: [PM] = []
            parents.reserveCapacity(parentDTOs.count)

            for dto in parentDTOs {
                let pid = dto[keyPath: id]
                let pUpdated = dto[keyPath: updatedAt]

                let obj: PM
                if let found = byId[pid] {
                    if found.updatedAt < pUpdated {
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

            // 4) Delete missing (full slice)
            // IMPORTANT: we must compare against the FULL parent scope, not only those whose IDs were in the incoming payload.
            if deletionPolicy == .hardDeleteMissing {
                // Fetch the entire parent scope for reconciliation (no predicate). If your app needs a narrower scope,
                // provide a filtered fetch at the call site (e.g., by tenant/account) by moving this into a parameter.
                let fullScope: [PM] = try ctx.fetch(FetchDescriptor<PM>())
                let toDelete = fullScope.filter { !touched.contains($0.remoteId) }
                toDelete.forEach { ctx.delete($0) }
                deleted += toDelete.count
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

        // Сохранение один раз — уже внутри transaction происходит commit,
        // но если используешь без transaction, оставь try ctx.save()
        // Здесь ctx.transaction сам коммитит при отсутствии throw.

        return .init(touchedIDs: touchedIDs, inserted: inserted, updated: updated, deleted: deleted)
    }
}
