use kaname_core::workflow_match::{
    EvaluationOutcome, MatchConfig, MatchRoots, ResolutionState, TraceOutcome, evaluate,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{fs, path::Path};

const CASE_A: &str = "018f2000-0001-7000-8000-000000000001";
const CASE_B: &str = "018f2000-0002-7000-8000-000000000002";
const CASE_C: &str = "018f2000-0003-7000-8000-000000000003";
const OTHERWISE: &str = "018f2000-0004-7000-8000-000000000004";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MatchGoldenCorpus {
    fixture_version: u32,
    privacy_class: String,
    goldens: Vec<MatchGolden>,
}

#[derive(Deserialize)]
struct MatchGolden {
    id: String,
    config: Value,
    roots: Value,
    expected: Value,
}

fn reference(root: &str, pointer: &str) -> Value {
    json!({"root": root, "pointer": pointer})
}

fn literal(value_type: &str, value: Value) -> Value {
    json!({"literal": {"type": value_type, "value": value}})
}

fn comparison(pointer: &str, operator: &str, value_type: &str, value: Value) -> Value {
    json!({
        "compare": {
            "left": reference("value", pointer),
            "operator": operator,
            "right": literal(value_type, value)
        }
    })
}

fn case(id: &str, key: &str, when: Value) -> Value {
    json!({"id": id, "key": key, "label": key, "when": when})
}

fn config(hit_policy: &str, cases: Vec<Value>, otherwise: bool) -> MatchConfig {
    serde_json::from_value(json!({
        "value": reference("input", ""),
        "hitPolicy": hit_policy,
        "cases": cases,
        "otherwise": otherwise.then(|| json!({
            "id": OTHERWISE,
            "key": "otherwise",
            "label": "Otherwise"
        }))
    }))
    .unwrap()
}

fn evaluate_input(
    config: &MatchConfig,
    input: Value,
) -> kaname_core::workflow_match::MatchEvaluation {
    evaluate(config, &MatchRoots::with_input(input))
}

#[test]
fn optional_nested_paths_keep_present_null_absent_and_wrong_type_distinct() {
    let present = config(
        "first",
        vec![case(
            CASE_A,
            "jp",
            comparison("/customer/address/country", "equal", "string", json!("JP")),
        )],
        true,
    );
    let result = evaluate_input(
        &present,
        json!({"customer": {"address": {"country": "JP"}}}),
    );
    assert_eq!(result.outcome, EvaluationOutcome::Matched);
    assert_eq!(result.selected_case_ids, [CASE_A]);
    assert_eq!(
        result.cases[0].condition.operands[0].state,
        ResolutionState::Present
    );

    let null = config(
        "first",
        vec![case(
            CASE_A,
            "null",
            json!({"isNull": reference("value", "/customer/address")}),
        )],
        true,
    );
    let result = evaluate_input(&null, json!({"customer": {"address": null}}));
    assert_eq!(result.outcome, EvaluationOutcome::Matched);
    assert_eq!(
        result.cases[0].condition.operands[0]
            .value_type
            .unwrap()
            .to_string(),
        "null"
    );

    let missing = config(
        "first",
        vec![case(
            CASE_A,
            "missing",
            json!({"missing": reference("value", "/customer/address")}),
        )],
        true,
    );
    let result = evaluate_input(&missing, json!({"customer": {}}));
    assert_eq!(result.outcome, EvaluationOutcome::Matched);
    assert_eq!(
        result.cases[0].condition.operands[0].state,
        ResolutionState::Absent
    );

    let wrong_type = config(
        "first",
        vec![case(
            CASE_A,
            "jp",
            comparison("/customer/address/country", "equal", "string", json!("JP")),
        )],
        true,
    );
    let result = evaluate_input(
        &wrong_type,
        json!({"customer": {"address": "not-an-object"}}),
    );
    assert_eq!(result.outcome, EvaluationOutcome::EvaluationError);
    assert!(!result.otherwise.unwrap().selected);
    assert_eq!(result.error.unwrap().code, "MATCH_PATH_WRONG_TYPE");
    assert_eq!(
        result.cases[0].condition.operands[0].state,
        ResolutionState::EvaluationError
    );
}

#[test]
fn typed_operators_cover_numbers_strings_membership_patterns_and_structures() {
    let predicates = [
        (
            comparison("/score", "greaterThanOrEqual", "number", json!(8)),
            json!({"score": 9}),
        ),
        (
            comparison("/name", "startsWith", "string", json!("Kana")),
            json!({"name": "Kaname"}),
        ),
        (
            comparison("/name", "endsWith", "string", json!("ame")),
            json!({"name": "Kaname"}),
        ),
        (
            comparison("/name", "contains", "string", json!("nam")),
            json!({"name": "Kaname"}),
        ),
        (
            comparison(
                "/name",
                "matchesSafePattern",
                "string",
                json!("^Kana[a-z]+$"),
            ),
            json!({"name": "Kaname"}),
        ),
        (
            comparison("/labels", "contains", "string", json!("review")),
            json!({"labels": ["review", "safe"]}),
        ),
        (
            json!({"compare": {
                "left": reference("value", "/state"),
                "operator": "in",
                "right": literal("json", json!(["ready", "waiting"]))
            }}),
            json!({"state": "ready"}),
        ),
        (
            comparison("/object", "equal", "json", json!({"ready": true})),
            json!({"object": {"ready": true}}),
        ),
    ];
    for (predicate, input) in predicates {
        let result = evaluate_input(
            &config("first", vec![case(CASE_A, "match", predicate)], false),
            input,
        );
        assert_eq!(result.outcome, EvaluationOutcome::Matched);
    }

    let mismatch = evaluate_input(
        &config(
            "first",
            vec![case(
                CASE_A,
                "bad",
                comparison("/score", "startsWith", "string", json!("8")),
            )],
            true,
        ),
        json!({"score": 8}),
    );
    assert_eq!(mismatch.outcome, EvaluationOutcome::EvaluationError);
    assert_eq!(mismatch.error.unwrap().code, "MATCH_OPERATOR_TYPE_MISMATCH");

    let invalid_pattern = evaluate_input(
        &config(
            "first",
            vec![case(
                CASE_A,
                "bad-pattern",
                comparison("/name", "matchesSafePattern", "string", json!("[")),
            )],
            false,
        ),
        json!({"name": "Kaname"}),
    );
    assert_eq!(invalid_pattern.error.unwrap().code, "MATCH_PATTERN_INVALID");
}

#[test]
fn boolean_groups_and_array_quantifiers_are_bounded_and_explain_short_circuiting() {
    let compound = json!({
        "all": [
            comparison("/score", "greaterThan", "number", json!(5)),
            {"any": [
                comparison("/region", "equal", "string", json!("APAC")),
                comparison("/region", "equal", "string", json!("EMEA"))
            ]},
            {"not": comparison("/manualOverride", "equal", "boolean", json!(true))}
        ]
    });
    let result = evaluate_input(
        &config("first", vec![case(CASE_A, "priority", compound)], false),
        json!({"score": 9, "region": "APAC", "manualOverride": false}),
    );
    assert_eq!(result.outcome, EvaluationOutcome::Matched);
    let any = &result.cases[0].condition.children[1];
    assert!(any.short_circuited);
    assert_eq!(any.children[1].outcome, TraceOutcome::NotEvaluated);

    let quantifiers = [
        ("arrayAny", "greaterThan", 1),
        ("arrayAll", "greaterThan", 0),
        ("arrayNone", "lessThan", 0),
        ("arrayExactlyOne", "equal", 1),
    ]
    .into_iter()
    .enumerate()
    .map(|(index, (quantifier, operator, right))| {
        case(
            [CASE_A, CASE_B, CASE_C, OTHERWISE][index],
            quantifier,
            json!({quantifier: {
                "value": reference("value", "/items"),
                "as": "item",
                "where": {"compare": {
                    "left": reference("item", ""),
                    "operator": operator,
                    "right": literal("number", json!(right))
                }}
            }}),
        )
    })
    .collect();
    let result = evaluate_input(
        &config("all", quantifiers, false),
        json!({"items": [1, 2, 2, 3]}),
    );
    assert_eq!(result.outcome, EvaluationOutcome::Matched);
    assert_eq!(result.selected_case_ids.len(), 4);
    assert!(
        result
            .cases
            .iter()
            .any(|trace| trace.condition.short_circuited)
    );
}

#[test]
fn first_unique_all_and_otherwise_have_non_overlapping_failure_semantics() {
    let matching_cases = || {
        vec![
            case(
                CASE_A,
                "one",
                json!({"isType": {"value": reference("value", ""), "type": "object"}}),
            ),
            case(
                CASE_B,
                "two",
                json!({"exists": reference("value", "/ready")}),
            ),
        ]
    };
    let input = json!({"ready": true});

    let first = evaluate_input(&config("first", matching_cases(), true), input.clone());
    assert_eq!(first.selected_case_ids, [CASE_A]);
    assert_eq!(first.cases[1].outcome, TraceOutcome::NotEvaluated);

    let unique = evaluate_input(&config("unique", matching_cases(), true), input.clone());
    assert_eq!(unique.outcome, EvaluationOutcome::EvaluationError);
    assert_eq!(unique.error.unwrap().code, "MATCH_UNIQUE_MULTIPLE");
    assert!(!unique.otherwise.unwrap().selected);

    let all = evaluate_input(&config("all", matching_cases(), true), input);
    assert_eq!(all.selected_case_ids, [CASE_A, CASE_B]);

    let otherwise = evaluate_input(
        &config(
            "first",
            vec![case(
                CASE_A,
                "no",
                comparison("/ready", "equal", "boolean", json!(true)),
            )],
            true,
        ),
        json!({"ready": false}),
    );
    assert_eq!(otherwise.outcome, EvaluationOutcome::Matched);
    assert_eq!(otherwise.selected_case_ids, [OTHERWISE]);
    assert!(otherwise.otherwise.unwrap().selected);

    let no_route = evaluate_input(
        &config(
            "first",
            vec![case(
                CASE_A,
                "no",
                comparison("/ready", "equal", "boolean", json!(true)),
            )],
            false,
        ),
        json!({"ready": false}),
    );
    assert_eq!(no_route.outcome, EvaluationOutcome::NotMatched);
}

#[test]
fn truth_tables_and_json_types_hold_across_generated_values() {
    let values = [
        json!(null),
        json!(false),
        json!(0),
        json!(""),
        json!([]),
        json!({}),
    ];
    let types = ["null", "boolean", "number", "string", "array", "object"];
    for (value_index, value) in values.iter().enumerate() {
        for (type_index, expected_type) in types.iter().enumerate() {
            let result = evaluate_input(
                &config(
                    "first",
                    vec![case(
                        CASE_A,
                        "type",
                        json!({
                            "isType": {"value": reference("value", ""), "type": expected_type}
                        }),
                    )],
                    false,
                ),
                value.clone(),
            );
            assert_eq!(
                result.outcome == EvaluationOutcome::Matched,
                value_index == type_index
            );
        }
    }

    for left in [false, true] {
        for right in [false, true] {
            let all = json!({"all": [
                comparison("/left", "equal", "boolean", json!(true)),
                comparison("/right", "equal", "boolean", json!(true))
            ]});
            let any = json!({"any": [
                comparison("/left", "equal", "boolean", json!(true)),
                comparison("/right", "equal", "boolean", json!(true))
            ]});
            for (condition, expected) in [(all, left && right), (any, left || right)] {
                let result = evaluate_input(
                    &config("first", vec![case(CASE_A, "boolean", condition)], false),
                    json!({"left": left, "right": right}),
                );
                assert_eq!(result.outcome == EvaluationOutcome::Matched, expected);
            }
        }
    }
}

#[test]
fn committed_match_trace_goldens_are_exact_and_redaction_safe() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Fixtures/workflow-v2/match-evaluator-v1.json");
    let corpus: MatchGoldenCorpus = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    assert_eq!(corpus.fixture_version, 1);
    assert_eq!(corpus.privacy_class, "synthetic-public");
    assert_eq!(corpus.goldens.len(), 4);
    for golden in corpus.goldens {
        let config: MatchConfig = serde_json::from_value(golden.config).unwrap();
        let roots = golden
            .roots
            .as_object()
            .unwrap()
            .iter()
            .fold(MatchRoots::default(), |roots, (key, value)| {
                roots.with_root(key, value.clone())
            });
        let actual = serde_json::to_value(evaluate(&config, &roots)).unwrap();
        assert_eq!(actual, golden.expected, "{}", golden.id);
        let serialized = actual.to_string();
        assert!(!serialized.contains("private-value"));
        assert!(!serialized.contains("not-an-object"));
    }
}

trait JsonTypeName {
    fn to_string(self) -> &'static str;
}

impl JsonTypeName for kaname_core::workflow_match::JsonType {
    fn to_string(self) -> &'static str {
        match self {
            Self::Null => "null",
            Self::Boolean => "boolean",
            Self::Number => "number",
            Self::String => "string",
            Self::Array => "array",
            Self::Object => "object",
        }
    }
}
