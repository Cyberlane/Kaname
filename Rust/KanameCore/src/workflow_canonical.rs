use serde::{
    Deserialize, Deserializer,
    de::{self, MapAccess, SeqAccess, Visitor},
};
use serde_json::{Map, Number, Value};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fmt};

pub const MAXIMUM_CANONICAL_INPUT_BYTES: usize = 512 * 1024;
const MAXIMUM_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Debug, PartialEq, Eq)]
pub enum WorkflowCanonicalError {
    InputOutOfBounds,
    InvalidIJson,
    EncodingFailed,
}

#[derive(Debug, PartialEq, Eq)]
pub struct WorkflowCanonicalReport {
    pub canonical_bytes: Vec<u8>,
    pub sha256: String,
}

pub fn canonicalize(input: &[u8]) -> Result<WorkflowCanonicalReport, WorkflowCanonicalError> {
    if input.is_empty() || input.len() > MAXIMUM_CANONICAL_INPUT_BYTES {
        return Err(WorkflowCanonicalError::InputOutOfBounds);
    }
    let mut deserializer = serde_json::Deserializer::from_slice(input);
    let value = UniqueJsonValue::deserialize(&mut deserializer)
        .map_err(|_| WorkflowCanonicalError::InvalidIJson)?
        .0;
    deserializer
        .end()
        .map_err(|_| WorkflowCanonicalError::InvalidIJson)?;
    let canonical_bytes = serde_json_canonicalizer::to_vec(&value)
        .map_err(|_| WorkflowCanonicalError::EncodingFailed)?;
    let sha256 = format!("sha256:{}", hex::encode(Sha256::digest(&canonical_bytes)));
    Ok(WorkflowCanonicalReport {
        canonical_bytes,
        sha256,
    })
}

struct UniqueJsonValue(Value);

impl<'de> Deserialize<'de> for UniqueJsonValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_any(UniqueJsonVisitor)
    }
}

struct UniqueJsonVisitor;

impl<'de> Visitor<'de> for UniqueJsonVisitor {
    type Value = UniqueJsonValue;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("I-JSON data")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(Value::Bool(value)))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        if !(-MAXIMUM_SAFE_INTEGER..=MAXIMUM_SAFE_INTEGER).contains(&value) {
            return Err(E::custom("integer_outside_i_json_safe_range"));
        }
        Ok(UniqueJsonValue(Value::Number(Number::from(value))))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        if value > MAXIMUM_SAFE_INTEGER as u64 {
            return Err(E::custom("integer_outside_i_json_safe_range"));
        }
        Ok(UniqueJsonValue(Value::Number(Number::from(value))))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Number::from_f64(value)
            .map(|number| UniqueJsonValue(Value::Number(number)))
            .ok_or_else(|| E::custom("non_finite_number"))
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
    where
        E: de::Error,
    {
        Ok(UniqueJsonValue(Value::String(value.to_owned())))
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(Value::String(value)))
    }

    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(Value::Null))
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(UniqueJsonValue(Value::Null))
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element::<UniqueJsonValue>()? {
            values.push(value.0);
        }
        Ok(UniqueJsonValue(Value::Array(values)))
    }

    fn visit_map<A>(self, mut object: A) -> Result<Self::Value, A::Error>
    where
        A: MapAccess<'de>,
    {
        let mut keys = BTreeSet::new();
        let mut values = Map::new();
        while let Some(key) = object.next_key::<String>()? {
            if !keys.insert(key.clone()) {
                return Err(de::Error::custom("duplicate_object_key"));
            }
            values.insert(key, object.next_value::<UniqueJsonValue>()?.0);
        }
        Ok(UniqueJsonValue(Value::Object(values)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_rfc_8785_sample() {
        let input = br#"{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],"string":"\u20ac$\u000F\nA'B\"\\\\\"/","literals":[null,true,false]}"#;
        let report = canonicalize(input).unwrap();
        assert_eq!(
            String::from_utf8(report.canonical_bytes).unwrap(),
            "{\"literals\":[null,true,false],\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27],\"string\":\"€$\\u000f\\nA'B\\\"\\\\\\\\\\\"/\"}"
        );
    }

    #[test]
    fn rejects_non_i_json_inputs() {
        for input in [
            br#"{"a":1,"a":2}"#.as_slice(),
            br#"9007199254740992"#.as_slice(),
            br#""\ud800""#.as_slice(),
            br#"NaN"#.as_slice(),
        ] {
            assert_eq!(
                canonicalize(input),
                Err(WorkflowCanonicalError::InvalidIJson)
            );
        }
        assert_eq!(
            canonicalize(&[]),
            Err(WorkflowCanonicalError::InputOutOfBounds)
        );
    }

    #[test]
    fn canonicalizes_negative_zero_and_utf16_property_order() {
        let input = "{\"€\":1,\"\\r\":2,\"דּ\":3,\"1\":4,\"😀\":5,\"\":6,\"ö\":7,\"numbers\":[-0,0.0,1e30,0.000001,1e-7]}";
        let report = canonicalize(input.as_bytes()).unwrap();
        assert_eq!(
            String::from_utf8(report.canonical_bytes).unwrap(),
            "{\"\\r\":2,\"1\":4,\"numbers\":[0,0,1e+30,0.000001,1e-7],\"\":6,\"ö\":7,\"€\":1,\"😀\":5,\"דּ\":3}"
        );
    }
}
