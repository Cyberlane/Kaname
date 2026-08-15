//! Deterministic run-retention policy and eligibility rules.
//!
//! The published workflow revision owns the policy. The runtime copies that
//! exact policy into the run-start fact so projection and UI never infer a
//! mutable installation default after execution has begun.

use crate::v1;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const DEFAULT_RETENTION_DAYS: u32 = 30;
pub const MAXIMUM_RETENTION_DAYS: u32 = 3_650;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkflowRetentionError {
    InvalidPolicy,
}

pub type Result<T> = std::result::Result<T, WorkflowRetentionError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "kebab-case", deny_unknown_fields)]
pub enum WorkflowRunRetentionPolicy {
    Duration { days: u32 },
    DeleteAfterSuccess,
    Forever,
}

impl Default for WorkflowRunRetentionPolicy {
    fn default() -> Self {
        Self::Duration {
            days: DEFAULT_RETENTION_DAYS,
        }
    }
}

impl WorkflowRunRetentionPolicy {
    pub fn from_optional_json(value: Option<&Value>) -> Result<Self> {
        let policy: Self = value
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|_| WorkflowRetentionError::InvalidPolicy)?
            .unwrap_or_default();
        policy.validate()?;
        Ok(policy)
    }

    pub fn from_proto(policy: Option<&v1::WorkflowRunRetentionPolicy>) -> Result<Self> {
        let Some(policy) = policy else {
            return Ok(Self::default());
        };
        let mode = v1::WorkflowRunRetentionMode::try_from(policy.mode)
            .map_err(|_| WorkflowRetentionError::InvalidPolicy)?;
        let parsed = match mode {
            v1::WorkflowRunRetentionMode::Duration => Self::Duration { days: policy.days },
            v1::WorkflowRunRetentionMode::DeleteAfterSuccess if policy.days == 0 => {
                Self::DeleteAfterSuccess
            }
            v1::WorkflowRunRetentionMode::Forever if policy.days == 0 => Self::Forever,
            _ => return Err(WorkflowRetentionError::InvalidPolicy),
        };
        parsed.validate()?;
        Ok(parsed)
    }

    pub fn as_proto(self) -> v1::WorkflowRunRetentionPolicy {
        let (mode, days) = match self {
            Self::Duration { days } => (v1::WorkflowRunRetentionMode::Duration, days),
            Self::DeleteAfterSuccess => (v1::WorkflowRunRetentionMode::DeleteAfterSuccess, 0),
            Self::Forever => (v1::WorkflowRunRetentionMode::Forever, 0),
        };
        v1::WorkflowRunRetentionPolicy {
            mode: mode as i32,
            days,
        }
    }

    pub fn validate(self) -> Result<()> {
        match self {
            Self::Duration { days } if (1..=MAXIMUM_RETENTION_DAYS).contains(&days) => Ok(()),
            Self::DeleteAfterSuccess | Self::Forever => Ok(()),
            Self::Duration { .. } => Err(WorkflowRetentionError::InvalidPolicy),
        }
    }

    pub fn automatic_eligible_at(
        self,
        outcome: Option<v1::WorkflowRunOutcome>,
        settled_at_unix_millis: Option<i64>,
    ) -> Option<i64> {
        let settled_at = settled_at_unix_millis.filter(|value| *value >= 0)?;
        match self {
            Self::Duration { days } => settled_at.checked_add(i64::from(days) * 86_400_000),
            Self::DeleteAfterSuccess if outcome == Some(v1::WorkflowRunOutcome::Succeeded) => {
                Some(settled_at)
            }
            Self::DeleteAfterSuccess | Self::Forever => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkflowRunProtectionState {
    pub settled: bool,
    pub waiting: bool,
    pub approval_pending: bool,
    pub effect_authorized: bool,
    pub unknown_outcome: bool,
}

impl WorkflowRunProtectionState {
    pub fn protected_reason(self) -> Option<&'static str> {
        if self.unknown_outcome {
            Some("unknown_outcome")
        } else if self.approval_pending {
            Some("approval_pending")
        } else if self.effect_authorized {
            Some("effect_authorized")
        } else if self.waiting {
            Some("waiting")
        } else if !self.settled {
            Some("run_not_settled")
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_and_modes_are_exact() {
        assert_eq!(
            WorkflowRunRetentionPolicy::from_optional_json(None).unwrap(),
            WorkflowRunRetentionPolicy::Duration { days: 30 }
        );
        assert_eq!(
            WorkflowRunRetentionPolicy::from_optional_json(Some(&serde_json::json!({
                "mode": "delete-after-success"
            })))
            .unwrap(),
            WorkflowRunRetentionPolicy::DeleteAfterSuccess
        );
        assert_eq!(
            WorkflowRunRetentionPolicy::from_optional_json(Some(&serde_json::json!({
                "mode": "forever"
            })))
            .unwrap(),
            WorkflowRunRetentionPolicy::Forever
        );
        assert!(
            WorkflowRunRetentionPolicy::from_optional_json(Some(&serde_json::json!({
                "mode": "duration",
                "days": 0
            })))
            .is_err()
        );
    }

    #[test]
    fn unresolved_states_are_always_protected() {
        for state in [
            WorkflowRunProtectionState {
                settled: false,
                waiting: true,
                approval_pending: false,
                effect_authorized: false,
                unknown_outcome: false,
            },
            WorkflowRunProtectionState {
                settled: false,
                waiting: false,
                approval_pending: true,
                effect_authorized: false,
                unknown_outcome: false,
            },
            WorkflowRunProtectionState {
                settled: true,
                waiting: false,
                approval_pending: false,
                effect_authorized: true,
                unknown_outcome: false,
            },
            WorkflowRunProtectionState {
                settled: true,
                waiting: false,
                approval_pending: false,
                effect_authorized: false,
                unknown_outcome: true,
            },
        ] {
            assert!(state.protected_reason().is_some());
        }
        assert_eq!(
            WorkflowRunProtectionState {
                settled: true,
                waiting: false,
                approval_pending: false,
                effect_authorized: false,
                unknown_outcome: false,
            }
            .protected_reason(),
            None
        );
    }

    #[test]
    fn automatic_eligibility_follows_each_policy_mode() {
        let settled_at = 1_000;
        assert_eq!(
            WorkflowRunRetentionPolicy::Duration { days: 30 }
                .automatic_eligible_at(Some(v1::WorkflowRunOutcome::Failed), Some(settled_at),),
            Some(2_592_001_000)
        );
        assert_eq!(
            WorkflowRunRetentionPolicy::DeleteAfterSuccess
                .automatic_eligible_at(Some(v1::WorkflowRunOutcome::Succeeded), Some(settled_at),),
            Some(settled_at)
        );
        assert_eq!(
            WorkflowRunRetentionPolicy::DeleteAfterSuccess
                .automatic_eligible_at(Some(v1::WorkflowRunOutcome::Failed), Some(settled_at),),
            None
        );
        assert_eq!(
            WorkflowRunRetentionPolicy::Forever
                .automatic_eligible_at(Some(v1::WorkflowRunOutcome::Succeeded), Some(settled_at),),
            None
        );
    }
}
