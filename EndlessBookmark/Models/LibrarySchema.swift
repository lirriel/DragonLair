import SwiftData

/// Versions of the data model. SwiftData migrates added fields that have a default value by
/// itself. A rename, a type change or a removed field needs a new version here plus a migration
/// stage, or libraries saved with the old model fail to open.
enum LibrarySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Bookmark.self, ScannedImage.self] }
}

enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

extension ModelContainer {
    /// The app's library, in the default store (the App Group container).
    static func library() throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: LibrarySchemaV1.self), migrationPlan: LibraryMigrationPlan.self)
    }
}
