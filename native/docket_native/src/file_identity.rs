//! Where a project file really is, and which file it is, before anything
//! opens it: two spellings of one file (through a symbolic link, a linked
//! parent directory, `..`, or letter case the file system ignores) must reach
//! one owner, never two with their own caches and locks.
//!
//! - An existing file resolves to its final path (every link and parent
//!   resolved) and the operating system's identity of it: device and inode on
//!   Unix; volume serial and the full 128-bit file ID on Windows.
//! - A file still to be created resolves its existing parent directory and
//!   keeps its own name.
//! - A file's own entry (`of_leaf`) resolves its parent directory but not the
//!   file itself, which must be a regular file, not a link: what an owner
//!   checks before writing, so a link put in its file's place is noticed
//!   rather than written through.
//!
//! Anything that cannot be resolved is an error, never a guess. Paths come
//! back with "/" separators, as Godot writes them.

use godot::prelude::*;
use std::path::{Path, PathBuf};

/// GDScript's way to resolve project files. Results are dictionaries:
/// {path, id, links} for an existing file, {path} for a new one, or {error}.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct DocketFileIdentity;

#[godot_api]
impl DocketFileIdentity {
    /// The existing regular file at `path` (absolute, or relative to the
    /// working directory): {path, id, links}, `links` its hard link count.
    #[func]
    fn of(&self, path: GString) -> VarDictionary {
        found(platform::existing(Path::new(&path.to_string()), true))
    }

    /// The regular file whose entry is `path`, its last component not
    /// followed: {path, id, links}; a link there is an error.
    #[func]
    fn of_leaf(&self, path: GString) -> VarDictionary {
        found(platform::existing(Path::new(&path.to_string()), false))
    }

    /// Where a file not yet at `path` would be: {path}, its parent directory
    /// resolved as it exists now. Any entry there (a link, dangling or not, a
    /// directory) is an error, and so is one that cannot be looked at: only
    /// a positive "no such entry" is absence.
    #[func]
    fn of_new(&self, path: GString) -> VarDictionary {
        let path = PathBuf::from(path.to_string());
        let name = match path.file_name() {
            Some(name) if !matches!(name.to_str(), Some("." | "..")) => name.to_owned(),
            _ => return failed(format!("{} does not name a file", path.display())),
        };
        let parent = match path.parent() {
            Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
            _ => PathBuf::from("."),
        };
        let resolved = match platform::directory(&parent) {
            Ok(resolved) => resolved.join(name),
            Err(error) => return failed(error),
        };
        match resolved.symlink_metadata() {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Ok(_) => return failed(format!("{} already exists", resolved.display())),
            Err(e) => return failed(format!("cannot inspect {}: {e}", resolved.display())),
        }
        let mut reply = VarDictionary::new();
        reply.set("path", godot_path(&resolved).as_str());
        reply
    }
}

pub(crate) struct Found {
    pub(crate) path: PathBuf,
    pub(crate) id: String,
    pub(crate) links: u64,
}

fn found(result: Result<Found, String>) -> VarDictionary {
    match result {
        Ok(found) => {
            let mut reply = VarDictionary::new();
            reply.set("path", godot_path(&found.path).as_str());
            reply.set("id", found.id.as_str());
            reply.set("links", found.links as i64);
            reply
        }
        Err(error) => failed(error),
    }
}

fn failed(error: String) -> VarDictionary {
    let mut reply = VarDictionary::new();
    reply.set("error", error.as_str());
    reply
}

// Windows' verbatim prefixes dropped ("\\?\C:\…" is "C:\…", "\\?\UNC\…" is
// "\\…") and separators turned to "/".
pub(crate) fn godot_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    let plain = if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else {
        text.strip_prefix(r"\\?\").unwrap_or(&text).to_string()
    };
    if cfg!(windows) { plain.replace('\\', "/") } else { plain }
}

#[cfg(unix)]
pub(crate) mod platform {
    use super::Found;
    use std::os::unix::fs::MetadataExt;
    use std::path::{Path, PathBuf};

    /// The identity `meta` (of a file, not followed) gives: device and inode.
    pub(crate) fn identity(meta: &std::fs::Metadata) -> String {
        format!("{}:{}", meta.dev(), meta.ino())
    }

    // `follow`: the file a link at `path` leads to; else the entry itself,
    // which must not be a link.
    pub fn existing(path: &Path, follow: bool) -> Result<Found, String> {
        let resolved = if follow {
            std::fs::canonicalize(path).map_err(|e| format!("cannot resolve {}: {e}", path.display()))?
        } else {
            let name = path.file_name().ok_or_else(|| format!("{} does not name a file", path.display()))?;
            let parent = match path.parent() {
                Some(parent) if !parent.as_os_str().is_empty() => parent,
                _ => Path::new("."),
            };
            directory(parent)?.join(name)
        };
        if resolved.to_str().is_none() {
            return Err(format!("{} is not a UTF-8 path", resolved.display()));
        }
        let meta = std::fs::symlink_metadata(&resolved).map_err(|e| format!("cannot inspect {}: {e}", resolved.display()))?;
        if meta.file_type().is_symlink() {
            return Err(format!("{} is a link", resolved.display()));
        }
        if !meta.is_file() {
            return Err(format!("{} is not a file", resolved.display()));
        }
        Ok(Found { id: identity(&meta), links: meta.nlink(), path: resolved })
    }

    pub fn directory(path: &Path) -> Result<PathBuf, String> {
        let resolved = std::fs::canonicalize(path).map_err(|e| format!("cannot resolve {}: {e}", path.display()))?;
        if !resolved.is_dir() || resolved.to_str().is_none() {
            return Err(format!("{} is not a usable directory", resolved.display()));
        }
        Ok(resolved)
    }
}

#[cfg(windows)]
pub(crate) mod platform {
    use super::Found;
    use std::ffi::OsString;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::path::{Path, PathBuf};
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FileAttributeTagInfo, FileIdInfo, GetFileInformationByHandle, GetFileInformationByHandleEx,
        GetFinalPathNameByHandleW, BY_HANDLE_FILE_INFORMATION, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
        FILE_ATTRIBUTE_TAG_INFO, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_ID_INFO,
        FILE_NAME_NORMALIZED, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
        VOLUME_NAME_DOS,
    };

    // The reparse tag bit of tags that name another file (IsReparseTagNameSurrogate).
    const NAME_SURROGATE: u32 = 0x2000_0000;

    // Closes a handle when dropped.
    struct Handle(HANDLE);

    impl Drop for Handle {
        fn drop(&mut self) {
            // SAFETY: the handle was opened here and is closed once.
            unsafe { CloseHandle(self.0) };
        }
    }

    // `path` opened for its attributes only, links followed to what they
    // lead to, with the final path and information of what was opened.
    // `follow` false: the entry itself, a reparse point (a link) included.
    fn open(path: &Path, follow: bool) -> Result<(PathBuf, BY_HANDLE_FILE_INFORMATION, Handle), String> {
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        // SAFETY: `wide` is NUL-terminated; the handle is closed by `Handle`.
        let raw = unsafe {
            CreateFileW(
                wide.as_ptr(),
                FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | if follow { 0 } else { FILE_FLAG_OPEN_REPARSE_POINT },
                std::ptr::null_mut(),
            )
        };
        if raw == INVALID_HANDLE_VALUE {
            return Err(format!("cannot open {}: {}", path.display(), std::io::Error::last_os_error()));
        }
        let handle = Handle(raw);
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: `info` is written by the call.
        if unsafe { GetFileInformationByHandle(handle.0, &mut info) } == 0 {
            return Err(format!("cannot inspect {}", path.display()));
        }
        let mut buffer = vec![0u16; 1024];
        loop {
            // SAFETY: `buffer` holds the length passed.
            let length = unsafe {
                GetFinalPathNameByHandleW(handle.0, buffer.as_mut_ptr(), buffer.len() as u32, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)
            } as usize;
            if length == 0 {
                return Err(format!("cannot resolve {}", path.display()));
            }
            if length < buffer.len() {
                let resolved = PathBuf::from(OsString::from_wide(&buffer[..length]));
                return Ok((resolved, info, handle));
            }
            buffer.resize(length + 1, 0);
        }
    }

    /// What an open handle is: its identity (volume serial and the full
    /// 128-bit file ID), its hard link count, and whether it is a directory
    /// or a link (a reparse point naming another file; others, such as a
    /// synced cloud file's, are the file itself).
    pub(crate) struct Facts {
        pub(crate) id: String,
        pub(crate) links: u64,
        pub(crate) directory: bool,
        pub(crate) link: bool,
    }

    pub(crate) fn facts(handle: HANDLE) -> Result<Facts, String> {
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: `info` is written by the call.
        if unsafe { GetFileInformationByHandle(handle, &mut info) } == 0 {
            return Err(format!("cannot inspect a file: {}", std::io::Error::last_os_error()));
        }
        let mut link = false;
        if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            let mut tag: FILE_ATTRIBUTE_TAG_INFO = unsafe { std::mem::zeroed() };
            // SAFETY: `tag` is written by the call, with its size.
            let read = unsafe {
                GetFileInformationByHandleEx(
                    handle,
                    FileAttributeTagInfo,
                    (&mut tag as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
                    std::mem::size_of::<FILE_ATTRIBUTE_TAG_INFO>() as u32,
                )
            };
            link = read == 0 || tag.ReparseTag & NAME_SURROGATE != 0;
        }
        let mut id: FILE_ID_INFO = unsafe { std::mem::zeroed() };
        // SAFETY: `id` is written by the call, with its size.
        if unsafe {
            GetFileInformationByHandleEx(handle, FileIdInfo, (&mut id as *mut FILE_ID_INFO).cast(), std::mem::size_of::<FILE_ID_INFO>() as u32)
        } == 0
        {
            return Err(format!("cannot identify a file: {}", std::io::Error::last_os_error()));
        }
        let file: String = id.FileId.Identifier.iter().map(|b| format!("{b:02x}")).collect();
        Ok(Facts {
            id: format!("{:016x}:{file}", id.VolumeSerialNumber),
            links: info.nNumberOfLinks as u64,
            directory: info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0,
            link,
        })
    }

    pub fn existing(path: &Path, follow: bool) -> Result<Found, String> {
        let (resolved, _, handle) = open(path, follow)?;
        let facts = facts(handle.0)?;
        if facts.link {
            return Err(format!("{} is a link", resolved.display()));
        }
        if resolved.to_str().is_none() {
            return Err(format!("{} is not a Unicode path", resolved.display()));
        }
        if facts.directory {
            return Err(format!("{} is not a file", resolved.display()));
        }
        Ok(Found { id: facts.id, links: facts.links, path: resolved })
    }

    pub fn directory(path: &Path) -> Result<PathBuf, String> {
        let (resolved, info, _) = open(path, true)?;
        if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 || resolved.to_str().is_none() {
            return Err(format!("{} is not a usable directory", resolved.display()));
        }
        Ok(resolved)
    }
}
