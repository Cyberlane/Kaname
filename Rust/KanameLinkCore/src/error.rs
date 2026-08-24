use std::fmt::{Display, Formatter};

pub type Result<T> = std::result::Result<T, LinkError>;

#[derive(Debug)]
pub enum LinkError {
    Invalid(&'static str),
    Forbidden(&'static str),
    NotFound(&'static str),
    Conflict(&'static str),
    Unavailable(&'static str),
    Io(std::io::Error),
    Sql(rusqlite::Error),
    Json(serde_json::Error),
    Crypto(snow::Error),
    Transport(String),
}

impl LinkError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Invalid(code)
            | Self::Forbidden(code)
            | Self::NotFound(code)
            | Self::Conflict(code)
            | Self::Unavailable(code) => code,
            Self::Io(_) => "io_failure",
            Self::Sql(_) => "storage_failure",
            Self::Json(_) => "invalid_json",
            Self::Crypto(_) => "noise_failure",
            Self::Transport(_) => "transport_failure",
        }
    }

    pub fn is_transport_boundary(&self) -> bool {
        matches!(self, Self::Unavailable(_) | Self::Transport(_))
    }
}

impl Display for LinkError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())
    }
}

impl std::error::Error for LinkError {}

impl From<std::io::Error> for LinkError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<rusqlite::Error> for LinkError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}

impl From<serde_json::Error> for LinkError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

impl From<snow::Error> for LinkError {
    fn from(value: snow::Error) -> Self {
        Self::Crypto(value)
    }
}
