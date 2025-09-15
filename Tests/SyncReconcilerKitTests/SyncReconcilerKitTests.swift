import Foundation
import SwiftData
import Testing
@testable import SyncReconcilerKit

// MARK: - Test DTOs
struct StudioDTO: RemoteStampedDTO, Sendable, Equatable {
    typealias ID = String
    let id: String
    let name: String
    let updatedAt: Date
    let rooms: [RoomDTO]
    let equipments: [EquipmentDTO]
}

struct RoomDTO: RemoteStampedDTO, Sendable, Equatable {
    typealias ID = String
    let id: String
    let title: String
    let updatedAt: Date
}

struct EquipmentDTO: RemoteStampedDTO, Sendable, Equatable {
    typealias ID = String
    let id: String
    let name: String
    let updatedAt: Date
}

// MARK: - Test Models
@Model
final class Studio: SyncableModel, SoftDeletable {
    @Attribute(.unique) var remoteId: String
    var name: String
    var updatedAt: Date
    var deletedAt: Date?
    @Relationship(deleteRule: .cascade) var rooms: [Room] = []
    @Relationship(deleteRule: .cascade) var equipments: [Equipment] = []

    typealias DTO = StudioDTO
    required convenience init(dto: DTO) {
        self.init(remoteId: dto.id, name: dto.name, updatedAt: dto.updatedAt)
    }
    init(remoteId: String, name: String, updatedAt: Date) {
        self.remoteId = remoteId
        self.name = name
        self.updatedAt = updatedAt
    }
    func apply(_ dto: DTO) { self.name = dto.name }
}

@Model
final class Room: SyncableModel, SoftDeletable {
    @Attribute(.unique) var remoteId: String
    var title: String
    var updatedAt: Date
    var deletedAt: Date?
    @Relationship(inverse: \Studio.rooms) var studio: Studio?
    
    typealias DTO = RoomDTO
    required convenience init(dto: DTO) {
        self.init(remoteId: dto.id, title: dto.title, updatedAt: dto.updatedAt, studio: nil)
    }
    init(remoteId: String, title: String, updatedAt: Date, studio: Studio?) {
        self.remoteId = remoteId
        self.title = title
        self.updatedAt = updatedAt
        self.studio = studio
    }
    func apply(_ dto: DTO) { self.title = dto.title }
}

@Model
final class Equipment: SyncableModel, SoftDeletable {
    @Attribute(.unique) var remoteId: String
    var name: String
    var updatedAt: Date
    var deletedAt: Date?
    @Relationship(inverse: \Studio.equipments) var studio: Studio?
    
    typealias DTO = EquipmentDTO
    required convenience init(dto: DTO) {
        self.init(remoteId: dto.id, name: dto.name, updatedAt: dto.updatedAt, studio: nil)
    }
    init(remoteId: String, name: String, updatedAt: Date, studio: Studio?) {
        self.remoteId = remoteId
        self.name = name
        self.updatedAt = updatedAt
        self.studio = studio
    }
    func apply(_ dto: DTO) { self.name = dto.name }
}

// MARK: - Helpers
@Suite struct SyncEngineTests {
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([Studio.self, Room.self, Equipment.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private static func engine() throws -> (SyncEngine, ModelContainer) {
        let container = try makeContainer()
        let engine = SyncEngine(modelContainer: container)
        return (engine, container)
    }

    private static func fetchAll<T: PersistentModel>(_ type: T.Type, _ ctx: ModelContext) throws -> [T] {
        try ctx.fetch(FetchDescriptor<T>())
    }

    // Common fetchers used by child tasks
    private static func studiosByIds(_ ids: Set<String>, _ ctx: ModelContext) throws -> [Studio] {
        let predicate = #Predicate<Studio> { ids.contains($0.remoteId) }
        return try ctx.fetch(FetchDescriptor(predicate: predicate))
    }
    private static func roomsByIds(_ ids: Set<String>, _ ctx: ModelContext) throws -> [Room] {
        let predicate = #Predicate<Room> { ids.contains($0.remoteId) }
        return try ctx.fetch(FetchDescriptor(predicate: predicate))
    }
    private static func equipmentsByIds(_ ids: Set<String>, _ ctx: ModelContext) throws -> [Equipment] {
        let predicate = #Predicate<Equipment> { ids.contains($0.remoteId) }
        return try ctx.fetch(FetchDescriptor(predicate: predicate))
    }

    // MARK: - Tests

    @Test func insertUpdateDelete_ParentFullSlice() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        let first = [
            StudioDTO(id: "s1", name: "Alpha", updatedAt: now, rooms: [], equipments: []),
            StudioDTO(id: "s2", name: "Beta",  updatedAt: now, rooms: [], equipments: [])
        ]

        // Full slice insert
        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .hardDeleteMissing,
            childTasks: [],
            extractParentIdForChildren: \.id
        )
        
        // Expect 2 studios exist
        let ctx = ModelContext(container)
        let all1: [Studio] = try Self.fetchAll(Studio.self, ctx)
        #expect(all1.count == 2)
        #expect(Set(all1.map { $0.remoteId }) == ["s1", "s2"])

        // Update s1 (newer updatedAt), and drop s2 in payload -> should delete s2
        let later = now.addingTimeInterval(10)
        let second = [
            StudioDTO(id: "s1", name: "Alpha+", updatedAt: later, rooms: [], equipments: [])
        ]
        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .hardDeleteMissing,
            childTasks: [],
            extractParentIdForChildren: \.id
        )

        let all2: [Studio] = try Self.fetchAll(Studio.self, ctx)
        #expect(all2.count == 1)
        #expect(all2.first?.remoteId == "s1")
        #expect(all2.first?.name == "Alpha+")
    }

    @Test func noDeletion_WhenPolicyNone() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        let first = [
            StudioDTO(id: "s1", name: "Alpha", updatedAt: now, rooms: [], equipments: [])
        ]
        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [],
            extractParentIdForChildren: \.id
        )

        let second = [
            StudioDTO(id: "s2", name: "Beta", updatedAt: now.addingTimeInterval(5), rooms: [], equipments: [])
        ]
        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [],
            extractParentIdForChildren: \.id
        )

        // Both should coexist since we didn't hard-delete missing
        let ctx = ModelContext(container)
        let studios: [Studio] = try Self.fetchAll(Studio.self, ctx)
        #expect(studios.count == 2)
        #expect(Set(studios.map { $0.remoteId }) == ["s1", "s2"])
    }

    @Test func childrenSync_TwoCollections_WithDeletion() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        // Initial payload: one studio with one room and one equipment
        let first = [
            StudioDTO(
                id: "s1",
                name: "Alpha",
                updatedAt: now,
                rooms: [RoomDTO(id: "r1", title: "A", updatedAt: now)],
                equipments: [EquipmentDTO(id: "e1", name: "Light", updatedAt: now)]
            )
        ]

        let roomsTask = ChildSyncTask<StudioDTO, Studio, Room>(
            extract: { $0.rooms },
            fetchExistingByIds: Self.roomsByIds,
            fetchScopeForDeletion: { parent, ctx in
                let pid = parent.remoteId
                return try ctx.fetch(
                    FetchDescriptor(predicate: #Predicate<Room> { $0.studio?.remoteId == pid })
                )
            },
            applyExtra: { model, _, parent, _ in if model.studio !== parent { model.studio = parent } },
            deletionPolicy: .hardDeleteMissing
        )

        let equipmentsTask = ChildSyncTask<StudioDTO, Studio, Equipment>(
            extract: { $0.equipments },
            fetchExistingByIds: Self.equipmentsByIds,
            fetchScopeForDeletion: { parent, ctx in
                let pid = parent.remoteId
                return try ctx.fetch(
                    FetchDescriptor(predicate: #Predicate<Equipment> { $0.studio?.remoteId == pid })
                )
            },
            applyExtra: { model, _, parent, _ in if model.studio !== parent { model.studio = parent } },
            deletionPolicy: .hardDeleteMissing
        )

        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .hardDeleteMissing,
            childTasks: [
                AnyChildTask(roomsTask,      parentId: \.id),
                AnyChildTask(equipmentsTask, parentId: \.id)
            ],
            extractParentIdForChildren: \.id
        )

        let ctx = ModelContext(container)
        #expect((try Self.fetchAll(Room.self, ctx)).map(\.remoteId) == ["r1"])
        #expect((try Self.fetchAll(Equipment.self, ctx)).map(\.remoteId) == ["e1"])

        // Next payload drops the room, keeps equipment, and renames equipment
        let later = now.addingTimeInterval(10)
        let second = [
            StudioDTO(
                id: "s1",
                name: "Alpha",
                updatedAt: later,
                rooms: [],
                equipments: [EquipmentDTO(id: "e1", name: "Light+", updatedAt: later)]
            )
        ]

        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .hardDeleteMissing,
            childTasks: [
                AnyChildTask(roomsTask,      parentId: \.id),
                AnyChildTask(equipmentsTask, parentId: \.id)
            ],
            extractParentIdForChildren: \.id
        )

        let rooms = try Self.fetchAll(Room.self, ctx)
        let equipments = try Self.fetchAll(Equipment.self, ctx)
        #expect(rooms.isEmpty)
        #expect(equipments.count == 1)
        #expect(equipments.first?.name == "Light+")
        #expect(equipments.first?.studio?.remoteId == "s1")
    }

    @Test func updatedAt_GuardsAgainstOlderPayload() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        let first = [ StudioDTO(id: "s1", name: "Alpha", updatedAt: now, rooms: [], equipments: []) ]
        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .hardDeleteMissing,
            childTasks: [],
            extractParentIdForChildren: \.id
        )

        // Send an OLDER payload for s1 — name should NOT change
        let older = now.addingTimeInterval(-60)
        let second = [ StudioDTO(id: "s1", name: "ShouldNotWin", updatedAt: older, rooms: [], equipments: []) ]
        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .hardDeleteMissing,
            childTasks: [],
            extractParentIdForChildren: \.id
        )

        let ctx = ModelContext(container)
        let s1: [Studio] = try Self.fetchAll(Studio.self, ctx)
        #expect(s1.count == 1)
        #expect(s1.first?.name == "Alpha")
    }

    @Test func softDelete_Parent_FullSlice() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        // Insert two studios
        let first = [
            StudioDTO(id: "s1", name: "Alpha", updatedAt: now, rooms: [], equipments: []),
            StudioDTO(id: "s2", name: "Beta",  updatedAt: now, rooms: [], equipments: [])
        ]
        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [],
            extractParentIdForChildren: \.id
        )

        // Full slice now contains only s1 → s2 should be soft-deleted
        let later = now.addingTimeInterval(5)
        let second = [ StudioDTO(id: "s1", name: "Alpha", updatedAt: later, rooms: [], equipments: []) ]
        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .softDeleteMissing,
            childTasks: [],
            extractParentIdForChildren: \.id,
            requireNonEmptyFullSlice: true
        )

        let ctx = ModelContext(container)
        let studios = try ctx.fetch(FetchDescriptor<Studio>())
        let s1 = studios.first { $0.remoteId == "s1" }
        let s2 = studios.first { $0.remoteId == "s2" }
        #expect(s1?.deletedAt == nil)
        #expect(s2?.deletedAt != nil) // soft-deleted
    }

    @Test func softDelete_Children_Scoped() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        // Studio with two rooms initially
        let first = [
            StudioDTO(
                id: "s1",
                name: "Alpha",
                updatedAt: now,
                rooms: [
                    RoomDTO(id: "r1", title: "A", updatedAt: now),
                    RoomDTO(id: "r2", title: "B", updatedAt: now)
                ],
                equipments: []
            )
        ]

        let roomsTaskSoft = ChildSyncTask<StudioDTO, Studio, Room>(
            extract: { $0.rooms },
            fetchExistingByIds: Self.roomsByIds,
            fetchScopeForDeletion: { parent, ctx in
                let pid = parent.remoteId
                return try ctx.fetch(
                    FetchDescriptor(predicate: #Predicate<Room> { $0.studio?.remoteId == pid })
                )
            },
            applyExtra: { model, _, parent, _ in if model.studio !== parent { model.studio = parent } },
            deletionPolicy: .softDeleteMissing
        )

        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [ AnyChildTask(roomsTaskSoft, parentId: \.id) ],
            extractParentIdForChildren: \.id
        )

        // Second payload drops r2 → it should be soft-deleted
        let later = now.addingTimeInterval(10)
        let second = [
            StudioDTO(
                id: "s1",
                name: "Alpha",
                updatedAt: later,
                rooms: [ RoomDTO(id: "r1", title: "A+", updatedAt: later) ],
                equipments: []
            )
        ]

        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [ AnyChildTask(roomsTaskSoft, parentId: \.id) ],
            extractParentIdForChildren: \.id
        )

        let ctx = ModelContext(container)
        let allRooms = try ctx.fetch(FetchDescriptor<Room>())
        let r1 = allRooms.first { $0.remoteId == "r1" }
        let r2 = allRooms.first { $0.remoteId == "r2" }
        #expect(r1?.deletedAt == nil)
        #expect(r2?.deletedAt != nil)
    }

    @Test func softDelete_Reactivation_Parent() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        // Full slice with two parents
        let first = [
            StudioDTO(id: "s1", name: "Alpha", updatedAt: now, rooms: [], equipments: []),
            StudioDTO(id: "s2", name: "Beta",  updatedAt: now, rooms: [], equipments: [])
        ]
        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [],
            extractParentIdForChildren: \.id
        )

        // Next full slice contains only s1 → soft-delete s2
        let later = now.addingTimeInterval(5)
        let second = [ StudioDTO(id: "s1", name: "Alpha", updatedAt: later, rooms: [], equipments: []) ]
        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .softDeleteMissing,
            childTasks: [],
            extractParentIdForChildren: \.id,
            requireNonEmptyFullSlice: true
        )

        // Reactivation: server includes s2 again with newer updatedAt
        let later2 = later.addingTimeInterval(10)
        let third = [
            StudioDTO(id: "s1", name: "Alpha", updatedAt: later2, rooms: [], equipments: []),
            StudioDTO(id: "s2", name: "Beta+", updatedAt: later2, rooms: [], equipments: [])
        ]
        _ = try await engine.upsertCollection(
            from: third,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .softDeleteMissing,
            childTasks: [],
            extractParentIdForChildren: \.id,
            requireNonEmptyFullSlice: true
        )

        let ctx = ModelContext(container)
        let all: [Studio] = try Self.fetchAll(Studio.self, ctx)
        let s2 = all.first { $0.remoteId == "s2" }
        #expect(s2 != nil)
        #expect(s2?.deletedAt == nil) // reactivated
        #expect(s2?.name == "Beta+")
    }

    @Test func softDelete_Reactivation_Child() async throws {
        let (engine, container) = try Self.engine()
        let now = Date()

        // Initial payload: one studio with two rooms
        let first = [
            StudioDTO(
                id: "s1",
                name: "Alpha",
                updatedAt: now,
                rooms: [
                    RoomDTO(id: "r1", title: "A", updatedAt: now),
                    RoomDTO(id: "r2", title: "B", updatedAt: now)
                ],
                equipments: []
            )
        ]

        let roomsTaskSoft = ChildSyncTask<StudioDTO, Studio, Room>(
            extract: { $0.rooms },
            fetchExistingByIds: Self.roomsByIds,
            fetchScopeForDeletion: { parent, ctx in
                let pid = parent.remoteId
                return try ctx.fetch(
                    FetchDescriptor(predicate: #Predicate<Room> { $0.studio?.remoteId == pid })
                )
            },
            applyExtra: { model, _, parent, _ in if model.studio !== parent { model.studio = parent } },
            deletionPolicy: .softDeleteMissing
        )

        // Insert
        _ = try await engine.upsertCollection(
            from: first,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [ AnyChildTask(roomsTaskSoft, parentId: \.id) ],
            extractParentIdForChildren: \.id
        )

        // Second payload drops r2 → soft-delete it
        let later = now.addingTimeInterval(5)
        let second = [
            StudioDTO(
                id: "s1",
                name: "Alpha",
                updatedAt: later,
                rooms: [ RoomDTO(id: "r1", title: "A+", updatedAt: later) ],
                equipments: []
            )
        ]
        _ = try await engine.upsertCollection(
            from: second,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [ AnyChildTask(roomsTaskSoft, parentId: \.id) ],
            extractParentIdForChildren: \.id
        )

        // Third payload returns r2 with newer updatedAt → should reactivate
        let later2 = later.addingTimeInterval(10)
        let third = [
            StudioDTO(
                id: "s1",
                name: "Alpha",
                updatedAt: later2,
                rooms: [
                    RoomDTO(id: "r1", title: "A++", updatedAt: later2),
                    RoomDTO(id: "r2", title: "B+",  updatedAt: later2)
                ],
                equipments: []
            )
        ]
        _ = try await engine.upsertCollection(
            from: third,
            fetchExistingByIds: Self.studiosByIds,
            deletionPolicy: .none,
            childTasks: [ AnyChildTask(roomsTaskSoft, parentId: \.id) ],
            extractParentIdForChildren: \.id
        )

        let ctx = ModelContext(container)
        let rooms = try Self.fetchAll(Room.self, ctx)
        let r2 = rooms.first { $0.remoteId == "r2" }
        #expect(r2 != nil)
        #expect(r2?.deletedAt == nil)
        #expect(r2?.title == "B+")
    }
}
