use kaname_core::{
    open_workflow_object_store,
    workflow_object_store::{
        WorkflowObjectStore, WorkflowObjectStoreError, WorkflowObjectStoreFault,
        WorkflowObjectStoreQuota,
    },
};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fs};
use tempfile::tempdir;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

fn quota(
    maximum_object_bytes: u64,
    maximum_total_bytes: u64,
    maximum_object_count: u64,
) -> WorkflowObjectStoreQuota {
    WorkflowObjectStoreQuota {
        maximum_object_bytes,
        maximum_total_bytes,
        maximum_object_count,
    }
}

fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn write_object(
    store: &WorkflowObjectStore,
    write_id: &str,
    bytes: &[u8],
) -> kaname_core::workflow_object_store::StoredWorkflowObject {
    let mut write = store.begin_write(write_id, Some(&digest(bytes))).unwrap();
    for chunk in bytes.chunks(31) {
        write.write_chunk(chunk).unwrap();
    }
    store.finalize(write).unwrap()
}

#[test]
fn interrupted_boundaries_recover_without_exposing_partial_objects() {
    let faults = [
        WorkflowObjectStoreFault::AfterDataFsyncBeforePromotion,
        WorkflowObjectStoreFault::AfterObjectPromotionBeforeManifest,
        WorkflowObjectStoreFault::AfterManifestPromotion,
    ];
    for (index, fault) in faults.into_iter().enumerate() {
        let temporary = tempdir().unwrap();
        let store = open_workflow_object_store(temporary.path(), quota(1024, 4096, 10)).unwrap();
        let bytes = format!("boundary-{index}").into_bytes();
        let expected = digest(&bytes);
        let mut write = store
            .begin_write(&format!("interrupted-{index}"), Some(&expected))
            .unwrap();
        write.write_chunk(&bytes).unwrap();
        assert!(matches!(
            store.finalize_with_fault_for_test(write, fault),
            Err(WorkflowObjectStoreError::Interrupted(_))
        ));

        let reopened = open_workflow_object_store(temporary.path(), quota(1024, 4096, 10)).unwrap();
        let recovery = reopened.recover().unwrap();
        assert_eq!(recovery.staged_writes_quarantined, 1);
        if fault == WorkflowObjectStoreFault::AfterObjectPromotionBeforeManifest {
            assert_eq!(recovery.invalid_objects_quarantined, 1);
            assert_eq!(reopened.usage().unwrap().object_count, 0);
        } else if fault == WorkflowObjectStoreFault::AfterManifestPromotion {
            assert_eq!(recovery.invalid_objects_quarantined, 0);
            assert_eq!(
                reopened.verify(&expected).unwrap().byte_count,
                bytes.len() as u64
            );
        } else {
            assert_eq!(recovery.invalid_objects_quarantined, 0);
            assert_eq!(reopened.usage().unwrap().object_count, 0);
        }
    }
}

#[test]
fn checksum_mismatch_is_quarantined_and_duplicate_content_is_not_counted_twice() {
    let temporary = tempdir().unwrap();
    let store = open_workflow_object_store(temporary.path(), quota(1024, 4096, 10)).unwrap();
    let mut mismatched = store
        .begin_write("checksum-mismatch", Some(&"0".repeat(64)))
        .unwrap();
    mismatched.write_chunk(b"actual bytes").unwrap();
    assert!(matches!(
        store.finalize(mismatched),
        Err(WorkflowObjectStoreError::ChecksumMismatch)
    ));
    assert_eq!(store.usage().unwrap().object_count, 0);

    let first = write_object(&store, "duplicate-first", b"same immutable bytes");
    let second = write_object(&store, "duplicate-second", b"same immutable bytes");
    assert!(!first.duplicate);
    assert!(second.duplicate);
    assert_eq!(first.manifest, second.manifest);
    assert_eq!(
        store.usage().unwrap(),
        kaname_core::workflow_object_store::WorkflowObjectStoreUsage {
            object_count: 1,
            byte_count: b"same immutable bytes".len() as u64,
        }
    );
    #[cfg(unix)]
    {
        let object = temporary
            .path()
            .join("Objects")
            .join("sha256")
            .join(&first.manifest.digest[..2])
            .join(&first.manifest.digest);
        let manifest = temporary
            .path()
            .join("Objects")
            .join("Manifests")
            .join("sha256")
            .join(&first.manifest.digest[..2])
            .join(format!("{}.json", first.manifest.digest));
        assert_eq!(
            fs::metadata(object).unwrap().permissions().mode() & 0o777,
            0o400
        );
        assert_eq!(
            fs::metadata(manifest).unwrap().permissions().mode() & 0o777,
            0o400
        );
    }
}

#[test]
fn large_object_is_streamed_and_copied_without_path_exposure() {
    let temporary = tempdir().unwrap();
    let store = open_workflow_object_store(
        temporary.path(),
        quota(8 * 1024 * 1024, 16 * 1024 * 1024, 10),
    )
    .unwrap();
    let bytes = (0..5 * 1024 * 1024)
        .map(|index| (index % 251) as u8)
        .collect::<Vec<_>>();
    let mut write = store
        .begin_write("large-streamed-object", Some(&digest(&bytes)))
        .unwrap();
    for chunk in bytes.chunks(47 * 1024) {
        write.write_chunk(chunk).unwrap();
    }
    assert_eq!(write.byte_count(), bytes.len() as u64);
    let stored = store.finalize(write).unwrap();
    let mut copied = Vec::new();
    let manifest = store
        .copy_to(&stored.manifest.digest, bytes.len() as u64, &mut copied)
        .unwrap();
    assert_eq!(manifest, stored.manifest);
    assert_eq!(copied, bytes);
}

#[test]
fn object_file_total_and_count_quotas_fail_closed() {
    let temporary = tempdir().unwrap();
    let store = open_workflow_object_store(temporary.path(), quota(8, 12, 2)).unwrap();
    let mut oversized = store.begin_write("oversized-object", None).unwrap();
    assert!(matches!(
        oversized.write_chunk(b"123456789"),
        Err(WorkflowObjectStoreError::QuotaExceeded("object_bytes"))
    ));
    drop(oversized);
    store.recover().unwrap();

    write_object(&store, "quota-object-one", b"12345678");
    let mut total = store.begin_write("quota-object-two", None).unwrap();
    total.write_chunk(b"abcde").unwrap();
    assert!(matches!(
        store.finalize(total),
        Err(WorkflowObjectStoreError::QuotaExceeded("total_bytes"))
    ));
    store.recover().unwrap();

    let count_store =
        open_workflow_object_store(temporary.path().join("count"), quota(8, 24, 1)).unwrap();
    write_object(&count_store, "count-object-one", b"one");
    let mut count = count_store.begin_write("count-object-two", None).unwrap();
    count.write_chunk(b"two").unwrap();
    assert!(matches!(
        count_store.finalize(count),
        Err(WorkflowObjectStoreError::QuotaExceeded("object_count"))
    ));
    assert_eq!(count_store.usage().unwrap().object_count, 1);
}

#[test]
fn garbage_collection_validates_all_live_references_before_quarantine() {
    let temporary = tempdir().unwrap();
    let store = open_workflow_object_store(temporary.path(), quota(1024, 4096, 10)).unwrap();
    let retained = write_object(&store, "gc-retained-object", b"retained");
    let first_orphan = write_object(&store, "gc-first-orphan", b"orphan one");
    let second_orphan = write_object(&store, "gc-second-orphan", b"orphan two");

    let missing = BTreeSet::from(["f".repeat(64)]);
    assert!(matches!(
        store.quarantine_unreferenced(&missing),
        Err(WorkflowObjectStoreError::Integrity("live_object_missing"))
    ));
    assert_eq!(store.usage().unwrap().object_count, 3);

    let live = BTreeSet::from([retained.manifest.digest.clone()]);
    let receipt = store.quarantine_unreferenced(&live).unwrap();
    assert_eq!(receipt.retained_object_count, 1);
    assert_eq!(receipt.quarantined_object_count, 2);
    assert_eq!(
        receipt.quarantined_byte_count,
        first_orphan.manifest.byte_count + second_orphan.manifest.byte_count
    );
    assert_eq!(
        store.verify(&retained.manifest.digest).unwrap(),
        retained.manifest
    );
    assert!(store.verify(&first_orphan.manifest.digest).is_err());
    assert!(store.verify(&second_orphan.manifest.digest).is_err());
}

#[test]
fn tampered_object_is_detected_and_quarantined_on_recovery() {
    let temporary = tempdir().unwrap();
    let store = open_workflow_object_store(temporary.path(), quota(1024, 4096, 10)).unwrap();
    let stored = write_object(&store, "tamper-detection", b"original");
    let object_path = temporary
        .path()
        .join("Objects")
        .join("sha256")
        .join(&stored.manifest.digest[..2])
        .join(&stored.manifest.digest);
    #[cfg(unix)]
    fs::set_permissions(&object_path, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&object_path, b"tampered").unwrap();
    assert!(matches!(
        store.verify(&stored.manifest.digest),
        Err(WorkflowObjectStoreError::Integrity("object_digest"))
    ));
    let report = store.recover().unwrap();
    assert_eq!(report.invalid_objects_quarantined, 1);
    assert_eq!(store.usage().unwrap().object_count, 0);
}
