use kaname_core::{
    open_workflow_library,
    workflow_library::{
        WORKFLOW_LIBRARY_SCHEMA_VERSION, WorkflowLibraryError, WorkflowLibraryMigrationFault,
        WorkflowLibraryStore,
    },
};
use rusqlite::{Connection, params};
use std::{collections::BTreeSet, fs};
use tempfile::tempdir;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const EXPECTED_TABLES: [&str; 7] = [
    "activation_aliases",
    "import_receipts",
    "package_registrations",
    "workflow_drafts",
    "workflow_identities",
    "workflow_library_migrations",
    "workflow_revisions",
];

#[test]
fn empty_install_creates_private_complete_and_rerunnable_schema() {
    let directory = tempdir().unwrap();
    let workflows = directory.path().join("Workflows");
    let database = workflows.join("workflow-library.sqlite");

    let store = open_workflow_library(directory.path()).unwrap();
    assert_eq!(
        store.schema_version().unwrap(),
        WORKFLOW_LIBRARY_SCHEMA_VERSION
    );
    assert_eq!(store.database_path(), Some(database.as_path()));
    assert_eq!(
        store.table_names().unwrap(),
        EXPECTED_TABLES
            .into_iter()
            .map(str::to_owned)
            .collect::<BTreeSet<_>>()
    );
    store.integrity_check().unwrap();
    drop(store);

    #[cfg(unix)]
    {
        assert_eq!(
            fs::metadata(&workflows).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&database).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    let reopened = WorkflowLibraryStore::open(&database).unwrap();
    reopened.integrity_check().unwrap();
    drop(reopened);
    let connection = Connection::open(&database).unwrap();
    let migration_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM workflow_library_migrations",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(migration_count, 1);
}

#[test]
fn forward_migration_preserves_a_valid_version_zero_database() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("workflow-library.sqlite");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE preflight_marker (value TEXT NOT NULL) STRICT;
             INSERT INTO preflight_marker(value) VALUES ('preserve-me');
             PRAGMA user_version = 0;",
        )
        .unwrap();
    drop(connection);

    let store = WorkflowLibraryStore::open(&database).unwrap();
    assert_eq!(
        store.schema_version().unwrap(),
        WORKFLOW_LIBRARY_SCHEMA_VERSION
    );
    store.integrity_check().unwrap();
    drop(store);

    let connection = Connection::open(&database).unwrap();
    let marker: String = connection
        .query_row("SELECT value FROM preflight_marker", [], |row| row.get(0))
        .unwrap();
    assert_eq!(marker, "preserve-me");
}

#[test]
fn revision_references_cannot_cross_workflow_boundaries() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("workflow-library.sqlite");
    drop(WorkflowLibraryStore::open(&database).unwrap());

    let connection = Connection::open(&database).unwrap();
    connection
        .pragma_update(None, "foreign_keys", "ON")
        .unwrap();
    for (workflow_id, package_id) in [
        ("workflow-one", "dev.kaname.one"),
        ("workflow-two", "dev.kaname.two"),
    ] {
        connection
            .execute(
                "INSERT INTO workflow_identities
                   (workflow_id, package_id, name, summary, created_at_unix_millis, updated_at_unix_millis)
                 VALUES (?1, ?2, ?1, '', 1, 1)",
                params![workflow_id, package_id],
            )
            .unwrap();
    }
    let digest = "0".repeat(64);
    connection
        .execute(
            "INSERT INTO workflow_revisions
               (revision_id, workflow_id, revision_number, bundle_relative_path,
                definition_digest, layout_digest, schema_bundle_digest,
                dependency_lock_digest, validation_digest, package_digest,
                format_version, created_at_unix_millis)
             VALUES ('revision-one', 'workflow-one', 1, 'Revisions/workflow-one/1-revision-one',
                     ?1, ?1, ?1, ?1, ?1, ?1, 1, 1)",
            [&digest],
        )
        .unwrap();

    assert!(
        connection
            .execute(
                "INSERT INTO activation_aliases
               (alias_id, workflow_id, alias_key, revision_id, updated_at_unix_millis)
             VALUES ('bad-alias', 'workflow-two', 'active', 'revision-one', 1)",
                [],
            )
            .is_err()
    );
    assert!(connection
        .execute(
            "INSERT INTO workflow_drafts
               (workflow_id, base_revision_id, draft_relative_path, generation, updated_at_unix_millis)
             VALUES ('workflow-two', 'revision-one', 'Drafts/workflow-two', 1, 1)",
            [],
        )
        .is_err());
}

#[test]
fn interrupted_migration_rolls_back_and_retries_as_one_complete_schema() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("workflow-library.sqlite");

    let interrupted = WorkflowLibraryStore::open_with_migration_fault_for_test(
        &database,
        WorkflowLibraryMigrationFault::AfterSchemaStatements,
    );
    assert!(matches!(
        interrupted,
        Err(WorkflowLibraryError::InjectedMigrationInterruption)
    ));

    assert_eq!(database_shape(&database), (0, BTreeSet::new()));

    let recovered = WorkflowLibraryStore::open(&database).unwrap();
    recovered.integrity_check().unwrap();
    assert_eq!(
        recovered.schema_version().unwrap(),
        WORKFLOW_LIBRARY_SCHEMA_VERSION
    );
}

#[test]
fn migration_schema_conflict_rolls_back_every_prior_statement() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("workflow-library.sqlite");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE workflow_identities (legacy_value TEXT NOT NULL);
             INSERT INTO workflow_identities(legacy_value) VALUES ('original');
             PRAGMA user_version = 0;",
        )
        .unwrap();
    drop(connection);

    assert!(matches!(
        WorkflowLibraryStore::open(&database),
        Err(WorkflowLibraryError::Database(_))
    ));

    let (version, tables) = database_shape(&database);
    assert_eq!(
        stored_text(&database, "SELECT legacy_value FROM workflow_identities"),
        "original"
    );
    assert_eq!(version, 0);
    assert!(!tables.contains("workflow_library_migrations"));
}

#[test]
fn corrupt_database_fails_closed_without_replacing_source_bytes() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("workflow-library.sqlite");
    let corrupt = b"not a sqlite workflow library".to_vec();
    fs::write(&database, &corrupt).unwrap();

    assert!(matches!(
        WorkflowLibraryStore::open(&database),
        Err(WorkflowLibraryError::CorruptDatabase)
    ));
    assert_eq!(fs::read(&database).unwrap(), corrupt);
    assert!(!database.with_extension("sqlite-wal").exists());
    assert!(!database.with_extension("sqlite-shm").exists());
}

#[test]
fn newer_schema_is_rejected_without_downgrade_or_database_writes() {
    let directory = tempdir().unwrap();
    let database = directory.path().join("workflow-library.sqlite");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE future_marker (value TEXT NOT NULL) STRICT;
             INSERT INTO future_marker(value) VALUES ('future');
             PRAGMA user_version = 2;",
        )
        .unwrap();
    drop(connection);
    let before = fs::read(&database).unwrap();

    assert!(matches!(
        WorkflowLibraryStore::open(&database),
        Err(WorkflowLibraryError::UnsupportedNewerSchema {
            found: 2,
            supported: WORKFLOW_LIBRARY_SCHEMA_VERSION,
        })
    ));
    assert_eq!(fs::read(&database).unwrap(), before);

    let (version, _) = database_shape(&database);
    assert_eq!(version, 2);
    assert_eq!(
        stored_text(&database, "SELECT value FROM future_marker"),
        "future"
    );
}

fn database_shape(path: &std::path::Path) -> (i64, BTreeSet<String>) {
    let connection = Connection::open(path).unwrap();
    let version = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    let mut statement = connection
        .prepare(
            "SELECT name FROM sqlite_schema
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name",
        )
        .unwrap();
    let names = statement
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<BTreeSet<_>>>()
        .unwrap();
    (version, names)
}

fn stored_text(path: &std::path::Path, query: &str) -> String {
    Connection::open(path)
        .unwrap()
        .query_row(query, [], |row| row.get(0))
        .unwrap()
}
