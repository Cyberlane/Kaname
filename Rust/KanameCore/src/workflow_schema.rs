use jsonschema::Draft;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const MAXIMUM_SCHEMA_CHECK_REQUEST_BYTES: usize = 512 * 1024;
pub const MAXIMUM_SCHEMA_DIAGNOSTICS: usize = 256;

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WorkflowSchemaCheckRequest {
    pub schema: Value,
    pub instance: Value,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowSchemaCheckOutcome {
    Valid,
    InvalidInstance,
    InvalidSchema,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct WorkflowSchemaDiagnostic {
    pub code: String,
    pub instance_path: String,
    pub schema_path: String,
    pub message: String,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct WorkflowSchemaCheckReport {
    pub draft: &'static str,
    pub outcome: WorkflowSchemaCheckOutcome,
    pub diagnostics: Vec<WorkflowSchemaDiagnostic>,
    pub diagnostics_truncated: bool,
}

pub fn check(request: &WorkflowSchemaCheckRequest) -> WorkflowSchemaCheckReport {
    let validator = match jsonschema::options()
        .with_draft(Draft::Draft202012)
        .should_validate_formats(true)
        .should_ignore_unknown_formats(false)
        .build(&request.schema)
    {
        Ok(validator) => validator,
        Err(error) => {
            return WorkflowSchemaCheckReport {
                draft: "2020-12",
                outcome: WorkflowSchemaCheckOutcome::InvalidSchema,
                diagnostics: vec![diagnostic(&error)],
                diagnostics_truncated: false,
            };
        }
    };

    let mut diagnostics = validator
        .iter_errors(&request.instance)
        .map(|error| diagnostic(&error))
        .collect::<Vec<_>>();
    diagnostics.sort_by(|left, right| {
        (
            &left.instance_path,
            &left.schema_path,
            &left.code,
            &left.message,
        )
            .cmp(&(
                &right.instance_path,
                &right.schema_path,
                &right.code,
                &right.message,
            ))
    });
    let diagnostics_truncated = diagnostics.len() > MAXIMUM_SCHEMA_DIAGNOSTICS;
    diagnostics.truncate(MAXIMUM_SCHEMA_DIAGNOSTICS);
    WorkflowSchemaCheckReport {
        draft: "2020-12",
        outcome: if diagnostics.is_empty() {
            WorkflowSchemaCheckOutcome::Valid
        } else {
            WorkflowSchemaCheckOutcome::InvalidInstance
        },
        diagnostics,
        diagnostics_truncated,
    }
}

fn diagnostic(error: &jsonschema::ValidationError<'_>) -> WorkflowSchemaDiagnostic {
    let schema_path = error.schema_path().to_string();
    let code = schema_path
        .rsplit('/')
        .next()
        .filter(|component| !component.is_empty())
        .unwrap_or("schema")
        .replace('~', "_");
    WorkflowSchemaDiagnostic {
        code: format!("json_schema.{code}"),
        instance_path: error.instance_path().to_string(),
        schema_path,
        message: error.masked_with("value").to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn request(schema: Value, instance: Value) -> WorkflowSchemaCheckRequest {
        WorkflowSchemaCheckRequest { schema, instance }
    }

    #[test]
    fn validates_draft_2020_12_features_and_local_references() {
        let schema = json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$defs": {
                "node": {
                    "type": "object",
                    "properties": {
                        "value": {"type": "integer"},
                        "next": {"$ref": "#/$defs/node"}
                    },
                    "required": ["value"],
                    "unevaluatedProperties": false
                }
            },
            "$ref": "#/$defs/node"
        });
        let valid = check(&request(
            schema.clone(),
            json!({"value": 1, "next": {"value": 2}}),
        ));
        assert_eq!(valid.outcome, WorkflowSchemaCheckOutcome::Valid);

        let invalid = check(&request(schema, json!({"value": 1, "extra": true})));
        assert_eq!(invalid.outcome, WorkflowSchemaCheckOutcome::InvalidInstance);
        assert_eq!(invalid.diagnostics[0].instance_path, "");
        assert!(
            invalid.diagnostics[0]
                .schema_path
                .ends_with("/unevaluatedProperties")
        );
    }

    #[test]
    fn opts_into_format_validation_and_masks_instance_values() {
        let report = check(&request(
            json!({"type": "object", "properties": {"address": {"type": "string", "format": "email"}}}),
            json!({"address": "private-value"}),
        ));
        assert_eq!(report.outcome, WorkflowSchemaCheckOutcome::InvalidInstance);
        assert_eq!(report.diagnostics[0].instance_path, "/address");
        assert!(!report.diagnostics[0].message.contains("private-value"));
    }

    #[test]
    fn sorts_diagnostics_by_stable_locations() {
        let report = check(&request(
            json!({
                "type": "object",
                "properties": {
                    "z": {"type": "integer"},
                    "a": {"type": "integer"}
                }
            }),
            json!({"z": false, "a": false}),
        ));
        let paths = report
            .diagnostics
            .iter()
            .map(|diagnostic| diagnostic.instance_path.as_str())
            .collect::<Vec<_>>();
        assert_eq!(paths, vec!["/a", "/z"]);
    }

    #[test]
    fn external_references_fail_closed_without_network_retrieval() {
        let report = check(&request(
            json!({"$ref": "https://example.invalid/workflow.json"}),
            json!({}),
        ));
        assert_eq!(report.outcome, WorkflowSchemaCheckOutcome::InvalidSchema);
        assert_eq!(report.diagnostics.len(), 1);
    }

    #[test]
    fn unknown_formats_fail_closed_until_registered() {
        let report = check(&request(
            json!({"type": "string", "format": "kaname-unknown"}),
            json!("value"),
        ));
        assert_eq!(report.outcome, WorkflowSchemaCheckOutcome::InvalidSchema);
    }
}
