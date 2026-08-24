use crate::{LinkError, Result};
use rusqlite::{Connection, params};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};

pub fn open_private_database(root: &Path, filename: &str) -> Result<(Connection, PathBuf)> {
    if root.as_os_str().is_empty() || root.file_name().is_none() {
        return Err(LinkError::Invalid("invalid_state_root"));
    }
    if root.exists() {
        protect_directory(root)?;
    } else {
        fs::create_dir_all(root)?;
        protect_directory(root)?;
    }
    let path = root.join(filename);
    if path.exists() {
        protect_file(&path)?;
    }
    let connection = Connection::open(&path)?;
    protect_file(&path)?;
    connection.execute_batch(
        "PRAGMA foreign_keys = ON;
         PRAGMA trusted_schema = OFF;
         PRAGMA secure_delete = ON;
         PRAGMA journal_mode = DELETE;
         PRAGMA synchronous = FULL;
         PRAGMA temp_store = MEMORY;",
    )?;
    Ok((connection, path))
}

pub fn table_has_column(connection: &Connection, table: &str, column: &str) -> Result<bool> {
    let count = connection.query_row(
        "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
        params![table, column],
        |row| row.get::<_, i64>(0),
    )?;
    Ok(count > 0)
}

fn protect_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(LinkError::Invalid("unsafe_state_root"));
    }
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn protect_file(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(LinkError::Invalid("unsafe_database_path"));
    }
    #[cfg(unix)]
    {
        if metadata.nlink() != 1 {
            return Err(LinkError::Invalid("unsafe_database_hard_link"));
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}
