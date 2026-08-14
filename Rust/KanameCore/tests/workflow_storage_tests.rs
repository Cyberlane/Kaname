use kaname_core::{
    open_workflow_object_store, open_workflow_scoped_storage,
    workflow_object_store::{WorkflowObjectStoreQuota, WorkflowObjectStoreUsage},
    workflow_storage::{
        WorkflowStorageAccessContext, WorkflowStorageError, WorkflowStorageNamespace,
        WorkflowStorageNamespaceQuota, WorkflowStorageScopeKind, WorkflowStorageValueInput,
        WorkflowStorageWriteRequest,
    },
};
use sha2::{Digest, Sha256};
use tempfile::tempdir;

fn object_quota() -> WorkflowObjectStoreQuota {
    WorkflowObjectStoreQuota {
        maximum_object_bytes: 8 * 1024 * 1024,
        maximum_total_bytes: 32 * 1024 * 1024,
        maximum_object_count: 100,
    }
}

fn namespace_quota() -> WorkflowStorageNamespaceQuota {
    WorkflowStorageNamespaceQuota {
        maximum_item_count: 100,
        maximum_total_bytes: 16 * 1024 * 1024,
        maximum_value_bytes: 8 * 1024 * 1024,
    }
}

fn namespace(
    kind: WorkflowStorageScopeKind,
    owner_id: &str,
    installation_id: Option<&str>,
) -> WorkflowStorageNamespace {
    WorkflowStorageNamespace {
        kind,
        owner_id: owner_id.into(),
        installation_id: installation_id.map(str::to_owned),
    }
}

fn access(
    run_id: Option<&str>,
    case_id: Option<&str>,
    installation_id: &str,
    accounts: &[&str],
) -> WorkflowStorageAccessContext {
    WorkflowStorageAccessContext {
        run_id: run_id.map(str::to_owned),
        case_id: case_id.map(str::to_owned),
        installation_id: installation_id.into(),
        account_binding_ids: accounts.iter().map(|value| (*value).to_owned()).collect(),
    }
}

#[derive(Clone, Copy)]
struct WriteFixture<'a> {
    command: &'a str,
    entry: &'a str,
    version: &'a str,
    key: &'a str,
}

const fn write_fixture<'a>(
    command: &'a str,
    entry: &'a str,
    version: &'a str,
    key: &'a str,
) -> WriteFixture<'a> {
    WriteFixture {
        command,
        entry,
        version,
        key,
    }
}

fn inline_request(
    fixture: WriteFixture<'_>,
    access: WorkflowStorageAccessContext,
    namespace: WorkflowStorageNamespace,
    expected_revision: u64,
    bytes: &[u8],
    timestamp: i64,
) -> WorkflowStorageWriteRequest {
    WorkflowStorageWriteRequest {
        command_id: fixture.command.into(),
        access,
        namespace,
        entry_id: fixture.entry.into(),
        version_id: fixture.version.into(),
        reference_id: None,
        logical_key: fixture.key.into(),
        expected_revision,
        schema_ref: Some("kaname://schemas/example-value-v1".into()),
        media_type: "application/json".into(),
        classification: "private".into(),
        purpose: "value".into(),
        value: WorkflowStorageValueInput::InlineCanonicalJson {
            bytes: bytes.to_vec(),
        },
        created_by_attempt_id: format!("attempt-{}", fixture.version),
        created_at_unix_millis: timestamp,
    }
}

fn object_request(
    fixture: WriteFixture<'_>,
    access: WorkflowStorageAccessContext,
    namespace: WorkflowStorageNamespace,
    reference: &str,
    digest: &str,
    byte_count: u64,
) -> WorkflowStorageWriteRequest {
    WorkflowStorageWriteRequest {
        command_id: fixture.command.into(),
        access,
        namespace,
        entry_id: fixture.entry.into(),
        version_id: fixture.version.into(),
        reference_id: Some(reference.into()),
        logical_key: fixture.key.into(),
        expected_revision: 0,
        schema_ref: None,
        media_type: "application/octet-stream".into(),
        classification: "sensitive".into(),
        purpose: "file".into(),
        value: WorkflowStorageValueInput::Object {
            digest: digest.into(),
            byte_count,
        },
        created_by_attempt_id: format!("attempt-{}", fixture.version),
        created_at_unix_millis: 2_000,
    }
}

#[test]
fn job_case_installation_and_account_scopes_fail_closed_across_contexts() {
    let temporary = tempdir().unwrap();
    let mut storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();
    let job_a = namespace(WorkflowStorageScopeKind::Job, "run-a", Some("install-a"));
    let job_b = namespace(WorkflowStorageScopeKind::Job, "run-b", Some("install-a"));
    let case_a = namespace(WorkflowStorageScopeKind::Case, "case-a", Some("install-a"));
    let installation_a = namespace(
        WorkflowStorageScopeKind::Installation,
        "install-a",
        Some("install-a"),
    );
    let account_a = namespace(WorkflowStorageScopeKind::AccountBinding, "account-a", None);
    for (index, scope) in [&job_a, &job_b, &case_a, &installation_a, &account_a]
        .into_iter()
        .enumerate()
    {
        assert!(
            !storage
                .register_namespace(scope.clone(), namespace_quota(), 100 + index as i64)
                .unwrap()
        );
    }

    let job_receipt = storage
        .write_value(inline_request(
            write_fixture(
                "command-job-a",
                "entry-job-a",
                "version-job-a",
                "working/result.json",
            ),
            access(Some("run-a"), Some("case-a"), "install-a", &["account-a"]),
            job_a.clone(),
            0,
            br#"{"ok":true}"#,
            1_000,
        ))
        .unwrap();
    assert!(
        storage
            .inspect_handle(
                &access(Some("run-a"), Some("case-a"), "install-a", &[]),
                &job_receipt.handle.handle_id,
            )
            .is_ok()
    );
    assert!(matches!(
        storage.inspect_handle(
            &access(Some("run-b"), Some("case-a"), "install-a", &[]),
            &job_receipt.handle.handle_id,
        ),
        Err(WorkflowStorageError::AccessDenied("namespace"))
    ));
    assert!(matches!(
        storage.inspect_handle(
            &access(Some("run-a"), Some("case-a"), "install-b", &[]),
            &job_receipt.handle.handle_id,
        ),
        Err(WorkflowStorageError::AccessDenied("namespace"))
    ));

    let case_receipt = storage
        .write_value(inline_request(
            write_fixture(
                "command-case-a",
                "entry-case-a",
                "version-case-a",
                "conversation/context.json",
            ),
            access(Some("run-a"), Some("case-a"), "install-a", &[]),
            case_a,
            0,
            br#"{"turns":1}"#,
            1_001,
        ))
        .unwrap();
    assert!(matches!(
        storage.inspect_handle(
            &access(Some("run-a"), Some("case-b"), "install-a", &[]),
            &case_receipt.handle.handle_id,
        ),
        Err(WorkflowStorageError::AccessDenied("namespace"))
    ));

    let installation_receipt = storage
        .write_value(inline_request(
            write_fixture(
                "command-install-a",
                "entry-install-a",
                "version-install-a",
                "templates/default.json",
            ),
            access(Some("run-a"), None, "install-a", &[]),
            installation_a,
            0,
            br#"{"template":1}"#,
            1_002,
        ))
        .unwrap();
    assert!(matches!(
        storage.inspect_handle(
            &access(Some("run-c"), None, "install-b", &[]),
            &installation_receipt.handle.handle_id,
        ),
        Err(WorkflowStorageError::AccessDenied("namespace"))
    ));

    let account_receipt = storage
        .write_value(inline_request(
            write_fixture(
                "command-account-a",
                "entry-account-a",
                "version-account-a",
                "provider/cursor.json",
            ),
            access(Some("run-a"), None, "install-a", &["account-a"]),
            account_a,
            0,
            br#"{"cursor":"one"}"#,
            1_003,
        ))
        .unwrap();
    assert!(matches!(
        storage.inspect_handle(
            &access(Some("run-a"), None, "install-a", &[]),
            &account_receipt.handle.handle_id,
        ),
        Err(WorkflowStorageError::AccessDenied("namespace"))
    ));
}

#[test]
fn optimistic_versions_are_idempotent_and_survive_restart() {
    let temporary = tempdir().unwrap();
    let scope = namespace(
        WorkflowStorageScopeKind::Job,
        "run-versioned",
        Some("install-a"),
    );
    let context = access(Some("run-versioned"), None, "install-a", &[]);
    let first_request = inline_request(
        write_fixture(
            "command-version-one",
            "entry-versioned",
            "version-one",
            "state/value.json",
        ),
        context.clone(),
        scope.clone(),
        0,
        br#"{"value":1}"#,
        1_000,
    );
    {
        let mut storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();
        storage
            .register_namespace(scope.clone(), namespace_quota(), 100)
            .unwrap();
        let first = storage.write_value(first_request.clone()).unwrap();
        assert_eq!(first.handle.revision, 1);
        assert!(!first.duplicate);
        let duplicate = storage.write_value(first_request).unwrap();
        assert!(duplicate.duplicate);
        assert_eq!(duplicate.handle, first.handle);

        let stale = inline_request(
            write_fixture(
                "command-version-stale",
                "entry-versioned",
                "version-stale",
                "state/value.json",
            ),
            context.clone(),
            scope.clone(),
            0,
            br#"{"value":2}"#,
            1_001,
        );
        assert!(matches!(
            storage.write_value(stale),
            Err(WorkflowStorageError::Conflict {
                expected: 0,
                actual: 1
            })
        ));
        let second = storage
            .write_value(inline_request(
                write_fixture(
                    "command-version-two",
                    "entry-versioned",
                    "version-two",
                    "state/value.json",
                ),
                context.clone(),
                scope.clone(),
                1,
                br#"{"value":2}"#,
                1_002,
            ))
            .unwrap();
        assert_eq!(second.handle.revision, 2);
    }

    let storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();
    let current = storage
        .list_current(&context, &scope, Some("state/"), 10)
        .unwrap();
    assert_eq!(current.len(), 1);
    assert_eq!(current[0].version_id, "version-two");
    let historical = storage.inspect_handle(&context, "version-one").unwrap();
    assert_eq!(historical.revision, 1);
    let mut bytes = Vec::new();
    storage
        .copy_value(&context, "version-one", 1024, &mut bytes)
        .unwrap();
    assert_eq!(bytes, br#"{"value":1}"#);
    assert_eq!(storage.usage(&context, &scope).unwrap().version_count, 2);
    storage.verify_integrity().unwrap();
}

#[test]
fn one_physical_object_can_have_isolated_logical_references_without_path_leakage() {
    let temporary = tempdir().unwrap();
    let bytes = (0..1024)
        .map(|value| (value % 251) as u8)
        .collect::<Vec<_>>();
    let expected = hex::encode(Sha256::digest(&bytes));
    let object_store = open_workflow_object_store(temporary.path(), object_quota()).unwrap();
    let mut write = object_store
        .begin_write("shared-object-write", Some(&expected))
        .unwrap();
    write.write_chunk(&bytes).unwrap();
    let object = object_store.finalize(write).unwrap();

    let mut storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();
    let first_scope = namespace(WorkflowStorageScopeKind::Job, "run-one", Some("install-a"));
    let second_scope = namespace(WorkflowStorageScopeKind::Job, "run-two", Some("install-a"));
    storage
        .register_namespace(first_scope.clone(), namespace_quota(), 100)
        .unwrap();
    storage
        .register_namespace(second_scope.clone(), namespace_quota(), 101)
        .unwrap();
    let first_access = access(Some("run-one"), None, "install-a", &[]);
    let second_access = access(Some("run-two"), None, "install-a", &[]);
    let first = storage
        .write_value(object_request(
            write_fixture(
                "command-object-one",
                "entry-object-one",
                "version-object-one",
                "files/result.bin",
            ),
            first_access.clone(),
            first_scope.clone(),
            "reference-object-one",
            &object.manifest.digest,
            object.manifest.byte_count,
        ))
        .unwrap();
    let second = storage
        .write_value(object_request(
            write_fixture(
                "command-object-two",
                "entry-object-two",
                "version-object-two",
                "files/result.bin",
            ),
            second_access.clone(),
            second_scope.clone(),
            "reference-object-two",
            &object.manifest.digest,
            object.manifest.byte_count,
        ))
        .unwrap();
    assert!(matches!(
        storage.inspect_handle(&second_access, &first.handle.handle_id),
        Err(WorkflowStorageError::AccessDenied("namespace"))
    ));
    let mut first_copy = Vec::new();
    storage
        .copy_value(
            &first_access,
            &first.handle.handle_id,
            2048,
            &mut first_copy,
        )
        .unwrap();
    let mut second_copy = Vec::new();
    storage
        .copy_value(
            &second_access,
            &second.handle.handle_id,
            2048,
            &mut second_copy,
        )
        .unwrap();
    assert_eq!(first_copy, bytes);
    assert_eq!(second_copy, bytes);
    assert_eq!(
        storage
            .usage(&first_access, &first_scope)
            .unwrap()
            .byte_count,
        1024
    );
    assert_eq!(
        storage
            .usage(&second_access, &second_scope)
            .unwrap()
            .byte_count,
        1024
    );
    assert_eq!(
        object_store.usage().unwrap(),
        WorkflowObjectStoreUsage {
            object_count: 1,
            byte_count: 1024,
        }
    );
    let serialized = serde_json::to_string(&(first, second)).unwrap();
    assert!(!serialized.contains("Objects"));
    assert!(!serialized.contains(&temporary.path().to_string_lossy().to_string()));
    storage.verify_integrity().unwrap();
}

#[test]
fn item_value_and_total_quotas_reject_without_partial_versions() {
    let temporary = tempdir().unwrap();
    let mut storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();

    let item_scope = namespace(
        WorkflowStorageScopeKind::Job,
        "run-item-quota",
        Some("install-a"),
    );
    let item_access = access(Some("run-item-quota"), None, "install-a", &[]);
    storage
        .register_namespace(
            item_scope.clone(),
            WorkflowStorageNamespaceQuota {
                maximum_item_count: 1,
                maximum_total_bytes: 10,
                maximum_value_bytes: 10,
            },
            100,
        )
        .unwrap();
    storage
        .write_value(inline_request(
            write_fixture(
                "command-item-one",
                "entry-item-one",
                "version-item-one",
                "one.json",
            ),
            item_access.clone(),
            item_scope.clone(),
            0,
            b"1",
            1_000,
        ))
        .unwrap();
    assert!(matches!(
        storage.write_value(inline_request(
            write_fixture(
                "command-item-two",
                "entry-item-two",
                "version-item-two",
                "two.json",
            ),
            item_access.clone(),
            item_scope.clone(),
            0,
            b"2",
            1_001,
        )),
        Err(WorkflowStorageError::QuotaExceeded("item_count"))
    ));
    assert_eq!(
        storage.usage(&item_access, &item_scope).unwrap().item_count,
        1
    );

    let value_scope = namespace(
        WorkflowStorageScopeKind::Job,
        "run-value-quota",
        Some("install-a"),
    );
    let value_access = access(Some("run-value-quota"), None, "install-a", &[]);
    storage
        .register_namespace(
            value_scope.clone(),
            WorkflowStorageNamespaceQuota {
                maximum_item_count: 2,
                maximum_total_bytes: 10,
                maximum_value_bytes: 2,
            },
            101,
        )
        .unwrap();
    assert!(matches!(
        storage.write_value(inline_request(
            write_fixture(
                "command-value-large",
                "entry-value-large",
                "version-value-large",
                "large.json",
            ),
            value_access.clone(),
            value_scope.clone(),
            0,
            b"123",
            1_002,
        )),
        Err(WorkflowStorageError::QuotaExceeded("value_bytes"))
    ));
    assert_eq!(
        storage
            .usage(&value_access, &value_scope)
            .unwrap()
            .version_count,
        0
    );

    let total_scope = namespace(
        WorkflowStorageScopeKind::Job,
        "run-total-quota",
        Some("install-a"),
    );
    let total_access = access(Some("run-total-quota"), None, "install-a", &[]);
    storage
        .register_namespace(
            total_scope.clone(),
            WorkflowStorageNamespaceQuota {
                maximum_item_count: 2,
                maximum_total_bytes: 5,
                maximum_value_bytes: 5,
            },
            102,
        )
        .unwrap();
    storage
        .write_value(inline_request(
            write_fixture(
                "command-total-one",
                "entry-total",
                "version-total-one",
                "total.json",
            ),
            total_access.clone(),
            total_scope.clone(),
            0,
            b"123",
            1_003,
        ))
        .unwrap();
    assert!(matches!(
        storage.write_value(inline_request(
            write_fixture(
                "command-total-two",
                "entry-total",
                "version-total-two",
                "total.json",
            ),
            total_access.clone(),
            total_scope.clone(),
            1,
            b"456",
            1_004,
        )),
        Err(WorkflowStorageError::QuotaExceeded("total_bytes"))
    ));
    assert_eq!(
        storage
            .usage(&total_access, &total_scope)
            .unwrap()
            .version_count,
        1
    );
}

#[test]
fn namespace_identity_and_object_metadata_cannot_be_rebound() {
    let temporary = tempdir().unwrap();
    let scope = namespace(
        WorkflowStorageScopeKind::Job,
        "run-bound",
        Some("install-a"),
    );
    let mut storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();
    assert!(
        !storage
            .register_namespace(scope.clone(), namespace_quota(), 100)
            .unwrap()
    );
    assert!(
        storage
            .register_namespace(scope.clone(), namespace_quota(), 100)
            .unwrap()
    );
    assert!(matches!(
        storage.register_namespace(
            scope,
            WorkflowStorageNamespaceQuota {
                maximum_item_count: 99,
                ..namespace_quota()
            },
            100,
        ),
        Err(WorkflowStorageError::Integrity("namespace_identity_reuse"))
    ));

    let object_store = open_workflow_object_store(temporary.path(), object_quota()).unwrap();
    let mut write = object_store
        .begin_write("metadata-object-write", None)
        .unwrap();
    write.write_chunk(b"object").unwrap();
    let object = object_store.finalize(write).unwrap();
    let object_scope = namespace(
        WorkflowStorageScopeKind::Job,
        "run-object",
        Some("install-a"),
    );
    storage
        .register_namespace(object_scope.clone(), namespace_quota(), 101)
        .unwrap();
    let mut request = object_request(
        write_fixture(
            "command-object-mismatch",
            "entry-object-mismatch",
            "version-object-mismatch",
            "files/object.bin",
        ),
        access(Some("run-object"), None, "install-a", &[]),
        object_scope,
        "reference-object-mismatch",
        &object.manifest.digest,
        object.manifest.byte_count + 1,
    );
    assert!(matches!(
        storage.write_value(request.clone()),
        Err(WorkflowStorageError::Integrity("object_byte_count"))
    ));
    request.value = WorkflowStorageValueInput::Object {
        digest: "f".repeat(64),
        byte_count: 6,
    };
    assert!(matches!(
        storage.write_value(request),
        Err(WorkflowStorageError::ObjectStore(_))
    ));
}

#[test]
fn list_bounds_and_command_identity_reuse_are_rejected() {
    let temporary = tempdir().unwrap();
    let scope = namespace(WorkflowStorageScopeKind::Job, "run-list", Some("install-a"));
    let context = access(Some("run-list"), None, "install-a", &[]);
    let mut storage = open_workflow_scoped_storage(temporary.path(), object_quota()).unwrap();
    storage
        .register_namespace(scope.clone(), namespace_quota(), 100)
        .unwrap();
    let request = inline_request(
        write_fixture(
            "command-reused",
            "entry-list",
            "version-list",
            "folder/value.json",
        ),
        context.clone(),
        scope.clone(),
        0,
        b"1",
        1_000,
    );
    storage.write_value(request.clone()).unwrap();
    let mut changed = request;
    changed.value = WorkflowStorageValueInput::InlineCanonicalJson {
        bytes: b"2".to_vec(),
    };
    assert!(matches!(
        storage.write_value(changed),
        Err(WorkflowStorageError::Integrity("command_identity_reuse"))
    ));
    assert!(matches!(
        storage.list_current(&context, &scope, None, 0),
        Err(WorkflowStorageError::Invalid("list_limit"))
    ));
    assert!(matches!(
        storage.list_current(&context, &scope, Some("../"), 10),
        Err(WorkflowStorageError::Invalid("logical_prefix"))
    ));
    assert_eq!(
        storage
            .list_current(&context, &scope, Some("folder/"), 10)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn newer_schema_and_corrupt_current_pointer_fail_closed_on_reopen() {
    let newer = tempdir().unwrap();
    {
        let _storage = open_workflow_scoped_storage(newer.path(), object_quota()).unwrap();
    }
    let newer_database = newer.path().join("Objects").join("workflow-storage.sqlite");
    let newer_connection = rusqlite::Connection::open(&newer_database).unwrap();
    newer_connection
        .pragma_update(None, "user_version", 2)
        .unwrap();
    drop(newer_connection);
    assert!(matches!(
        open_workflow_scoped_storage(newer.path(), object_quota()),
        Err(WorkflowStorageError::UnsupportedNewerSchema {
            found: 2,
            supported: 1
        })
    ));

    let corrupt = tempdir().unwrap();
    let scope = namespace(
        WorkflowStorageScopeKind::Job,
        "run-corrupt",
        Some("install-a"),
    );
    {
        let mut storage = open_workflow_scoped_storage(corrupt.path(), object_quota()).unwrap();
        storage
            .register_namespace(scope.clone(), namespace_quota(), 100)
            .unwrap();
        storage
            .write_value(inline_request(
                write_fixture(
                    "command-corrupt",
                    "entry-corrupt",
                    "version-corrupt",
                    "state/corrupt.json",
                ),
                access(Some("run-corrupt"), None, "install-a", &[]),
                scope,
                0,
                b"1",
                1_000,
            ))
            .unwrap();
    }
    let corrupt_database = corrupt
        .path()
        .join("Objects")
        .join("workflow-storage.sqlite");
    let corrupt_connection = rusqlite::Connection::open(&corrupt_database).unwrap();
    corrupt_connection
        .execute(
            "UPDATE storage_entries SET current_version_id = 'missing-version'",
            [],
        )
        .unwrap();
    drop(corrupt_connection);
    assert!(matches!(
        open_workflow_scoped_storage(corrupt.path(), object_quota()),
        Err(WorkflowStorageError::Integrity("current_versions"))
    ));
}
