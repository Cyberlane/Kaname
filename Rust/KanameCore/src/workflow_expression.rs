//! Deterministic evaluation of the workflow v1 mapping algebra.
//!
//! The mapping language is the closed expression set defined by
//! `Schema/Workflow/v1/mapping.schema.json`: `whole`, `select`, `literal`,
//! `object`, `array`, `coalesce`, and `format`. Evaluation is pure: the result
//! depends only on the expression and the provided roots, so a replayed run
//! recomputes byte-identical values without new journal facts.
//!
//! The executor exposes exactly one root, `input`, holding the value flowing
//! into the mapped edge or node. The remaining schema roots (`value`, `item`,
//! `error`, `job`, `case`, `workflow`) stay authorable but are not executable
//! here; `job`/`case`/`workflow` reads must go through `storage.read` so the
//! read is journaled. `executable_mapping` is the shared gate the compiler and
//! executor use to classify a mapping as runnable.

use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::collections::BTreeSet;

/// Maximum nesting depth for a mapping expression tree.
pub const MAXIMUM_EXPRESSION_DEPTH: usize = 64;
/// Maximum `format` template length in bytes (mirrors the schema bound).
pub const MAXIMUM_TEMPLATE_BYTES: usize = 8192;
/// Maximum named values in a `format` expression (mirrors the schema bound).
pub const MAXIMUM_FORMAT_VALUES: usize = 64;
/// Maximum properties in an `object` expression (mirrors the schema bound).
pub const MAXIMUM_OBJECT_PROPERTIES: usize = 128;
/// Maximum items in an `array` expression (mirrors the schema bound).
pub const MAXIMUM_ARRAY_ITEMS: usize = 128;
/// Operand bounds for `coalesce` (mirrors the schema bounds).
pub const MINIMUM_COALESCE_OPERANDS: usize = 2;
pub const MAXIMUM_COALESCE_OPERANDS: usize = 16;
/// Maximum JSON Pointer length in bytes (mirrors the identifier schema bound).
pub const MAXIMUM_POINTER_BYTES: usize = 4096;
/// Maximum serialized result size. Matches the runtime inline value bound so a
/// mapped value always fits an ordinary inline emission.
pub const MAXIMUM_RESULT_BYTES: usize = 32 * 1024;

/// The only root the minimal executor resolves at runtime.
pub const INPUT_ROOT: &str = "input";

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ExpressionEvaluationError {
    /// Stable machine code, `mapping.`-prefixed.
    pub code: String,
    /// JSON Pointer into the mapping expression that failed.
    pub expression_path: String,
    /// Human-readable diagnostic. Never contains resolved values.
    pub message: String,
}

impl ExpressionEvaluationError {
    fn new(code: &str, path: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            expression_path: path.to_owned(),
            message: message.into(),
        }
    }

    /// Whether the failure represents value absence rather than a structural
    /// defect. `coalesce` skips absence failures and surfaces everything else.
    fn is_absence(&self) -> bool {
        matches!(
            self.code.as_str(),
            "mapping.pointer-unresolved" | "mapping.null-value"
        )
    }
}

type EvaluationResult = Result<Value, ExpressionEvaluationError>;

/// Named root values available to `whole` and `select`.
#[derive(Debug, Default, Clone)]
pub struct ExpressionRoots {
    values: BTreeMap<String, Value>,
}

impl ExpressionRoots {
    pub fn with_input(input: Value) -> Self {
        Self::default().with_root(INPUT_ROOT, input)
    }

    pub fn with_root(mut self, root: impl Into<String>, value: Value) -> Self {
        self.values.insert(root.into(), value);
        self
    }

    fn get(&self, root: &str) -> Option<&Value> {
        self.values.get(root)
    }
}

/// Collects every root name referenced by `whole` or `select` expressions.
/// Malformed nodes are ignored; `executable_mapping` reports them instead.
pub fn referenced_roots(expression: &Value) -> BTreeSet<String> {
    let mut roots = BTreeSet::new();
    collect_roots(expression, 0, &mut roots);
    roots
}

fn collect_roots(expression: &Value, depth: usize, roots: &mut BTreeSet<String>) {
    if depth > MAXIMUM_EXPRESSION_DEPTH {
        return;
    }
    let Some(object) = expression.as_object() else {
        return;
    };
    if object.contains_key("whole") {
        roots.insert(INPUT_ROOT.to_owned());
    }
    if let Some(reference) = object.get("select")
        && let Some(root) = reference.get("root").and_then(Value::as_str)
    {
        roots.insert(root.to_owned());
    }
    if let Some(properties) = object.get("object").and_then(Value::as_object) {
        for property in properties.values() {
            collect_roots(property, depth + 1, roots);
        }
    }
    if let Some(items) = object.get("array").and_then(Value::as_array) {
        for item in items {
            collect_roots(item, depth + 1, roots);
        }
    }
    if let Some(operands) = object.get("coalesce").and_then(Value::as_array) {
        for operand in operands {
            collect_roots(operand, depth + 1, roots);
        }
    }
    if let Some(values) = object
        .get("format")
        .and_then(|format| format.get("values"))
        .and_then(Value::as_object)
    {
        for value in values.values() {
            collect_roots(value, depth + 1, roots);
        }
    }
}

/// Whether the executor can run this mapping: structurally valid per the
/// mapping schema shape and referencing only the `input` root.
pub fn executable_mapping(expression: &Value) -> bool {
    validate_shape(expression, "", 0).is_ok()
        && referenced_roots(expression)
            .iter()
            .all(|root| root == INPUT_ROOT)
}

/// Evaluates a mapping expression against the provided roots.
pub fn evaluate(expression: &Value, roots: &ExpressionRoots) -> EvaluationResult {
    validate_shape(expression, "", 0)?;
    let result = evaluate_at(expression, roots, "", 0)?;
    let encoded = serde_json::to_vec(&result).map_err(|_| {
        ExpressionEvaluationError::new("mapping.result-encoding", "", "The result cannot encode.")
    })?;
    if encoded.len() > MAXIMUM_RESULT_BYTES {
        return Err(ExpressionEvaluationError::new(
            "mapping.result-too-large",
            "",
            format!("The result exceeds {MAXIMUM_RESULT_BYTES} bytes."),
        ));
    }
    Ok(result)
}

fn validate_shape(
    expression: &Value,
    path: &str,
    depth: usize,
) -> Result<(), ExpressionEvaluationError> {
    if depth > MAXIMUM_EXPRESSION_DEPTH {
        return Err(ExpressionEvaluationError::new(
            "mapping.depth-exceeded",
            path,
            format!("Expressions nest deeper than {MAXIMUM_EXPRESSION_DEPTH} levels."),
        ));
    }
    let malformed =
        |path: &str| ExpressionEvaluationError::new("mapping.malformed", path, "The expression is not one of whole, select, literal, object, array, coalesce, or format.");
    let object = expression.as_object().ok_or_else(|| malformed(path))?;
    if object.len() != 1 {
        return Err(malformed(path));
    }
    let (keyword, body) = object.iter().next().expect("single-entry object");
    match keyword.as_str() {
        "whole" => {
            if body != &Value::Bool(true) {
                return Err(malformed(&format!("{path}/whole")));
            }
        }
        "select" => {
            let reference = body.as_object().ok_or_else(|| malformed(&format!("{path}/select")))?;
            let root = reference.get("root").and_then(Value::as_str);
            let pointer = reference.get("pointer").and_then(Value::as_str);
            if reference.len() != 2 || root.is_none() || pointer.is_none() {
                return Err(malformed(&format!("{path}/select")));
            }
            let pointer = pointer.expect("checked pointer");
            if pointer.len() > MAXIMUM_POINTER_BYTES
                || (!pointer.is_empty() && !pointer.starts_with('/'))
            {
                return Err(ExpressionEvaluationError::new(
                    "mapping.pointer-invalid",
                    &format!("{path}/select/pointer"),
                    "The pointer must be an RFC 6901 JSON Pointer within bounds.",
                ));
            }
        }
        "literal" => {
            let literal = body.as_object().ok_or_else(|| malformed(&format!("{path}/literal")))?;
            let literal_type = literal.get("type").and_then(Value::as_str);
            let value = literal.get("value");
            let valid = literal.len() == 2
                && match (literal_type, value) {
                    (Some("string"), Some(Value::String(_)))
                    | (Some("number"), Some(Value::Number(_)))
                    | (Some("boolean"), Some(Value::Bool(_)))
                    | (Some("null"), Some(Value::Null))
                    | (Some("json"), Some(_)) => true,
                    _ => false,
                };
            if !valid {
                return Err(malformed(&format!("{path}/literal")));
            }
        }
        "object" => {
            let properties = body.as_object().ok_or_else(|| malformed(&format!("{path}/object")))?;
            if properties.len() > MAXIMUM_OBJECT_PROPERTIES {
                return Err(ExpressionEvaluationError::new(
                    "mapping.bounds-exceeded",
                    &format!("{path}/object"),
                    format!("Objects allow at most {MAXIMUM_OBJECT_PROPERTIES} properties."),
                ));
            }
            for (key, property) in properties {
                validate_shape(property, &format!("{path}/object/{}", escape(key)), depth + 1)?;
            }
        }
        "array" => {
            let items = body.as_array().ok_or_else(|| malformed(&format!("{path}/array")))?;
            if items.len() > MAXIMUM_ARRAY_ITEMS {
                return Err(ExpressionEvaluationError::new(
                    "mapping.bounds-exceeded",
                    &format!("{path}/array"),
                    format!("Arrays allow at most {MAXIMUM_ARRAY_ITEMS} items."),
                ));
            }
            for (index, item) in items.iter().enumerate() {
                validate_shape(item, &format!("{path}/array/{index}"), depth + 1)?;
            }
        }
        "coalesce" => {
            let operands = body.as_array().ok_or_else(|| malformed(&format!("{path}/coalesce")))?;
            if operands.len() < MINIMUM_COALESCE_OPERANDS
                || operands.len() > MAXIMUM_COALESCE_OPERANDS
            {
                return Err(ExpressionEvaluationError::new(
                    "mapping.bounds-exceeded",
                    &format!("{path}/coalesce"),
                    format!(
                        "Coalesce requires {MINIMUM_COALESCE_OPERANDS} to {MAXIMUM_COALESCE_OPERANDS} operands."
                    ),
                ));
            }
            for (index, operand) in operands.iter().enumerate() {
                validate_shape(operand, &format!("{path}/coalesce/{index}"), depth + 1)?;
            }
        }
        "format" => {
            let format = body.as_object().ok_or_else(|| malformed(&format!("{path}/format")))?;
            let template = format.get("template").and_then(Value::as_str);
            let values = format.get("values").and_then(Value::as_object);
            let (Some(template), Some(values)) = (template, values) else {
                return Err(malformed(&format!("{path}/format")));
            };
            if format.len() != 2 {
                return Err(malformed(&format!("{path}/format")));
            }
            if template.len() > MAXIMUM_TEMPLATE_BYTES || values.len() > MAXIMUM_FORMAT_VALUES {
                return Err(ExpressionEvaluationError::new(
                    "mapping.bounds-exceeded",
                    &format!("{path}/format"),
                    "The template or value set exceeds its schema bound.",
                ));
            }
            let placeholders = template_placeholders(template, &format!("{path}/format/template"))?;
            for placeholder in &placeholders {
                if !values.contains_key(placeholder) {
                    return Err(ExpressionEvaluationError::new(
                        "mapping.format-value-missing",
                        &format!("{path}/format/template"),
                        format!("The template names `{placeholder}` but no such value exists."),
                    ));
                }
            }
            for (key, value) in values {
                validate_shape(value, &format!("{path}/format/values/{}", escape(key)), depth + 1)?;
            }
        }
        _ => return Err(malformed(path)),
    }
    Ok(())
}

fn evaluate_at(
    expression: &Value,
    roots: &ExpressionRoots,
    path: &str,
    depth: usize,
) -> EvaluationResult {
    let object = expression.as_object().expect("validated expression");
    let (keyword, body) = object.iter().next().expect("validated expression");
    match keyword.as_str() {
        "whole" => resolve(roots, INPUT_ROOT, "", &format!("{path}/whole")),
        "select" => {
            let root = body["root"].as_str().expect("validated select");
            let pointer = body["pointer"].as_str().expect("validated select");
            resolve(roots, root, pointer, &format!("{path}/select"))
        }
        "literal" => Ok(body["value"].clone()),
        "object" => {
            let mut result = Map::new();
            for (key, property) in body.as_object().expect("validated object") {
                result.insert(
                    key.clone(),
                    evaluate_at(property, roots, &format!("{path}/object/{}", escape(key)), depth + 1)?,
                );
            }
            Ok(Value::Object(result))
        }
        "array" => {
            let mut result = Vec::new();
            for (index, item) in body.as_array().expect("validated array").iter().enumerate() {
                result.push(evaluate_at(item, roots, &format!("{path}/array/{index}"), depth + 1)?);
            }
            Ok(Value::Array(result))
        }
        "coalesce" => {
            for (index, operand) in body.as_array().expect("validated coalesce").iter().enumerate()
            {
                match evaluate_at(operand, roots, &format!("{path}/coalesce/{index}"), depth + 1) {
                    Ok(Value::Null) => {}
                    Ok(value) => return Ok(value),
                    Err(error) if error.is_absence() => {}
                    Err(error) => return Err(error),
                }
            }
            Err(ExpressionEvaluationError::new(
                "mapping.coalesce-exhausted",
                &format!("{path}/coalesce"),
                "Every coalesce operand was null or unresolved.",
            ))
        }
        "format" => {
            let template = body["template"].as_str().expect("validated format");
            let values = body["values"].as_object().expect("validated format");
            let mut rendered = String::new();
            for segment in
                template_segments(template, &format!("{path}/format/template"))?
            {
                match segment {
                    TemplateSegment::Text(text) => rendered.push_str(&text),
                    TemplateSegment::Placeholder(name) => {
                        let value_path = format!("{path}/format/values/{}", escape(&name));
                        let value = evaluate_at(
                            values.get(&name).expect("validated placeholder"),
                            roots,
                            &value_path,
                            depth + 1,
                        )?;
                        match value {
                            Value::String(text) => rendered.push_str(&text),
                            Value::Number(number) => rendered.push_str(&number.to_string()),
                            Value::Bool(flag) => {
                                rendered.push_str(if flag { "true" } else { "false" })
                            }
                            Value::Null => {
                                return Err(ExpressionEvaluationError::new(
                                    "mapping.null-value",
                                    &value_path,
                                    format!("The format value `{name}` is null."),
                                ));
                            }
                            Value::Array(_) | Value::Object(_) => {
                                return Err(ExpressionEvaluationError::new(
                                    "mapping.format-value-not-scalar",
                                    &value_path,
                                    format!("The format value `{name}` is not a scalar."),
                                ));
                            }
                        }
                    }
                }
            }
            Ok(Value::String(rendered))
        }
        _ => unreachable!("validated expression"),
    }
}

fn resolve(roots: &ExpressionRoots, root: &str, pointer: &str, path: &str) -> EvaluationResult {
    let Some(mut current) = roots.get(root) else {
        return Err(ExpressionEvaluationError::new(
            "mapping.root-unavailable",
            path,
            format!("The root `{root}` is not available in this context."),
        ));
    };
    if pointer.is_empty() {
        return Ok(current.clone());
    }
    for token in pointer.split('/').skip(1) {
        let token = crate::workflow_match::decode_pointer_token(token).ok_or_else(|| {
            ExpressionEvaluationError::new(
                "mapping.pointer-invalid",
                path,
                "The pointer contains an invalid escape.",
            )
        })?;
        current = match current {
            Value::Object(map) => map.get(&token).ok_or_else(|| {
                ExpressionEvaluationError::new(
                    "mapping.pointer-unresolved",
                    path,
                    "The pointer does not resolve.",
                )
            })?,
            Value::Array(items) => {
                let index = parse_array_index(&token).ok_or_else(|| {
                    ExpressionEvaluationError::new(
                        "mapping.pointer-unresolved",
                        path,
                        "The pointer does not resolve.",
                    )
                })?;
                items.get(index).ok_or_else(|| {
                    ExpressionEvaluationError::new(
                        "mapping.pointer-unresolved",
                        path,
                        "The pointer does not resolve.",
                    )
                })?
            }
            _ => {
                return Err(ExpressionEvaluationError::new(
                    "mapping.pointer-unresolved",
                    path,
                    "The pointer does not resolve.",
                ));
            }
        };
    }
    Ok(current.clone())
}

fn parse_array_index(token: &str) -> Option<usize> {
    if token == "0" {
        return Some(0);
    }
    if token.is_empty() || token.starts_with('0') || !token.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    token.parse().ok()
}

enum TemplateSegment {
    Text(String),
    Placeholder(String),
}

fn template_placeholders(
    template: &str,
    path: &str,
) -> Result<BTreeSet<String>, ExpressionEvaluationError> {
    Ok(template_segments(template, path)?
        .into_iter()
        .filter_map(|segment| match segment {
            TemplateSegment::Placeholder(name) => Some(name),
            TemplateSegment::Text(_) => None,
        })
        .collect())
}

/// Parses `{name}` placeholders. `{{` and `}}` escape literal braces. Any
/// other bare brace, an empty name, or an unterminated placeholder fails.
fn template_segments(
    template: &str,
    path: &str,
) -> Result<Vec<TemplateSegment>, ExpressionEvaluationError> {
    let invalid = |message: &str| {
        ExpressionEvaluationError::new("mapping.template-invalid", path, message.to_owned())
    };
    let mut segments = Vec::new();
    let mut text = String::new();
    let mut characters = template.chars().peekable();
    while let Some(character) = characters.next() {
        match character {
            '{' if characters.peek() == Some(&'{') => {
                characters.next();
                text.push('{');
            }
            '}' if characters.peek() == Some(&'}') => {
                characters.next();
                text.push('}');
            }
            '{' => {
                let mut name = String::new();
                loop {
                    match characters.next() {
                        Some('}') => break,
                        Some('{') => return Err(invalid("Placeholders cannot nest.")),
                        Some(inner) => name.push(inner),
                        None => return Err(invalid("A placeholder is unterminated.")),
                    }
                }
                if name.is_empty() {
                    return Err(invalid("A placeholder name is empty."));
                }
                if !text.is_empty() {
                    segments.push(TemplateSegment::Text(std::mem::take(&mut text)));
                }
                segments.push(TemplateSegment::Placeholder(name));
            }
            '}' => return Err(invalid("A closing brace has no opening brace.")),
            _ => text.push(character),
        }
    }
    if !text.is_empty() {
        segments.push(TemplateSegment::Text(text));
    }
    Ok(segments)
}

fn escape(token: &str) -> String {
    token.replace('~', "~0").replace('/', "~1")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn roots() -> ExpressionRoots {
        ExpressionRoots::with_input(json!({
            "subject": "Invoice 42",
            "amount": 1280.5,
            "flags": {"urgent": true, "spam/like": false},
            "recipients": ["kay@example.com", "justin@example.com"],
            "missing": null
        }))
    }

    #[test]
    fn whole_returns_the_input() {
        assert_eq!(
            evaluate(&json!({"whole": true}), &roots()).expect("whole")["subject"],
            "Invoice 42"
        );
    }

    #[test]
    fn select_resolves_pointers_including_escapes_and_indices() {
        let select = |pointer: &str| {
            evaluate(
                &json!({"select": {"root": "input", "pointer": pointer}}),
                &roots(),
            )
        };
        assert_eq!(select("/subject").expect("string"), json!("Invoice 42"));
        assert_eq!(select("/flags/spam~1like").expect("escape"), json!(false));
        assert_eq!(select("/recipients/1").expect("index"), json!("justin@example.com"));
        assert_eq!(select("").expect("empty pointer")["amount"], json!(1280.5));
        assert_eq!(
            select("/recipients/01").expect_err("leading zero").code,
            "mapping.pointer-unresolved"
        );
        assert_eq!(
            select("/absent").expect_err("absent").code,
            "mapping.pointer-unresolved"
        );
    }

    #[test]
    fn select_rejects_unavailable_roots() {
        let error = evaluate(
            &json!({"select": {"root": "case", "pointer": "/anything"}}),
            &roots(),
        )
        .expect_err("root");
        assert_eq!(error.code, "mapping.root-unavailable");
    }

    #[test]
    fn literals_pass_through_typed_values() {
        assert_eq!(
            evaluate(&json!({"literal": {"type": "number", "value": 7}}), &roots()).expect("number"),
            json!(7)
        );
        assert_eq!(
            evaluate(
                &json!({"literal": {"type": "json", "value": {"nested": [1, 2]}}}),
                &roots()
            )
            .expect("json"),
            json!({"nested": [1, 2]})
        );
        let error = evaluate(
            &json!({"literal": {"type": "number", "value": "seven"}}),
            &roots(),
        )
        .expect_err("mismatch");
        assert_eq!(error.code, "mapping.malformed");
    }

    #[test]
    fn compose_and_format_expressions_evaluate() {
        let cases: Vec<(Value, Value)> = vec![
            (
                json!({"object": {
                    "title": {"select": {"root": "input", "pointer": "/subject"}},
                    "pair": {"array": [
                        {"literal": {"type": "string", "value": "fixed"}},
                        {"select": {"root": "input", "pointer": "/amount"}}
                    ]}
                }}),
                json!({"title": "Invoice 42", "pair": ["fixed", 1280.5]}),
            ),
            (
                json!({"format": {
                    "template": "{subject} costs {amount} {{unformatted}} urgent={urgent}",
                    "values": {
                        "subject": {"select": {"root": "input", "pointer": "/subject"}},
                        "amount": {"select": {"root": "input", "pointer": "/amount"}},
                        "urgent": {"select": {"root": "input", "pointer": "/flags/urgent"}}
                    }
                }}),
                json!("Invoice 42 costs 1280.5 {unformatted} urgent=true"),
            ),
        ];
        for (expression, expected) in cases {
            assert_eq!(evaluate(&expression, &roots()).expect("evaluate"), expected);
        }
    }

    #[test]
    fn coalesce_skips_null_and_unresolved_then_exhausts() {
        let result = evaluate(
            &json!({"coalesce": [
                {"select": {"root": "input", "pointer": "/missing"}},
                {"select": {"root": "input", "pointer": "/absent"}},
                {"select": {"root": "input", "pointer": "/subject"}}
            ]}),
            &roots(),
        )
        .expect("coalesce");
        assert_eq!(result, json!("Invoice 42"));
        let exhausted = evaluate(
            &json!({"coalesce": [
                {"select": {"root": "input", "pointer": "/missing"}},
                {"literal": {"type": "null", "value": null}}
            ]}),
            &roots(),
        )
        .expect_err("exhausted");
        assert_eq!(exhausted.code, "mapping.coalesce-exhausted");
    }

    #[test]
    fn coalesce_surfaces_structural_failures() {
        let error = evaluate(
            &json!({"coalesce": [
                {"select": {"root": "case", "pointer": "/anything"}},
                {"literal": {"type": "string", "value": "fallback"}}
            ]}),
            &roots(),
        )
        .expect_err("structural");
        assert_eq!(error.code, "mapping.root-unavailable");
    }

    #[test]
    fn format_fails_closed_on_missing_null_and_non_scalar_values() {
        let missing = evaluate(
            &json!({"format": {"template": "{absent}", "values": {}}}),
            &roots(),
        )
        .expect_err("missing");
        assert_eq!(missing.code, "mapping.format-value-missing");
        let null = evaluate(
            &json!({"format": {
                "template": "{gone}",
                "values": {"gone": {"select": {"root": "input", "pointer": "/missing"}}}
            }}),
            &roots(),
        )
        .expect_err("null");
        assert_eq!(null.code, "mapping.null-value");
        let non_scalar = evaluate(
            &json!({"format": {
                "template": "{flags}",
                "values": {"flags": {"select": {"root": "input", "pointer": "/flags"}}}
            }}),
            &roots(),
        )
        .expect_err("non-scalar");
        assert_eq!(non_scalar.code, "mapping.format-value-not-scalar");
    }

    #[test]
    fn template_brace_errors_fail_closed() {
        for template in ["{unterminated", "{}", "stray}", "{a{b}}"] {
            let error = evaluate(
                &json!({"format": {"template": template, "values": {"a": {"whole": true}, "b": {"whole": true}}}}),
                &roots(),
            )
            .expect_err(template);
            assert_eq!(error.code, "mapping.template-invalid", "{template}");
        }
    }

    #[test]
    fn bounds_and_depth_fail_closed() {
        let too_many_items = json!({"array": (0..129).map(|_| json!({"whole": true})).collect::<Vec<_>>()});
        assert_eq!(
            evaluate(&too_many_items, &roots()).expect_err("items").code,
            "mapping.bounds-exceeded"
        );
        let mut nested = json!({"whole": true});
        for _ in 0..65 {
            nested = json!({"array": [nested]});
        }
        assert_eq!(
            evaluate(&nested, &roots()).expect_err("depth").code,
            "mapping.depth-exceeded"
        );
        let single_coalesce = json!({"coalesce": [{"whole": true}]});
        assert_eq!(
            evaluate(&single_coalesce, &roots()).expect_err("operands").code,
            "mapping.bounds-exceeded"
        );
    }

    #[test]
    fn oversized_results_fail_closed() {
        let big = "x".repeat(8000);
        let expression = json!({"array": (0..5).map(|_| json!({"literal": {"type": "string", "value": big}})).collect::<Vec<_>>()});
        assert_eq!(
            evaluate(&expression, &roots()).expect_err("size").code,
            "mapping.result-too-large"
        );
    }

    #[test]
    fn malformed_expressions_fail_closed() {
        for expression in [
            json!("whole"),
            json!({}),
            json!({"whole": false}),
            json!({"whole": true, "select": {"root": "input", "pointer": ""}}),
            json!({"select": {"root": "input"}}),
            json!({"select": {"root": "input", "pointer": "no-slash"}}),
            json!({"unknown": true}),
        ] {
            assert!(
                matches!(
                    evaluate(&expression, &roots()).expect_err("malformed").code.as_str(),
                    "mapping.malformed" | "mapping.pointer-invalid"
                ),
                "{expression}"
            );
        }
    }

    #[test]
    fn executable_mapping_gates_roots_and_shape() {
        assert!(executable_mapping(&json!({"whole": true})));
        assert!(executable_mapping(&json!({"object": {
            "a": {"select": {"root": "input", "pointer": "/subject"}}
        }})));
        assert!(!executable_mapping(&json!({"select": {"root": "case", "pointer": "/x"}})));
        assert!(!executable_mapping(&json!({"select": {"root": "workflow", "pointer": ""}})));
        assert!(!executable_mapping(&json!({"unknown": true})));
    }

    #[test]
    fn evaluation_is_deterministic() {
        let expression = json!({"object": {
            "z": {"whole": true},
            "a": {"format": {"template": "{s}", "values": {"s": {"select": {"root": "input", "pointer": "/subject"}}}}}
        }});
        let first = serde_json::to_vec(&evaluate(&expression, &roots()).expect("first")).expect("encode");
        let second = serde_json::to_vec(&evaluate(&expression, &roots()).expect("second")).expect("encode");
        assert_eq!(first, second);
    }
}
