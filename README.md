# SyncReconcilerKit

**SyncReconcilerKit** is a Swift package that provides a generic, testable, and concurrency-safe synchronization engine for SwiftData. It helps reconcile server-based DTOs with local models in an **upsert + reconcile** pattern:

- **Insert** new entities if they don’t exist.
- **Update** existing ones if the server’s version is newer.
- **Delete** local entities that are missing from the server (optional, for full-slice syncs).
- **Synchronize children** recursively with flexible tasks.

This pattern makes it easy to build **server-driven, offline-capable apps** without duplicating boilerplate merge logic.

---

## Features

- 🔄 Generic **upsert engine** for any SwiftData model.
- 🧩 Reusable **child sync tasks** (handle multiple child collections per parent).
- 🛡️ Concurrency-safe with Swift 6.2 strict isolation (`@ModelActor`, `Sendable`).
- 🧪 Fully testable with in-memory containers and [Swift Testing](https://github.com/apple/swift-testing).
- ⚙️ Configurable **deletion policies** (`.none`, `.hardDeleteMissing`).
- 📦 No external dependencies — just SwiftData and Swift standard libraries.

---

## Installation

Add the package to your Xcode project:

1. In Xcode, go to **File → Add Packages…**
2. Enter the package URL of your repository (e.g., `https://github.com/BasinPhoto/SyncReconcilerKit.git`)
3. Add `SyncReconcilerKit` to your app and test targets.

---

## Usage

### 1. Define DTOs

```swift
struct StudioDTO: RemoteStampedDTO, Sendable {
    typealias ID = String
    let id: String
    let name: String
    let updatedAt: Date
    let rooms: [RoomDTO]
}

struct RoomDTO: RemoteStampedDTO, Sendable {
    typealias ID = String
    let id: String
    let title: String
    let updatedAt: Date
}

### 2. Define Models

```swift
@Model
final class Studio: Identifiable, RemoteStampedModel, MergeAppliable, InitFromDTO {
    @Attribute(.unique) var remoteId: String
    var name: String
    var updatedAt: Date
    @Relationship(deleteRule: .cascade) var rooms: [Room] = []
    
    var id: String {
        self.remoteId
    }

    required convenience init(dto: StudioDTO) {
        self.init(remoteId: dto.id, name: dto.name, updatedAt: dto.updatedAt)
    }

    init(remoteId: String, name: String, updatedAt: Date) {
        self.remoteId = remoteId
        self.name = name
        self.updatedAt = updatedAt
    }

    func apply(_ dto: StudioDTO) {
        self.name = dto.name
    }
}
```
### 3. Create a Sync Task for Children

```swift
let roomsTask = ChildSyncTask<StudioDTO, Studio, Room>(
    extract: { $0.rooms },
    fetchExistingByIds: { ids, ctx in
        try ctx.fetch(FetchDescriptor(predicate: #Predicate<Room> { ids.contains($0.remoteId) }))
    },
    fetchScopeForDeletion: { parent, ctx in
        let pid = parent.remoteId
        return try ctx.fetch(FetchDescriptor(predicate: #Predicate<Room> { $0.studio?.remoteId == pid }))
    },
    applyExtra: { model, _, parent, _ in
        if model.studio !== parent { model.studio = parent }
    },
    deletionPolicy: .hardDeleteMissing
)
```
### 4. Run sync

```swift
let dtos: [StudioDTO] = try await api.fetchStudios()

let engine = SyncEngine(modelContainer: container)

try await engine.upsertCollection(
    from: dtos,
    model: Studio.self,
    id: \.id,
    updatedAt: \.updatedAt,
    fetchExistingByIds: { ids, ctx in
        try ctx.fetch(FetchDescriptor(predicate: #Predicate<Studio> { ids.contains($0.remoteId) }))
    },
    deletionPolicy: .hardDeleteMissing,
    apply: { model, dto, _ in model.apply(dto) },
    makeNew: { dto, _ in Studio(dto: dto) },
    childTasks: [AnyChildTask(roomsTask, parentId: \.id)],
    extractParentIdForChildren: \.id
)
```
## Testing

This package is fully covered by Swift Testing.

## Roadmap

    •    ✅ Generic parent/child sync
    •    ✅ Swift Testing suite
    •    🔜 Support for soft-delete strategies
    •    🔜 Built-in utilities for fetchByIds and scoping
    
## License

MIT License. See LICENSE for details.
