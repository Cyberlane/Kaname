use regex::RegexBuilder;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{cmp::Ordering, collections::BTreeMap};

const MAXIMUM_CONDITION_EVALUATIONS: usize = 4_096;
const MAXIMUM_CONDITION_DEPTH: usize = 64;
const MAXIMUM_ARRAY_ITEMS: usize = 4_096;
const MAXIMUM_PATTERN_BYTES: usize = 1_024;
const MAXIMUM_REGEX_BYTES: usize = 1 << 20;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct MatchConfig {
    pub value: ValueReference,
    pub hit_policy: HitPolicy,
    pub cases: Vec<MatchCase>,
    pub otherwise: Option<CasePort>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum HitPolicy {
    First,
    Unique,
    All,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MatchCase {
    pub id: String,
    pub key: String,
    pub label: String,
    pub when: Condition,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CasePort {
    pub id: String,
    pub key: String,
    pub label: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ValueReference {
    pub root: String,
    pub pointer: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Operand {
    Reference(ValueReference),
    Literal { literal: TypedLiteral },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TypedLiteral {
    #[serde(rename = "type")]
    pub value_type: LiteralType,
    pub value: Value,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LiteralType {
    String,
    Number,
    Boolean,
    Null,
    Json,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Condition {
    All {
        all: Vec<Condition>,
    },
    Any {
        any: Vec<Condition>,
    },
    Not {
        not: Box<Condition>,
    },
    Compare {
        compare: Comparison,
    },
    Exists {
        exists: ValueReference,
    },
    Missing {
        missing: ValueReference,
    },
    IsNull {
        #[serde(rename = "isNull")]
        is_null: ValueReference,
    },
    IsType {
        #[serde(rename = "isType")]
        is_type: TypeCondition,
    },
    ArrayAny {
        #[serde(rename = "arrayAny")]
        array_any: ArrayCondition,
    },
    ArrayAll {
        #[serde(rename = "arrayAll")]
        array_all: ArrayCondition,
    },
    ArrayNone {
        #[serde(rename = "arrayNone")]
        array_none: ArrayCondition,
    },
    ArrayExactlyOne {
        #[serde(rename = "arrayExactlyOne")]
        array_exactly_one: ArrayCondition,
    },
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Comparison {
    pub left: Operand,
    pub operator: ComparisonOperator,
    pub right: Operand,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ComparisonOperator {
    Equal,
    NotEqual,
    LessThan,
    LessThanOrEqual,
    GreaterThan,
    GreaterThanOrEqual,
    Contains,
    StartsWith,
    EndsWith,
    MatchesSafePattern,
    In,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TypeCondition {
    pub value: ValueReference,
    #[serde(rename = "type")]
    pub expected_type: JsonType,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArrayCondition {
    pub value: ValueReference,
    pub r#as: ItemBinding,
    pub r#where: Box<Condition>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub enum ItemBinding {
    #[serde(rename = "item")]
    Item,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum JsonType {
    Null,
    Boolean,
    Number,
    String,
    Array,
    Object,
}

#[derive(Debug, Clone, Default)]
pub struct MatchRoots {
    values: BTreeMap<String, Value>,
}

impl MatchRoots {
    pub fn with_input(input: Value) -> Self {
        Self::default().with_root("input", input)
    }

    pub fn with_root(mut self, root: impl Into<String>, value: Value) -> Self {
        self.values.insert(root.into(), value);
        self
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MatchEvaluation {
    pub trace_version: u32,
    pub outcome: EvaluationOutcome,
    pub hit_policy: HitPolicy,
    pub input: OperandTrace,
    pub selected_case_ids: Vec<String>,
    pub emitted_port_ids: Vec<String>,
    pub cases: Vec<CaseTrace>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub otherwise: Option<OtherwiseTrace>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<EvaluationError>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum EvaluationOutcome {
    Matched,
    NotMatched,
    EvaluationError,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum TraceOutcome {
    Matched,
    NotMatched,
    EvaluationError,
    NotEvaluated,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CaseTrace {
    pub case_id: String,
    pub key: String,
    pub outcome: TraceOutcome,
    pub condition: ConditionTrace,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OtherwiseTrace {
    pub case_id: String,
    pub key: String,
    pub selected: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConditionTrace {
    pub expression_id: String,
    pub kind: String,
    pub outcome: TraceOutcome,
    pub short_circuited: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operator: Option<ComparisonOperator>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub iteration_index: Option<usize>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub operands: Vec<OperandTrace>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<ConditionTrace>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<EvaluationError>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OperandTrace {
    pub source: String,
    pub state: ResolutionState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value_type: Option<JsonType>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ResolutionState {
    Present,
    Absent,
    EvaluationError,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EvaluationError {
    pub code: String,
    pub expression_id: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encountered_type: Option<JsonType>,
}

enum Resolved<'a> {
    Present(&'a Value),
    Absent,
}

struct Evaluator {
    roots: BTreeMap<String, Value>,
    evaluations: usize,
}

struct ConditionResult {
    matched: bool,
    trace: ConditionTrace,
}

pub fn evaluate(config: &MatchConfig, roots: &MatchRoots) -> MatchEvaluation {
    let mut evaluator = Evaluator {
        roots: roots.values.clone(),
        evaluations: 0,
    };
    let input_resolution = evaluator.resolve(&config.value, "/value");
    let input_trace = operand_trace(&config.value, &input_resolution);
    let input = match input_resolution {
        Ok(Resolved::Present(value)) => value.clone(),
        Ok(Resolved::Absent) => {
            return terminal_error(
                config.hit_policy,
                input_trace,
                Vec::new(),
                error("MATCH_INPUT_ABSENT", "/value", "Match input is absent."),
                config.otherwise.as_ref(),
            );
        }
        Err(error) => {
            return terminal_error(
                config.hit_policy,
                input_trace,
                Vec::new(),
                error,
                config.otherwise.as_ref(),
            );
        }
    };
    evaluator.roots.insert("value".into(), input);

    let mut case_traces = Vec::with_capacity(config.cases.len());
    let mut selected = Vec::new();
    for (index, case) in config.cases.iter().enumerate() {
        if config.hit_policy == HitPolicy::First && !selected.is_empty() {
            case_traces.push(CaseTrace {
                case_id: case.id.clone(),
                key: case.key.clone(),
                outcome: TraceOutcome::NotEvaluated,
                condition: skipped_trace(&case.when, &format!("/cases/{index}/when"), None),
            });
            continue;
        }
        evaluator.roots.insert(
            "case".into(),
            serde_json::json!({
                "id": case.id,
                "key": case.key,
                "label": case.label
            }),
        );
        let expression_id = format!("/cases/{index}/when");
        match evaluator.evaluate_condition(&case.when, &expression_id, 0, None) {
            Ok(result) => {
                let outcome = if result.matched {
                    selected.push((case.id.clone(), format!("case-{}", case.id)));
                    TraceOutcome::Matched
                } else {
                    TraceOutcome::NotMatched
                };
                case_traces.push(CaseTrace {
                    case_id: case.id.clone(),
                    key: case.key.clone(),
                    outcome,
                    condition: result.trace,
                });
            }
            Err((error, trace)) => {
                case_traces.push(CaseTrace {
                    case_id: case.id.clone(),
                    key: case.key.clone(),
                    outcome: TraceOutcome::EvaluationError,
                    condition: trace,
                });
                return terminal_error(
                    config.hit_policy,
                    input_trace,
                    case_traces,
                    error,
                    config.otherwise.as_ref(),
                );
            }
        }
    }

    if config.hit_policy == HitPolicy::Unique && selected.len() > 1 {
        return terminal_error(
            config.hit_policy,
            input_trace,
            case_traces,
            error(
                "MATCH_UNIQUE_MULTIPLE",
                "/hitPolicy",
                "Exactly-one Match selected more than one case.",
            ),
            config.otherwise.as_ref(),
        );
    }

    if selected.is_empty() {
        if let Some(otherwise) = &config.otherwise {
            return MatchEvaluation {
                trace_version: 1,
                outcome: EvaluationOutcome::Matched,
                hit_policy: config.hit_policy,
                input: input_trace,
                selected_case_ids: vec![otherwise.id.clone()],
                emitted_port_ids: vec![format!("case-{}", otherwise.id)],
                cases: case_traces,
                otherwise: Some(OtherwiseTrace {
                    case_id: otherwise.id.clone(),
                    key: otherwise.key.clone(),
                    selected: true,
                }),
                error: None,
            };
        }
        return MatchEvaluation {
            trace_version: 1,
            outcome: EvaluationOutcome::NotMatched,
            hit_policy: config.hit_policy,
            input: input_trace,
            selected_case_ids: Vec::new(),
            emitted_port_ids: Vec::new(),
            cases: case_traces,
            otherwise: None,
            error: None,
        };
    }

    MatchEvaluation {
        trace_version: 1,
        outcome: EvaluationOutcome::Matched,
        hit_policy: config.hit_policy,
        input: input_trace,
        selected_case_ids: selected.iter().map(|(id, _)| id.clone()).collect(),
        emitted_port_ids: selected.into_iter().map(|(_, port)| port).collect(),
        cases: case_traces,
        otherwise: config.otherwise.as_ref().map(|otherwise| OtherwiseTrace {
            case_id: otherwise.id.clone(),
            key: otherwise.key.clone(),
            selected: false,
        }),
        error: None,
    }
}

// A failure deliberately carries the partial explanation tree so the inspector
// can show exactly where evaluation stopped. Keeping it inline avoids a second
// representation of the recursive trace contract.
#[allow(clippy::result_large_err)]
impl Evaluator {
    fn evaluate_condition(
        &mut self,
        condition: &Condition,
        expression_id: &str,
        depth: usize,
        iteration_index: Option<usize>,
    ) -> Result<ConditionResult, (EvaluationError, ConditionTrace)> {
        self.evaluations += 1;
        if self.evaluations > MAXIMUM_CONDITION_EVALUATIONS || depth > MAXIMUM_CONDITION_DEPTH {
            let error = error(
                "MATCH_LIMIT_EXCEEDED",
                expression_id,
                "Match condition evaluation exceeded its deterministic limit.",
            );
            return Err((error.clone(), error_trace(condition, expression_id, error)));
        }
        match condition {
            Condition::All { all } => {
                self.evaluate_group("all", all, expression_id, depth, iteration_index, false)
            }
            Condition::Any { any } => {
                self.evaluate_group("any", any, expression_id, depth, iteration_index, true)
            }
            Condition::Not { not } => {
                let child_id = format!("{expression_id}/not");
                match self.evaluate_condition(not, &child_id, depth + 1, iteration_index) {
                    Ok(child) => Ok(ConditionResult {
                        matched: !child.matched,
                        trace: trace(
                            expression_id,
                            "not",
                            !child.matched,
                            iteration_index,
                            Vec::new(),
                            vec![child.trace],
                        ),
                    }),
                    Err((error, child)) => Err((
                        error.clone(),
                        ConditionTrace {
                            expression_id: expression_id.into(),
                            kind: "not".into(),
                            outcome: TraceOutcome::EvaluationError,
                            short_circuited: false,
                            operator: None,
                            iteration_index,
                            operands: Vec::new(),
                            children: vec![child],
                            error: Some(error),
                        },
                    )),
                }
            }
            Condition::Compare { compare } => {
                self.evaluate_comparison(compare, expression_id, iteration_index)
            }
            Condition::Exists { exists } => {
                self.evaluate_presence("exists", exists, expression_id, iteration_index, false)
            }
            Condition::Missing { missing } => {
                self.evaluate_presence("missing", missing, expression_id, iteration_index, true)
            }
            Condition::IsNull { is_null } => {
                let resolution = self.resolve(is_null, expression_id);
                self.resolution_predicate(
                    "isNull",
                    is_null,
                    resolution,
                    expression_id,
                    iteration_index,
                    |value| value.is_null(),
                )
            }
            Condition::IsType { is_type } => {
                let resolution = self.resolve(&is_type.value, expression_id);
                self.resolution_predicate(
                    "isType",
                    &is_type.value,
                    resolution,
                    expression_id,
                    iteration_index,
                    |value| json_type(value) == is_type.expected_type,
                )
            }
            Condition::ArrayAny { array_any } => self.evaluate_array(
                "arrayAny",
                array_any,
                expression_id,
                depth,
                iteration_index,
                ArrayMode::Any,
            ),
            Condition::ArrayAll { array_all } => self.evaluate_array(
                "arrayAll",
                array_all,
                expression_id,
                depth,
                iteration_index,
                ArrayMode::All,
            ),
            Condition::ArrayNone { array_none } => self.evaluate_array(
                "arrayNone",
                array_none,
                expression_id,
                depth,
                iteration_index,
                ArrayMode::None,
            ),
            Condition::ArrayExactlyOne { array_exactly_one } => self.evaluate_array(
                "arrayExactlyOne",
                array_exactly_one,
                expression_id,
                depth,
                iteration_index,
                ArrayMode::ExactlyOne,
            ),
        }
    }

    fn evaluate_group(
        &mut self,
        kind: &str,
        conditions: &[Condition],
        expression_id: &str,
        depth: usize,
        iteration_index: Option<usize>,
        match_on: bool,
    ) -> Result<ConditionResult, (EvaluationError, ConditionTrace)> {
        let mut children = Vec::with_capacity(conditions.len());
        let mut result = !match_on;
        let mut stopped = false;
        for (index, condition) in conditions.iter().enumerate() {
            let child_id = format!("{expression_id}/{kind}/{index}");
            if stopped {
                children.push(skipped_trace(condition, &child_id, iteration_index));
                continue;
            }
            match self.evaluate_condition(condition, &child_id, depth + 1, iteration_index) {
                Ok(child) => {
                    result = child.matched;
                    children.push(child.trace);
                    if result == match_on {
                        stopped = true;
                    }
                }
                Err((error, child)) => {
                    children.push(child);
                    return Err((
                        error.clone(),
                        ConditionTrace {
                            expression_id: expression_id.into(),
                            kind: kind.into(),
                            outcome: TraceOutcome::EvaluationError,
                            short_circuited: false,
                            operator: None,
                            iteration_index,
                            operands: Vec::new(),
                            children,
                            error: Some(error),
                        },
                    ));
                }
            }
        }
        let short_circuited = children
            .iter()
            .any(|child| child.outcome == TraceOutcome::NotEvaluated);
        Ok(ConditionResult {
            matched: result,
            trace: ConditionTrace {
                expression_id: expression_id.into(),
                kind: kind.into(),
                outcome: outcome(result),
                short_circuited,
                operator: None,
                iteration_index,
                operands: Vec::new(),
                children,
                error: None,
            },
        })
    }

    fn evaluate_comparison(
        &self,
        comparison: &Comparison,
        expression_id: &str,
        iteration_index: Option<usize>,
    ) -> Result<ConditionResult, (EvaluationError, ConditionTrace)> {
        let left = self.resolve_operand(&comparison.left, expression_id);
        let right = self.resolve_operand(&comparison.right, expression_id);
        let operands = vec![
            operand_trace_for_operand(&comparison.left, &left),
            operand_trace_for_operand(&comparison.right, &right),
        ];
        let values = match (left, right) {
            (Ok(Resolved::Present(left)), Ok(Resolved::Present(right))) => (left, right),
            (Ok(Resolved::Absent), _) | (_, Ok(Resolved::Absent)) => {
                return Ok(comparison_result(
                    expression_id,
                    comparison.operator,
                    false,
                    iteration_index,
                    operands,
                ));
            }
            (Err(error), _) | (_, Err(error)) => {
                return Err((
                    error.clone(),
                    comparison_error_trace(
                        expression_id,
                        comparison.operator,
                        iteration_index,
                        operands,
                        error,
                    ),
                ));
            }
        };
        match compare(values.0, comparison.operator, values.1, expression_id) {
            Ok(matched) => Ok(comparison_result(
                expression_id,
                comparison.operator,
                matched,
                iteration_index,
                operands,
            )),
            Err(error) => Err((
                error.clone(),
                comparison_error_trace(
                    expression_id,
                    comparison.operator,
                    iteration_index,
                    operands,
                    error,
                ),
            )),
        }
    }

    fn evaluate_presence(
        &self,
        kind: &str,
        reference: &ValueReference,
        expression_id: &str,
        iteration_index: Option<usize>,
        missing: bool,
    ) -> Result<ConditionResult, (EvaluationError, ConditionTrace)> {
        let resolution = self.resolve(reference, expression_id);
        self.resolution_predicate(
            kind,
            reference,
            resolution,
            expression_id,
            iteration_index,
            |_| !missing,
        )
        .map(|mut result| {
            if result.trace.operands[0].state == ResolutionState::Absent {
                result.matched = missing;
                result.trace.outcome = outcome(missing);
            }
            result
        })
    }

    fn resolution_predicate(
        &self,
        kind: &str,
        reference: &ValueReference,
        resolution: Result<Resolved<'_>, EvaluationError>,
        expression_id: &str,
        iteration_index: Option<usize>,
        predicate: impl FnOnce(&Value) -> bool,
    ) -> Result<ConditionResult, (EvaluationError, ConditionTrace)> {
        let operand = operand_trace(reference, &resolution);
        match resolution {
            Ok(Resolved::Present(value)) => {
                let matched = predicate(value);
                Ok(ConditionResult {
                    matched,
                    trace: trace(
                        expression_id,
                        kind,
                        matched,
                        iteration_index,
                        vec![operand],
                        Vec::new(),
                    ),
                })
            }
            Ok(Resolved::Absent) => Ok(ConditionResult {
                matched: false,
                trace: trace(
                    expression_id,
                    kind,
                    false,
                    iteration_index,
                    vec![operand],
                    Vec::new(),
                ),
            }),
            Err(error) => Err((
                error.clone(),
                ConditionTrace {
                    expression_id: expression_id.into(),
                    kind: kind.into(),
                    outcome: TraceOutcome::EvaluationError,
                    short_circuited: false,
                    operator: None,
                    iteration_index,
                    operands: vec![operand],
                    children: Vec::new(),
                    error: Some(error),
                },
            )),
        }
    }

    fn evaluate_array(
        &mut self,
        kind: &str,
        condition: &ArrayCondition,
        expression_id: &str,
        depth: usize,
        iteration_index: Option<usize>,
        mode: ArrayMode,
    ) -> Result<ConditionResult, (EvaluationError, ConditionTrace)> {
        let resolution = self.resolve(&condition.value, expression_id);
        let operand = operand_trace(&condition.value, &resolution);
        let value = match resolution {
            Ok(Resolved::Present(value)) => value,
            Ok(Resolved::Absent) => {
                return Ok(ConditionResult {
                    matched: false,
                    trace: trace(
                        expression_id,
                        kind,
                        false,
                        iteration_index,
                        vec![operand],
                        Vec::new(),
                    ),
                });
            }
            Err(error) => {
                return Err((
                    error.clone(),
                    ConditionTrace {
                        expression_id: expression_id.into(),
                        kind: kind.into(),
                        outcome: TraceOutcome::EvaluationError,
                        short_circuited: false,
                        operator: None,
                        iteration_index,
                        operands: vec![operand],
                        children: Vec::new(),
                        error: Some(error),
                    },
                ));
            }
        };
        let items = value.as_array().cloned().ok_or_else(|| {
            let error = error(
                "MATCH_ARRAY_EXPECTED",
                expression_id,
                "Array quantifier received a non-array value.",
            );
            (
                error.clone(),
                ConditionTrace {
                    expression_id: expression_id.into(),
                    kind: kind.into(),
                    outcome: TraceOutcome::EvaluationError,
                    short_circuited: false,
                    operator: None,
                    iteration_index,
                    operands: vec![operand.clone()],
                    children: Vec::new(),
                    error: Some(error),
                },
            )
        })?;
        if items.len() > MAXIMUM_ARRAY_ITEMS {
            let error = error(
                "MATCH_LIMIT_EXCEEDED",
                expression_id,
                "Array quantifier exceeded its deterministic item limit.",
            );
            return Err((error.clone(), error_trace_for(kind, expression_id, error)));
        }

        let previous_item = self.roots.get("item").cloned();
        let mut children = Vec::with_capacity(items.len());
        let mut match_count = 0usize;
        let mut stopped = false;
        for (index, item) in items.iter().enumerate() {
            if stopped {
                children.push(skipped_trace(
                    &condition.r#where,
                    &format!("{expression_id}/where"),
                    Some(index),
                ));
                continue;
            }
            self.roots.insert("item".into(), item.clone());
            match self.evaluate_condition(
                &condition.r#where,
                &format!("{expression_id}/where"),
                depth + 1,
                Some(index),
            ) {
                Ok(child) => {
                    if child.matched {
                        match_count += 1;
                    }
                    children.push(child.trace);
                    stopped = match mode {
                        ArrayMode::Any => match_count == 1,
                        ArrayMode::All => !child.matched,
                        ArrayMode::None => child.matched,
                        ArrayMode::ExactlyOne => match_count > 1,
                    };
                }
                Err((error, child)) => {
                    children.push(child);
                    restore_root(&mut self.roots, "item", previous_item);
                    return Err((
                        error.clone(),
                        ConditionTrace {
                            expression_id: expression_id.into(),
                            kind: kind.into(),
                            outcome: TraceOutcome::EvaluationError,
                            short_circuited: false,
                            operator: None,
                            iteration_index,
                            operands: vec![operand],
                            children,
                            error: Some(error),
                        },
                    ));
                }
            }
        }
        restore_root(&mut self.roots, "item", previous_item);
        let matched = match mode {
            ArrayMode::Any => match_count > 0,
            ArrayMode::All => match_count == items.len(),
            ArrayMode::None => match_count == 0,
            ArrayMode::ExactlyOne => match_count == 1,
        };
        let short_circuited = children
            .iter()
            .any(|child| child.outcome == TraceOutcome::NotEvaluated);
        Ok(ConditionResult {
            matched,
            trace: ConditionTrace {
                expression_id: expression_id.into(),
                kind: kind.into(),
                outcome: outcome(matched),
                short_circuited,
                operator: None,
                iteration_index,
                operands: vec![operand],
                children,
                error: None,
            },
        })
    }

    fn resolve<'a>(
        &'a self,
        reference: &ValueReference,
        expression_id: &str,
    ) -> Result<Resolved<'a>, EvaluationError> {
        let Some(mut current) = self.roots.get(&reference.root) else {
            return Err(error(
                "MATCH_ROOT_UNAVAILABLE",
                expression_id,
                "The referenced Match root is unavailable.",
            ));
        };
        if reference.pointer.is_empty() {
            return Ok(Resolved::Present(current));
        }
        if !reference.pointer.starts_with('/') {
            return Err(error(
                "MATCH_POINTER_INVALID",
                expression_id,
                "The Match reference is not a valid JSON Pointer.",
            ));
        }
        for raw_token in reference.pointer[1..].split('/') {
            let Some(token) = decode_pointer_token(raw_token) else {
                return Err(error(
                    "MATCH_POINTER_INVALID",
                    expression_id,
                    "The Match reference contains an invalid JSON Pointer escape.",
                ));
            };
            match current {
                Value::Object(object) => {
                    let Some(next) = object.get(&token) else {
                        return Ok(Resolved::Absent);
                    };
                    current = next;
                }
                Value::Array(array) => {
                    if token.is_empty()
                        || (token.len() > 1 && token.starts_with('0'))
                        || !token.bytes().all(|byte| byte.is_ascii_digit())
                    {
                        return Err(error(
                            "MATCH_POINTER_INVALID",
                            expression_id,
                            "The Match array reference contains an invalid index.",
                        ));
                    }
                    let Some(index) = token.parse::<usize>().ok() else {
                        return Err(error(
                            "MATCH_POINTER_INVALID",
                            expression_id,
                            "The Match array index is out of range.",
                        ));
                    };
                    let Some(next) = array.get(index) else {
                        return Ok(Resolved::Absent);
                    };
                    current = next;
                }
                _ => {
                    let mut failure = error(
                        "MATCH_PATH_WRONG_TYPE",
                        expression_id,
                        "The Match path traverses through a non-container value.",
                    );
                    failure.encountered_type = Some(json_type(current));
                    return Err(failure);
                }
            }
        }
        Ok(Resolved::Present(current))
    }

    fn resolve_operand<'a>(
        &'a self,
        operand: &'a Operand,
        expression_id: &str,
    ) -> Result<Resolved<'a>, EvaluationError> {
        match operand {
            Operand::Reference(reference) => self.resolve(reference, expression_id),
            Operand::Literal { literal } => {
                if literal_matches_type(literal) {
                    Ok(Resolved::Present(&literal.value))
                } else {
                    Err(error(
                        "MATCH_LITERAL_TYPE_MISMATCH",
                        expression_id,
                        "The literal value does not match its declared type.",
                    ))
                }
            }
        }
    }
}

#[derive(Clone, Copy)]
enum ArrayMode {
    Any,
    All,
    None,
    ExactlyOne,
}

fn compare(
    left: &Value,
    operator: ComparisonOperator,
    right: &Value,
    expression_id: &str,
) -> Result<bool, EvaluationError> {
    match operator {
        ComparisonOperator::Equal => Ok(equal_values(left, right)),
        ComparisonOperator::NotEqual => Ok(!equal_values(left, right)),
        ComparisonOperator::LessThan
        | ComparisonOperator::LessThanOrEqual
        | ComparisonOperator::GreaterThan
        | ComparisonOperator::GreaterThanOrEqual => {
            let Some(ordering) = numeric_ordering(left, right) else {
                return Err(type_error(expression_id));
            };
            Ok(match operator {
                ComparisonOperator::LessThan => ordering == Ordering::Less,
                ComparisonOperator::LessThanOrEqual => ordering != Ordering::Greater,
                ComparisonOperator::GreaterThan => ordering == Ordering::Greater,
                ComparisonOperator::GreaterThanOrEqual => ordering != Ordering::Less,
                _ => unreachable!(),
            })
        }
        ComparisonOperator::Contains => match (left, right) {
            (Value::String(value), Value::String(fragment)) => Ok(value.contains(fragment)),
            (Value::Array(values), value) => {
                Ok(values.iter().any(|item| equal_values(item, value)))
            }
            _ => Err(type_error(expression_id)),
        },
        ComparisonOperator::StartsWith => match (left.as_str(), right.as_str()) {
            (Some(value), Some(prefix)) => Ok(value.starts_with(prefix)),
            _ => Err(type_error(expression_id)),
        },
        ComparisonOperator::EndsWith => match (left.as_str(), right.as_str()) {
            (Some(value), Some(suffix)) => Ok(value.ends_with(suffix)),
            _ => Err(type_error(expression_id)),
        },
        ComparisonOperator::MatchesSafePattern => match (left.as_str(), right.as_str()) {
            (Some(value), Some(pattern)) if pattern.len() <= MAXIMUM_PATTERN_BYTES => {
                RegexBuilder::new(pattern)
                    .size_limit(MAXIMUM_REGEX_BYTES)
                    .build()
                    .map(|regex| regex.is_match(value))
                    .map_err(|_| {
                        error(
                            "MATCH_PATTERN_INVALID",
                            expression_id,
                            "The safe pattern is invalid or exceeds its compiled size limit.",
                        )
                    })
            }
            (Some(_), Some(_)) => Err(error(
                "MATCH_PATTERN_INVALID",
                expression_id,
                "The safe pattern exceeds its source size limit.",
            )),
            _ => Err(type_error(expression_id)),
        },
        ComparisonOperator::In => match right {
            Value::Array(values) => Ok(values.iter().any(|item| equal_values(left, item))),
            _ => Err(type_error(expression_id)),
        },
    }
}

fn numeric_ordering(left: &Value, right: &Value) -> Option<Ordering> {
    left.as_f64()?.partial_cmp(&right.as_f64()?)
}

fn equal_values(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(_), Value::Number(_)) => {
            numeric_ordering(left, right) == Some(Ordering::Equal)
        }
        _ => left == right,
    }
}

fn literal_matches_type(literal: &TypedLiteral) -> bool {
    match literal.value_type {
        LiteralType::String => literal.value.is_string(),
        LiteralType::Number => literal.value.is_number(),
        LiteralType::Boolean => literal.value.is_boolean(),
        LiteralType::Null => literal.value.is_null(),
        LiteralType::Json => true,
    }
}

fn json_type(value: &Value) -> JsonType {
    match value {
        Value::Null => JsonType::Null,
        Value::Bool(_) => JsonType::Boolean,
        Value::Number(_) => JsonType::Number,
        Value::String(_) => JsonType::String,
        Value::Array(_) => JsonType::Array,
        Value::Object(_) => JsonType::Object,
    }
}

pub(crate) fn decode_pointer_token(token: &str) -> Option<String> {
    let mut decoded = String::with_capacity(token.len());
    let mut characters = token.chars();
    while let Some(character) = characters.next() {
        if character != '~' {
            decoded.push(character);
            continue;
        }
        match characters.next() {
            Some('0') => decoded.push('~'),
            Some('1') => decoded.push('/'),
            _ => return None,
        }
    }
    Some(decoded)
}

fn type_error(expression_id: &str) -> EvaluationError {
    error(
        "MATCH_OPERATOR_TYPE_MISMATCH",
        expression_id,
        "The Match operator does not accept the resolved operand types.",
    )
}

fn error(code: &str, expression_id: &str, message: &str) -> EvaluationError {
    EvaluationError {
        code: code.into(),
        expression_id: expression_id.into(),
        message: message.into(),
        encountered_type: None,
    }
}

fn terminal_error(
    hit_policy: HitPolicy,
    input: OperandTrace,
    cases: Vec<CaseTrace>,
    error: EvaluationError,
    otherwise: Option<&CasePort>,
) -> MatchEvaluation {
    MatchEvaluation {
        trace_version: 1,
        outcome: EvaluationOutcome::EvaluationError,
        hit_policy,
        input,
        selected_case_ids: Vec::new(),
        emitted_port_ids: Vec::new(),
        cases,
        otherwise: otherwise.map(|otherwise| OtherwiseTrace {
            case_id: otherwise.id.clone(),
            key: otherwise.key.clone(),
            selected: false,
        }),
        error: Some(error),
    }
}

fn outcome(matched: bool) -> TraceOutcome {
    if matched {
        TraceOutcome::Matched
    } else {
        TraceOutcome::NotMatched
    }
}

fn trace(
    expression_id: &str,
    kind: &str,
    matched: bool,
    iteration_index: Option<usize>,
    operands: Vec<OperandTrace>,
    children: Vec<ConditionTrace>,
) -> ConditionTrace {
    ConditionTrace {
        expression_id: expression_id.into(),
        kind: kind.into(),
        outcome: outcome(matched),
        short_circuited: false,
        operator: None,
        iteration_index,
        operands,
        children,
        error: None,
    }
}

fn comparison_result(
    expression_id: &str,
    operator: ComparisonOperator,
    matched: bool,
    iteration_index: Option<usize>,
    operands: Vec<OperandTrace>,
) -> ConditionResult {
    let mut condition_trace = trace(
        expression_id,
        "compare",
        matched,
        iteration_index,
        operands,
        Vec::new(),
    );
    condition_trace.operator = Some(operator);
    ConditionResult {
        matched,
        trace: condition_trace,
    }
}

fn comparison_error_trace(
    expression_id: &str,
    operator: ComparisonOperator,
    iteration_index: Option<usize>,
    operands: Vec<OperandTrace>,
    error: EvaluationError,
) -> ConditionTrace {
    ConditionTrace {
        expression_id: expression_id.into(),
        kind: "compare".into(),
        outcome: TraceOutcome::EvaluationError,
        short_circuited: false,
        operator: Some(operator),
        iteration_index,
        operands,
        children: Vec::new(),
        error: Some(error),
    }
}

fn skipped_trace(
    condition: &Condition,
    expression_id: &str,
    iteration_index: Option<usize>,
) -> ConditionTrace {
    terminal_condition_trace(
        expression_id,
        condition_kind(condition),
        TraceOutcome::NotEvaluated,
        true,
        iteration_index,
        None,
    )
}

fn error_trace(
    condition: &Condition,
    expression_id: &str,
    error: EvaluationError,
) -> ConditionTrace {
    error_trace_for(condition_kind(condition), expression_id, error)
}

fn error_trace_for(kind: &str, expression_id: &str, error: EvaluationError) -> ConditionTrace {
    terminal_condition_trace(
        expression_id,
        kind,
        TraceOutcome::EvaluationError,
        false,
        None,
        Some(error),
    )
}

fn terminal_condition_trace(
    expression_id: &str,
    kind: &str,
    outcome: TraceOutcome,
    short_circuited: bool,
    iteration_index: Option<usize>,
    error: Option<EvaluationError>,
) -> ConditionTrace {
    ConditionTrace {
        expression_id: expression_id.into(),
        kind: kind.into(),
        outcome,
        short_circuited,
        operator: None,
        iteration_index,
        operands: Vec::new(),
        children: Vec::new(),
        error,
    }
}

fn condition_kind(condition: &Condition) -> &'static str {
    match condition {
        Condition::All { .. } => "all",
        Condition::Any { .. } => "any",
        Condition::Not { .. } => "not",
        Condition::Compare { .. } => "compare",
        Condition::Exists { .. } => "exists",
        Condition::Missing { .. } => "missing",
        Condition::IsNull { .. } => "isNull",
        Condition::IsType { .. } => "isType",
        Condition::ArrayAny { .. } => "arrayAny",
        Condition::ArrayAll { .. } => "arrayAll",
        Condition::ArrayNone { .. } => "arrayNone",
        Condition::ArrayExactlyOne { .. } => "arrayExactlyOne",
    }
}

fn operand_trace(
    reference: &ValueReference,
    resolution: &Result<Resolved<'_>, EvaluationError>,
) -> OperandTrace {
    resolved_operand_trace(
        format!("{}#{}", reference.root, reference.pointer),
        resolution,
    )
}

fn operand_trace_for_operand(
    operand: &Operand,
    resolution: &Result<Resolved<'_>, EvaluationError>,
) -> OperandTrace {
    match operand {
        Operand::Reference(reference) => operand_trace(reference, resolution),
        Operand::Literal { literal } => resolved_operand_trace(
            format!("literal:{:?}", literal.value_type).to_lowercase(),
            resolution,
        ),
    }
}

fn resolved_operand_trace(
    source: String,
    resolution: &Result<Resolved<'_>, EvaluationError>,
) -> OperandTrace {
    match resolution {
        Ok(Resolved::Present(value)) => OperandTrace {
            source,
            state: ResolutionState::Present,
            value_type: Some(json_type(value)),
        },
        Ok(Resolved::Absent) => OperandTrace {
            source,
            state: ResolutionState::Absent,
            value_type: None,
        },
        Err(_) => OperandTrace {
            source,
            state: ResolutionState::EvaluationError,
            value_type: resolution
                .as_ref()
                .err()
                .and_then(|error| error.encountered_type),
        },
    }
}

fn restore_root(roots: &mut BTreeMap<String, Value>, key: &str, previous: Option<Value>) {
    if let Some(value) = previous {
        roots.insert(key.into(), value);
    } else {
        roots.remove(key);
    }
}
