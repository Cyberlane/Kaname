//! Read-only workflow history, semantic comparisons, and alias-only activation.
//!
//! Published bundle bytes remain owned by `workflow_publication`. This module
//! verifies them before presentation, compares versions without exposing a
//! second graph interpreter, and changes only the activation alias row.

use crate::workflow_library::{
    Result, WorkflowLibraryError, WorkflowLibraryStore, is_workflow_identifier,
    read_bounded_private_file,
};
use rusqlite::{OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeSet, path::Path};

const MAXIMUM_REVISION_SOURCE_BYTES: usize = 512 * 1024;
const MAXIMUM_COMPARISON_POINTERS: usize = 4_096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkflowPortfolioState {
    Draft,
    Published,
    Active,
    Disabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkflowExecutionSupport {
    Executable,
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowPortfolioItem {
    pub workflow_id: String,
    pub package_id: String,
    pub name: String,
    pub summary: String,
    pub state: WorkflowPortfolioState,
    pub has_draft: bool,
    pub latest_revision_id: Option<String>,
    pub latest_revision_number: Option<i64>,
    pub active_revision_id: Option<String>,
    pub execution_support: Option<WorkflowExecutionSupport>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowRevisionSummary {
    pub workflow_id: String,
    pub revision_id: String,
    pub revision_number: i64,
    pub release_version: String,
    pub created_at_unix_millis: i64,
    pub package_digest: String,
    pub is_active: bool,
    pub execution_support: WorkflowExecutionSupport,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkflowRevisionContent {
    pub summary: WorkflowRevisionSummary,
    pub workflow_source: Vec<u8>,
    pub layout_source: Vec<u8>,
    pub schema_bundle_source: Vec<u8>,
    pub dependency_lock_source: Vec<u8>,
    pub configuration_source: Vec<u8>,
    pub compiled_source: Vec<u8>,
    pub validation_source: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowRevisionComparison {
    pub workflow_id: String,
    pub from_revision_id: String,
    pub to_revision_id: String,
    pub added_node_ids: Vec<String>,
    pub removed_node_ids: Vec<String>,
    pub changed_definition_pointers: Vec<String>,
    pub changed_layout_pointers: Vec<String>,
    pub changed_configuration_pointers: Vec<String>,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetWorkflowActivation {
    pub alias_id: String,
    pub workflow_id: String,
    pub alias_key: String,
    pub revision_id: Option<String>,
    pub expected_generation: i64,
    pub updated_at_unix_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowActivation {
    pub workflow_id: String,
    pub alias_key: String,
    pub revision_id: Option<String>,
    pub generation: i64,
    pub duplicate: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[doc(hidden)]
pub enum WorkflowActivationFault {
    AfterCommit,
}

impl WorkflowLibraryStore {
    pub fn workflow_portfolio(&self, alias_key: &str) -> Result<Vec<WorkflowPortfolioItem>> {
        validate_identifier(alias_key, "alias_key")?;
        let mut identities = self.connection.prepare(
            "SELECT workflow_id, package_id, name, summary
             FROM workflow_identities
             ORDER BY updated_at_unix_millis DESC, workflow_id",
        )?;
        let rows = identities.query_map([], identity_row_from_query)?;
        let mut items = Vec::new();
        for row in rows {
            let identity = row?;
            let workflow_id = identity.workflow_id;
            let draft_state: Option<String> = self
                .connection
                .query_row(
                    "SELECT state FROM workflow_drafts WHERE workflow_id = ?1",
                    [&workflow_id],
                    |record| record.get(0),
                )
                .optional()?;
            let has_draft = draft_state.is_some();
            let latest = latest_revision_row(&self.connection, &workflow_id)?;
            let alias = activation_row(&self.connection, &workflow_id, alias_key)?;
            let execution_support = latest
                .as_ref()
                .map(|row| self.revision_execution_support(&row.revision_id))
                .transpose()?
                .or_else(|| {
                    (draft_state.as_deref() == Some("unsupported"))
                        .then_some(WorkflowExecutionSupport::Unsupported)
                });
            let active_revision_id = alias.as_ref().and_then(|row| row.revision_id.clone());
            let state = if active_revision_id.is_some() {
                WorkflowPortfolioState::Active
            } else if alias.is_some() {
                WorkflowPortfolioState::Disabled
            } else if latest.is_some() {
                WorkflowPortfolioState::Published
            } else {
                WorkflowPortfolioState::Draft
            };
            items.push(WorkflowPortfolioItem {
                workflow_id,
                package_id: identity.package_id,
                name: identity.name,
                summary: identity.summary,
                state,
                has_draft,
                latest_revision_id: latest.as_ref().map(|row| row.revision_id.clone()),
                latest_revision_number: latest.as_ref().map(|row| row.revision_number),
                active_revision_id,
                execution_support,
            });
        }
        Ok(items)
    }

    pub fn workflow_revision_history(
        &self,
        workflow_id: &str,
        alias_key: &str,
    ) -> Result<Vec<WorkflowRevisionSummary>> {
        validate_identifier(workflow_id, "workflow_id")?;
        validate_identifier(alias_key, "alias_key")?;
        let active = activation_row(&self.connection, workflow_id, alias_key)?
            .and_then(|row| row.revision_id);
        let mut statement = self.connection.prepare(
            "SELECT r.workflow_id, r.revision_id, r.revision_number,
                    (SELECT p.release_version FROM package_registrations p
                     WHERE p.revision_id = r.revision_id
                     ORDER BY p.registered_at_unix_millis DESC, p.registration_id LIMIT 1),
                    r.created_at_unix_millis, r.package_digest
             FROM workflow_revisions r
             WHERE r.workflow_id = ?1
             ORDER BY r.revision_number DESC",
        )?;
        let rows = statement.query_map([workflow_id], revision_row_from_query)?;
        let mut history = Vec::new();
        for row in rows {
            let row = row?;
            let execution_support = self.revision_execution_support(&row.revision_id)?;
            let is_active = active.as_deref() == Some(row.revision_id.as_str());
            history.push(row.summary(is_active, execution_support));
        }
        Ok(history)
    }

    pub fn load_workflow_revision(
        &self,
        revision_id: &str,
        alias_key: &str,
    ) -> Result<WorkflowRevisionContent> {
        validate_identifier(revision_id, "revision_id")?;
        self.verify_published_revision(revision_id)?;
        let row = revision_row(&self.connection, revision_id)?
            .ok_or_else(|| WorkflowLibraryError::RevisionHistory("revision_not_found".into()))?;
        let active = activation_row(&self.connection, &row.workflow_id, alias_key)?
            .and_then(|alias| alias.revision_id);
        let directory = self.revision_directory(revision_id)?;
        let execution_support = read_execution_support(&directory.join("compiled.json"))?;
        Ok(WorkflowRevisionContent {
            summary: row.summary(active.as_deref() == Some(revision_id), execution_support),
            workflow_source: read_revision_file(&directory, "workflow.json")?,
            layout_source: read_revision_file(&directory, "layout.json")?,
            schema_bundle_source: read_revision_file(&directory, "schemas/bundle.json")?,
            dependency_lock_source: read_revision_file(&directory, "lock.json")?,
            configuration_source: read_revision_file(&directory, "schemas/configuration.json")?,
            compiled_source: read_revision_file(&directory, "compiled.json")?,
            validation_source: read_revision_file(&directory, "validation.json")?,
        })
    }

    pub fn compare_workflow_revisions(
        &self,
        from_revision_id: &str,
        to_revision_id: &str,
    ) -> Result<WorkflowRevisionComparison> {
        let from = self.load_workflow_revision(from_revision_id, "active")?;
        let to = self.load_workflow_revision(to_revision_id, "active")?;
        if from.summary.workflow_id != to.summary.workflow_id {
            return Err(WorkflowLibraryError::RevisionHistory(
                "cross_workflow_comparison".into(),
            ));
        }
        let from_workflow = parse_revision_json(&from.workflow_source)?;
        let to_workflow = parse_revision_json(&to.workflow_source)?;
        let from_layout = parse_revision_json(&from.layout_source)?;
        let to_layout = parse_revision_json(&to.layout_source)?;
        let from_configuration = parse_revision_json(&from.configuration_source)?;
        let to_configuration = parse_revision_json(&to.configuration_source)?;
        let from_nodes = node_ids(&from_workflow)?;
        let to_nodes = node_ids(&to_workflow)?;
        let mut remaining = MAXIMUM_COMPARISON_POINTERS;
        let (changed_definition_pointers, definition_truncated) =
            difference_pointers(&from_workflow, &to_workflow, &mut remaining);
        let (changed_layout_pointers, layout_truncated) =
            difference_pointers(&from_layout, &to_layout, &mut remaining);
        let (changed_configuration_pointers, configuration_truncated) =
            difference_pointers(&from_configuration, &to_configuration, &mut remaining);
        Ok(WorkflowRevisionComparison {
            workflow_id: from.summary.workflow_id,
            from_revision_id: from.summary.revision_id,
            to_revision_id: to.summary.revision_id,
            added_node_ids: to_nodes.difference(&from_nodes).cloned().collect(),
            removed_node_ids: from_nodes.difference(&to_nodes).cloned().collect(),
            changed_definition_pointers,
            changed_layout_pointers,
            changed_configuration_pointers,
            truncated: definition_truncated || layout_truncated || configuration_truncated,
        })
    }

    pub fn set_workflow_activation(
        &mut self,
        request: SetWorkflowActivation,
    ) -> Result<WorkflowActivation> {
        self.set_workflow_activation_with_fault(request, None)
    }

    #[doc(hidden)]
    pub fn set_workflow_activation_with_fault_for_test(
        &mut self,
        request: SetWorkflowActivation,
        fault: WorkflowActivationFault,
    ) -> Result<WorkflowActivation> {
        self.set_workflow_activation_with_fault(request, Some(fault))
    }

    fn set_workflow_activation_with_fault(
        &mut self,
        request: SetWorkflowActivation,
        fault: Option<WorkflowActivationFault>,
    ) -> Result<WorkflowActivation> {
        validate_activation_request(&request)?;
        if let Some(revision_id) = request.revision_id.as_deref() {
            let revision_workflow: Option<String> = self
                .connection
                .query_row(
                    "SELECT workflow_id FROM workflow_revisions WHERE revision_id = ?1",
                    [revision_id],
                    |row| row.get(0),
                )
                .optional()?;
            if revision_workflow.as_deref() != Some(request.workflow_id.as_str()) {
                return Err(WorkflowLibraryError::RevisionHistory(
                    "activation_revision_not_found".into(),
                ));
            }
            self.verify_published_revision(revision_id)?;
        }
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = activation_row(&transaction, &request.workflow_id, &request.alias_key)?;
        if let Some(current) = current {
            if current.alias_id != request.alias_id {
                return Err(WorkflowLibraryError::RevisionHistory(
                    "activation_alias_identity".into(),
                ));
            }
            if current.generation == request.expected_generation + 1
                && current.revision_id == request.revision_id
                && current.updated_at_unix_millis == request.updated_at_unix_millis
            {
                return Ok(current.outcome(true));
            }
            if current.generation != request.expected_generation {
                return Err(WorkflowLibraryError::ActivationConflict {
                    expected: request.expected_generation,
                    actual: current.generation,
                });
            }
            if request.updated_at_unix_millis < current.updated_at_unix_millis {
                return Err(WorkflowLibraryError::RevisionHistory(
                    "activation_time_regression".into(),
                ));
            }
            let generation = current.generation + 1;
            transaction.execute(
                "UPDATE activation_aliases
                 SET revision_id = ?1, generation = ?2, updated_at_unix_millis = ?3
                 WHERE alias_id = ?4 AND generation = ?5",
                params![
                    request.revision_id,
                    generation,
                    request.updated_at_unix_millis,
                    request.alias_id,
                    request.expected_generation,
                ],
            )?;
            transaction.commit()?;
            let outcome = WorkflowActivation {
                workflow_id: request.workflow_id,
                alias_key: request.alias_key,
                revision_id: request.revision_id,
                generation,
                duplicate: false,
            };
            if fault == Some(WorkflowActivationFault::AfterCommit) {
                return Err(WorkflowLibraryError::InjectedActivationInterruption);
            }
            return Ok(outcome);
        }
        if request.expected_generation != 0 {
            return Err(WorkflowLibraryError::ActivationConflict {
                expected: request.expected_generation,
                actual: 0,
            });
        }
        transaction.execute(
            "INSERT INTO activation_aliases
               (alias_id, workflow_id, alias_key, revision_id, generation, updated_at_unix_millis)
             VALUES (?1, ?2, ?3, ?4, 1, ?5)",
            params![
                request.alias_id,
                request.workflow_id,
                request.alias_key,
                request.revision_id,
                request.updated_at_unix_millis,
            ],
        )?;
        transaction.commit()?;
        let outcome = WorkflowActivation {
            workflow_id: request.workflow_id,
            alias_key: request.alias_key,
            revision_id: request.revision_id,
            generation: 1,
            duplicate: false,
        };
        if fault == Some(WorkflowActivationFault::AfterCommit) {
            return Err(WorkflowLibraryError::InjectedActivationInterruption);
        }
        Ok(outcome)
    }

    fn revision_execution_support(&self, revision_id: &str) -> Result<WorkflowExecutionSupport> {
        self.verify_published_revision(revision_id)?;
        let directory = self.revision_directory(revision_id)?;
        read_execution_support(&directory.join("compiled.json"))
    }

    fn revision_directory(&self, revision_id: &str) -> Result<std::path::PathBuf> {
        let relative: Option<String> = self
            .connection
            .query_row(
                "SELECT bundle_relative_path FROM workflow_revisions WHERE revision_id = ?1",
                [revision_id],
                |row| row.get(0),
            )
            .optional()?;
        let relative = relative
            .ok_or_else(|| WorkflowLibraryError::RevisionHistory("revision_not_found".into()))?;
        Ok(self.workflow_root()?.join(relative))
    }
}

#[derive(Debug)]
struct IdentityRow {
    workflow_id: String,
    package_id: String,
    name: String,
    summary: String,
}

#[derive(Debug)]
struct RevisionRow {
    workflow_id: String,
    revision_id: String,
    revision_number: i64,
    release_version: String,
    created_at_unix_millis: i64,
    package_digest: String,
}

fn identity_row_from_query(row: &rusqlite::Row<'_>) -> rusqlite::Result<IdentityRow> {
    let workflow_id = row.get(0)?;
    Ok(IdentityRow {
        workflow_id,
        package_id: row.get(1)?,
        name: row.get(2)?,
        summary: row.get(3)?,
    })
}

impl RevisionRow {
    fn summary(
        self,
        is_active: bool,
        execution_support: WorkflowExecutionSupport,
    ) -> WorkflowRevisionSummary {
        WorkflowRevisionSummary {
            workflow_id: self.workflow_id,
            revision_id: self.revision_id,
            revision_number: self.revision_number,
            release_version: self.release_version,
            created_at_unix_millis: self.created_at_unix_millis,
            package_digest: self.package_digest,
            is_active,
            execution_support,
        }
    }
}

#[derive(Debug)]
struct ActivationRow {
    alias_id: String,
    workflow_id: String,
    alias_key: String,
    revision_id: Option<String>,
    generation: i64,
    updated_at_unix_millis: i64,
}

impl ActivationRow {
    fn outcome(self, duplicate: bool) -> WorkflowActivation {
        WorkflowActivation {
            workflow_id: self.workflow_id,
            alias_key: self.alias_key,
            revision_id: self.revision_id,
            generation: self.generation,
            duplicate,
        }
    }
}

fn latest_revision_row(
    connection: &rusqlite::Connection,
    workflow_id: &str,
) -> Result<Option<RevisionRow>> {
    Ok(connection
        .query_row(
            "SELECT r.workflow_id, r.revision_id, r.revision_number,
                    (SELECT p.release_version FROM package_registrations p
                     WHERE p.revision_id = r.revision_id
                     ORDER BY p.registered_at_unix_millis DESC, p.registration_id LIMIT 1),
                    r.created_at_unix_millis, r.package_digest
             FROM workflow_revisions r
             WHERE r.workflow_id = ?1
             ORDER BY r.revision_number DESC LIMIT 1",
            [workflow_id],
            revision_row_from_query,
        )
        .optional()?)
}

fn revision_row(
    connection: &rusqlite::Connection,
    revision_id: &str,
) -> Result<Option<RevisionRow>> {
    Ok(connection
        .query_row(
            "SELECT r.workflow_id, r.revision_id, r.revision_number,
                    (SELECT p.release_version FROM package_registrations p
                     WHERE p.revision_id = r.revision_id
                     ORDER BY p.registered_at_unix_millis DESC, p.registration_id LIMIT 1),
                    r.created_at_unix_millis, r.package_digest
             FROM workflow_revisions r
             WHERE r.revision_id = ?1",
            [revision_id],
            revision_row_from_query,
        )
        .optional()?)
}

fn revision_row_from_query(row: &rusqlite::Row<'_>) -> rusqlite::Result<RevisionRow> {
    Ok(RevisionRow {
        workflow_id: row.get(0)?,
        revision_id: row.get(1)?,
        revision_number: row.get(2)?,
        release_version: row.get(3)?,
        created_at_unix_millis: row.get(4)?,
        package_digest: row.get(5)?,
    })
}

fn activation_row(
    connection: &rusqlite::Connection,
    workflow_id: &str,
    alias_key: &str,
) -> Result<Option<ActivationRow>> {
    Ok(connection
        .query_row(
            "SELECT alias_id, workflow_id, alias_key, revision_id, generation,
                    updated_at_unix_millis
             FROM activation_aliases WHERE workflow_id = ?1 AND alias_key = ?2",
            params![workflow_id, alias_key],
            |row| {
                let generation = row.get(4)?;
                let updated_at_unix_millis = row.get(5)?;
                Ok(ActivationRow {
                    alias_id: row.get(0)?,
                    workflow_id: row.get(1)?,
                    alias_key: row.get(2)?,
                    revision_id: row.get(3)?,
                    generation,
                    updated_at_unix_millis,
                })
            },
        )
        .optional()?)
}

fn read_revision_file(directory: &Path, relative: &str) -> Result<Vec<u8>> {
    read_bounded_private_file(&directory.join(relative), MAXIMUM_REVISION_SOURCE_BYTES)
}

fn read_execution_support(path: &Path) -> Result<WorkflowExecutionSupport> {
    let compiled = parse_revision_json(&read_bounded_private_file(
        path,
        MAXIMUM_REVISION_SOURCE_BYTES,
    )?)?;
    let nodes = compiled
        .get("nodes")
        .and_then(Value::as_array)
        .ok_or_else(|| WorkflowLibraryError::RevisionHistory("compiled_nodes".into()))?;
    if nodes
        .iter()
        .all(|node| node.get("executionAvailability").and_then(Value::as_str) == Some("executable"))
    {
        Ok(WorkflowExecutionSupport::Executable)
    } else {
        Ok(WorkflowExecutionSupport::Unsupported)
    }
}

fn node_ids(workflow: &Value) -> Result<BTreeSet<String>> {
    let nodes = workflow
        .pointer("/graph/nodes")
        .and_then(Value::as_array)
        .ok_or_else(|| WorkflowLibraryError::RevisionHistory("workflow_nodes".into()))?;
    nodes
        .iter()
        .map(|node| {
            node.get("id")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| WorkflowLibraryError::RevisionHistory("workflow_node_id".into()))
        })
        .collect()
}

fn parse_revision_json(bytes: &[u8]) -> Result<Value> {
    serde_json::from_slice(bytes)
        .map_err(|_| WorkflowLibraryError::RevisionHistory("revision_json".into()))
}

fn difference_pointers(left: &Value, right: &Value, remaining: &mut usize) -> (Vec<String>, bool) {
    let mut pointers = Vec::new();
    let mut truncated = false;
    collect_differences(left, right, "", remaining, &mut pointers, &mut truncated);
    (pointers, truncated)
}

fn collect_differences(
    left: &Value,
    right: &Value,
    pointer: &str,
    remaining: &mut usize,
    output: &mut Vec<String>,
    truncated: &mut bool,
) {
    if left == right || *truncated {
        return;
    }
    match (left, right) {
        (Value::Object(left), Value::Object(right)) => {
            let keys = left.keys().chain(right.keys()).collect::<BTreeSet<_>>();
            for key in keys {
                let child = format!("{pointer}/{}", escape_pointer_token(key));
                match (left.get(key), right.get(key)) {
                    (Some(left), Some(right)) => {
                        collect_differences(left, right, &child, remaining, output, truncated)
                    }
                    _ => record_difference(&child, remaining, output, truncated),
                }
            }
        }
        (Value::Array(left), Value::Array(right)) => {
            let length = left.len().max(right.len());
            for index in 0..length {
                let child = format!("{pointer}/{index}");
                match (left.get(index), right.get(index)) {
                    (Some(left), Some(right)) => {
                        collect_differences(left, right, &child, remaining, output, truncated)
                    }
                    _ => record_difference(&child, remaining, output, truncated),
                }
            }
        }
        _ => record_difference(pointer, remaining, output, truncated),
    }
}

fn record_difference(
    pointer: &str,
    remaining: &mut usize,
    output: &mut Vec<String>,
    truncated: &mut bool,
) {
    if *remaining == 0 {
        *truncated = true;
    } else {
        output.push(if pointer.is_empty() {
            "/".into()
        } else {
            pointer.into()
        });
        *remaining -= 1;
    }
}

fn escape_pointer_token(value: &str) -> String {
    value.replace('~', "~0").replace('/', "~1")
}

fn validate_activation_request(request: &SetWorkflowActivation) -> Result<()> {
    validate_identifier(&request.alias_id, "alias_id")?;
    validate_identifier(&request.workflow_id, "workflow_id")?;
    validate_identifier(&request.alias_key, "alias_key")?;
    if let Some(revision_id) = request.revision_id.as_deref() {
        validate_identifier(revision_id, "revision_id")?;
    }
    if request.expected_generation < 0 || request.updated_at_unix_millis < 0 {
        return Err(WorkflowLibraryError::RevisionHistory(
            "activation_bounds".into(),
        ));
    }
    Ok(())
}

fn validate_identifier(value: &str, code: &str) -> Result<()> {
    if !is_workflow_identifier(value, 128) {
        return Err(WorkflowLibraryError::RevisionHistory(code.into()));
    }
    Ok(())
}
