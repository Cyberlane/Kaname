use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::Path,
};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};

pub(crate) type Result<T> = std::result::Result<T, PrivateFilesystemError>;

#[derive(Debug)]
pub(crate) enum PrivateFilesystemError {
    Io(std::io::Error),
    UnsafePath(&'static str),
    Bounds(&'static str),
}

impl PrivateFilesystemError {
    pub(crate) fn fold<T>(
        self,
        io: impl FnOnce(std::io::Error) -> T,
        unsafe_path: impl FnOnce(&'static str) -> T,
        bounds: impl FnOnce(&'static str) -> T,
    ) -> T {
        match self {
            Self::Io(error) => io(error),
            Self::UnsafePath(code) => unsafe_path(code),
            Self::Bounds(code) => bounds(code),
        }
    }
}

impl From<std::io::Error> for PrivateFilesystemError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Clone, Copy)]
pub(crate) enum PrivatePathKind {
    File,
    Directory,
}

pub(crate) fn protect_path(path: &Path, kind: PrivatePathKind) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    let expected_type = match kind {
        PrivatePathKind::File => metadata.is_file(),
        PrivatePathKind::Directory => metadata.is_dir(),
    };
    if metadata.file_type().is_symlink() || !expected_type {
        return Err(PrivateFilesystemError::UnsafePath("private_path_type"));
    }
    #[cfg(unix)]
    if matches!(kind, PrivatePathKind::File) && metadata.nlink() != 1 {
        return Err(PrivateFilesystemError::UnsafePath("private_file_hard_link"));
    }
    #[cfg(unix)]
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(match kind {
            PrivatePathKind::File => 0o600,
            PrivatePathKind::Directory => 0o700,
        }),
    )?;
    Ok(())
}

pub(crate) fn ensure_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    protect_path(path, PrivatePathKind::Directory)
}

pub(crate) fn write_new_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let file = write_new_file_unflushed(path, bytes)?;
    file.sync_all()?;
    Ok(())
}

pub(crate) fn write_new_file_unflushed(path: &Path, bytes: &[u8]) -> Result<File> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    protect_path(path, PrivatePathKind::File)?;
    file.write_all(bytes)?;
    Ok(file)
}

pub(crate) fn read_bounded_file(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>> {
    let metadata = file_metadata(path)?;
    if metadata.len() > maximum_bytes {
        return Err(PrivateFilesystemError::Bounds("private_file_bytes"));
    }
    Ok(fs::read(path)?)
}

pub(crate) fn file_metadata(path: &Path) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(PrivateFilesystemError::UnsafePath("private_file_type"));
    }
    #[cfg(unix)]
    if metadata.nlink() != 1 {
        return Err(PrivateFilesystemError::UnsafePath("private_file_hard_link"));
    }
    Ok(metadata)
}

pub(crate) fn directory_metadata(path: &Path) -> Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(PrivateFilesystemError::UnsafePath("private_directory_type"));
    }
    Ok(metadata)
}

pub(crate) fn make_immutable_file(path: &Path) -> Result<()> {
    file_metadata(path)?;
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o400))?;
    #[cfg(not(unix))]
    {
        let mut permissions = fs::metadata(path)?.permissions();
        permissions.set_readonly(true);
        fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

pub(crate) fn sync_directory(path: &Path) -> Result<()> {
    directory_metadata(path)?;
    File::open(path)?.sync_all()?;
    Ok(())
}
