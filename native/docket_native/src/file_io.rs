//! Writing a new file without ever replacing one, and the lock a project's
//! audit sidecar is written and read under.
//!
//! A new file is staged in the directory it will live in (a private,
//! uniquely named file, created exclusively, written in full and flushed to
//! the device), then published under its final name only if no entry of that
//! name exists: Linux renameat2 RENAME_NOREPLACE, macOS renamex_np
//! RENAME_EXCL, Windows MoveFileExW without REPLACE_EXISTING and with
//! WRITE_THROUGH; each treats any entry there, a dangling link included, as
//! taken. Nothing checks and then overwrites, links and unlinks, or copies
//! across devices; where the no-clobber move is unsupported, nothing is
//! published and that is said. The staged file is checked (its identity, its
//! one name, its exact bytes) and then moved by name, so a file swapped or
//! changed in between would be moved instead; the same check after the move
//! catches it, as a publication not durable. Each check compares the bytes
//! read through its checked handle and then flushes that file; a writer
//! changing it at the same time is not excluded. A stage that fails
//! after it was created is left where it is: removing it by name could
//! remove another file put in its place. On Unix the directory is flushed
//! after the move (F_FULLFSYNC on macOS where the file system has it); on
//! Windows write-through is what the move promises, and no more is claimed.
//! New files are the account's own: mode 0600 on Unix; on Windows an access
//! list of this account, SYSTEM and Administrators, set as the file is
//! created and not inherited. A publication reports how far it got:
//! not_published, published_durability_uncertain (the name is taken and
//! stays, but its flush or check failed) or published_durable.
//!
//! The audit lock is an OS lock on a file in the coordination directory
//! named after the sidecar's path (the project's, its directory resolved,
//! case folded), so every spelling that reaches one sidecar takes one lock;
//! the file is never removed, so every holder locks the same one. Under it
//! the sidecar, `<project>.audit.jsonl`, is appended to, or read whole, only
//! through a handle that is the sidecar itself: a regular file with no other
//! names, never a link or a pipe in its place. It orders only writers that
//! take it.

use crate::coord_dir::coordination_dir;
use crate::file_identity::{godot_path, platform};
use godot::prelude::*;
use std::fs::{File, TryLockError};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const LOCK_POLL: Duration = Duration::from_millis(10);

/// GDScript's handle on checked file writing and the audit lock. Results are
/// dictionaries, {error} (with `kind` where one is useful) on failure.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct DocketFileIO;

#[godot_api]
impl DocketFileIO {
    /// A new file in the existing directory `parent` holding exactly `bytes`,
    /// written and flushed to the device before this returns: {stage,
    /// identity}. Its name is unique, and it is created exclusively and
    /// private to this account. On failure {error, kind}, plus `stage` when
    /// a file was created and left behind.
    #[func]
    fn stage_new(&self, parent: GString, bytes: PackedByteArray) -> VarDictionary {
        match stage(Path::new(&parent.to_string()), bytes.as_slice()) {
            Ok((path, identity)) => {
                let mut reply = VarDictionary::new();
                reply.set("stage", godot_path(&path).as_str());
                reply.set("identity", identity.as_str());
                reply
            }
            Err((error, left)) => {
                let mut reply = failed(error, "stage");
                if let Some(path) = left {
                    reply.set("stage", godot_path(&path).as_str());
                }
                reply
            }
        }
    }

    /// Publishes the staged file `stage`, which must still be the file
    /// `expected_id` holding exactly `bytes`, as `dest` in the same
    /// directory, only if nothing is there: {status, phase, identity, path,
    /// error}. `status` is not_published (nothing changed),
    /// published_durability_uncertain (dest holds what was moved, but its
    /// flush or check failed; it is left as it is) or published_durable.
    #[func]
    fn publish_new(&self, stage: GString, expected_id: GString, bytes: PackedByteArray, dest: GString) -> VarDictionary {
        publish(Path::new(&stage.to_string()), &expected_id.to_string(), bytes.as_slice(), Path::new(&dest.to_string()))
    }

    /// Flushes the existing file `path` to the device: {} or {error}. A link,
    /// or a file with other names, is refused.
    #[func]
    fn sync_existing(&self, path: GString) -> VarDictionary {
        let path = PathBuf::from(path.to_string());
        let synced = io::open_verify(&path)
            .map_err(|e| format!("cannot open {}: {e}", path.display()))
            .and_then(|file| io::check_sole(&file, &path).map(|_| file))
            .and_then(|file| file.sync_all().map_err(|e| format!("cannot flush {}: {e}", path.display())));
        match synced {
            Ok(()) => VarDictionary::new(),
            Err(error) => failed(error, "sync"),
        }
    }

    /// The audit lock of the project file at `source` (absolute), held
    /// once no other holder has it or refused after `deadline_ms`: {guard} (a
    /// DocketAuditGuard, released by release() or when freed) or {error,
    /// kind}, kind "busy" when another holder kept it, "unavailable" when it
    /// cannot be taken. Not reentrant: a holder asking again waits for itself.
    #[func]
    fn audit_lock(&self, source: GString, deadline_ms: i64) -> VarDictionary {
        lock_audits(&source.to_string(), None, deadline_ms)
    }

    /// As audit_lock, holding as well the audit lock of `other` (a project
    /// file not yet written, say), both within `deadline_ms`. The two are
    /// taken in one order by their lock keys, so two holders of the same pair
    /// never wait on each other, and once when both paths share a key. The
    /// guard is for `source`'s sidecar and holds both until released.
    #[func]
    fn audit_lock_with(&self, source: GString, other: GString, deadline_ms: i64) -> VarDictionary {
        lock_audits(&source.to_string(), Some(&other.to_string()), deadline_ms)
    }
}

// The audit locks of `source` and `other`: {guard} or {error, kind}. Locks
// already taken are given back on failure, as their files are dropped.
fn lock_audits(source: &str, other: Option<&str>, deadline_ms: i64) -> VarDictionary {
    let deadline = Instant::now() + Duration::from_millis(deadline_ms.max(0) as u64);
    let source = match resolved(Path::new(source)) {
        Ok(path) => path,
        Err(error) => return failed(error, "unavailable"),
    };
    let source_key = lock_key(&source);
    let mut wanted = vec![(source_key.clone(), source.clone())];
    if let Some(other) = other {
        match resolved(Path::new(other)) {
            Ok(path) if lock_key(&path) != source_key => wanted.push((lock_key(&path), path)),
            Ok(_) => {}
            Err(error) => return failed(error, "unavailable"),
        }
    }
    wanted.sort_by(|a, b| a.0.cmp(&b.0));
    let (mut lock, mut also) = (None, None);
    for (key, path) in wanted {
        let file = match lock_file(&key) {
            Ok(file) => file,
            Err(error) => return failed(error, "unavailable"),
        };
        loop {
            match file.try_lock() {
                Ok(()) => break,
                Err(TryLockError::WouldBlock) if Instant::now() < deadline => std::thread::sleep(LOCK_POLL),
                Err(TryLockError::WouldBlock) => return failed(format!("the audit of {} is locked by another writer", path.display()), "busy"),
                Err(TryLockError::Error(e)) => return failed(format!("cannot lock the audit of {}: {e}", path.display()), "unavailable"),
            }
        }
        if key == source_key {
            lock = Some(file);
        } else {
            also = Some(file);
        }
    }
    let guard = DocketAuditGuard { lock, also, audit: PathBuf::from(format!("{}.audit.jsonl", source.display())) };
    let mut reply = VarDictionary::new();
    reply.set("guard", Gd::from_object(guard));
    reply
}

/// A held audit lock (DocketFileIO.audit_lock, or audit_lock_with and the
/// other lock it took) and what it guards: the project's audit sidecar,
/// appended to or read only while it is held.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct DocketAuditGuard {
    lock: Option<File>,
    // The other audit lock taken with this one (audit_lock_with), if any.
    also: Option<File>,
    audit: PathBuf,
}

#[godot_api]
impl DocketAuditGuard {
    /// Appends `bytes` to the sidecar, creating it (exclusively, private to
    /// this account) when absent: {} or {error}. A link or a file with other
    /// names in its place is refused.
    #[func]
    fn append(&self, bytes: PackedByteArray) -> VarDictionary {
        if self.lock.is_none() {
            return failed("the audit lock was released".to_string(), "released");
        }
        let appended = io::open_append(&self.audit)
            .or_else(|e| if e.kind() == ErrorKind::NotFound { io::create_audit(&self.audit) } else { Err(e) })
            .map_err(|e| format!("cannot open {}: {e}", self.audit.display()))
            .and_then(|file| io::check_sole(&file, &self.audit).map(|_| file))
            .and_then(|mut file| file.write_all(bytes.as_slice()).map_err(|e| format!("cannot append to {}: {e}", self.audit.display())));
        match appended {
            Ok(()) => VarDictionary::new(),
            Err(error) => failed(error, "unavailable"),
        }
    }

    /// The sidecar's exact bytes: {present: true, bytes, identity}, {present:
    /// false} only when there is positively no entry of its name, else
    /// {error} (a link, a file with other names, a read that failed).
    #[func]
    fn snapshot(&self) -> VarDictionary {
        if self.lock.is_none() {
            return failed("the audit lock was released".to_string(), "released");
        }
        let mut reply = VarDictionary::new();
        let file = match io::open_read(&self.audit) {
            Ok(file) => file,
            Err(e) if e.kind() == ErrorKind::NotFound => {
                reply.set("present", false);
                return reply;
            }
            Err(e) => return failed(format!("cannot open {}: {e}", self.audit.display()), "unavailable"),
        };
        let read = io::check_sole(&file, &self.audit).and_then(|identity| {
            let mut bytes = Vec::new();
            (&file).read_to_end(&mut bytes).map_err(|e| format!("cannot read {}: {e}", self.audit.display()))?;
            Ok((identity, bytes))
        });
        match read {
            Ok((identity, bytes)) => {
                reply.set("present", true);
                reply.set("bytes", PackedByteArray::from(bytes.as_slice()));
                reply.set("identity", identity.as_str());
                reply
            }
            Err(error) => failed(error, "unavailable"),
        }
    }

    /// Gives the lock back; the guard can do nothing more.
    #[func]
    fn release(&mut self) {
        self.lock = None;
        self.also = None;
    }

    #[func]
    fn is_held(&self) -> bool {
        self.lock.is_some()
    }
}

fn failed(error: String, kind: &str) -> VarDictionary {
    let mut reply = VarDictionary::new();
    reply.set("error", error.as_str());
    reply.set("kind", kind);
    reply
}

// A staged file in `parent`: its path and identity; else why not, and the
// file left behind if one was created.
fn stage(parent: &Path, bytes: &[u8]) -> Result<(PathBuf, String), (String, Option<PathBuf>)> {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let dir = platform::directory(parent).map_err(|error| (error, None))?;
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    for _ in 0..16 {
        let name = format!(".docket-stage-{}-{nanos}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
        let path = dir.join(name);
        let mut file = match io::create_private(&path) {
            Ok(file) => file,
            Err(e) if e.kind() == ErrorKind::AlreadyExists => continue,
            Err(e) => return Err((format!("cannot create a file in {}: {e}", dir.display()), None)),
        };
        let staged = file
            .write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
            .and_then(|_| io::check_sole(&file, &path));
        return match staged {
            Ok(identity) => Ok((path, identity)),
            Err(error) => Err((error, Some(path))),
        };
    }
    Err((format!("cannot find an unused name in {}", dir.display()), None))
}

// "" when the file at `path` is `expected_id`, with no other names, holding
// exactly `bytes`, flushed to the device; else what differs.
fn holds(path: &Path, expected_id: &str, bytes: &[u8]) -> String {
    let file = match io::open_verify(path) {
        Ok(file) => file,
        Err(e) => return format!("cannot open {}: {e}", path.display()),
    };
    match io::check_sole(&file, path) {
        Ok(identity) if identity == expected_id => {}
        Ok(_) => return format!("{} is not the file staged", path.display()),
        Err(error) => return error,
    }
    // One byte past what is expected is enough to tell a longer file.
    let mut found = Vec::with_capacity(bytes.len() + 1);
    if let Err(e) = (&file).take(bytes.len() as u64 + 1).read_to_end(&mut found) {
        return format!("cannot read {}: {e}", path.display());
    }
    if found != bytes {
        return format!("{} does not hold what was staged", path.display());
    }
    match file.sync_all() {
        Ok(()) => String::new(),
        Err(e) => format!("cannot flush {}: {e}", path.display()),
    }
}

fn publish(stage: &Path, expected_id: &str, bytes: &[u8], dest: &Path) -> VarDictionary {
    let outcome = |status: &str, phase: &str, error: String| {
        let mut reply = VarDictionary::new();
        reply.set("status", status);
        reply.set("phase", phase);
        reply.set("error", error.as_str());
        reply
    };
    // The staged file, still the one staged and still what was written.
    let staged = match platform::existing(stage, false) {
        Ok(found) => found,
        Err(error) => return outcome("not_published", "verify_stage", error),
    };
    let differs = holds(&staged.path, expected_id, bytes);
    if !differs.is_empty() {
        return outcome("not_published", "verify_stage", differs);
    }
    // The destination: a new name in the same directory.
    let (name, parent) = match (dest.file_name(), dest.parent()) {
        (Some(name), Some(parent)) if !parent.as_os_str().is_empty() => (name, parent),
        _ => return outcome("not_published", "check_destination", format!("{} does not name a file", dest.display())),
    };
    let dir = match platform::directory(parent) {
        Ok(dir) => dir,
        Err(error) => return outcome("not_published", "check_destination", error),
    };
    if staged.path.parent() != Some(dir.as_path()) {
        return outcome("not_published", "check_destination", format!("{} is not in the directory of the file staged", dest.display()));
    }
    let target = dir.join(name);
    if let Err(e) = io::rename_no_clobber(&staged.path, &target) {
        let error = match e.kind() {
            ErrorKind::AlreadyExists => format!("{} already exists", target.display()),
            ErrorKind::Unsupported => format!("the file system of {} cannot publish a file without replacing one", dir.display()),
            _ => format!("cannot publish {}: {e}", target.display()),
        };
        return outcome("not_published", "publish", error);
    }
    // From here the name is taken and stays, whatever follows.
    if let Err(e) = io::sync_directory(&dir) {
        return outcome("published_durability_uncertain", "sync_directory", format!("cannot flush {}: {e}", dir.display()));
    }
    let differs = holds(&target, expected_id, bytes);
    if !differs.is_empty() {
        return outcome("published_durability_uncertain", "verify_published", differs);
    }
    let mut reply = outcome("published_durable", "done", String::new());
    reply.set("identity", expected_id);
    reply.set("path", godot_path(&target).as_str());
    reply
}

// `path` with its directory resolved and its name as given, so the sidecar
// stays beside the name AuditLog.read_entries reads.
fn resolved(path: &Path) -> Result<PathBuf, String> {
    match (path.file_name(), path.parent()) {
        (Some(name), Some(parent)) if !parent.as_os_str().is_empty() => Ok(platform::directory(parent)?.join(name)),
        _ => Err(format!("{} does not name a file", path.display())),
    }
}

// The lock key of the project file at `source` (resolved): its path with
// its case folded, as Windows and macOS file systems usually ignore it;
// where case matters, two names differing only in case merely share a lock.
fn lock_key(source: &Path) -> String {
    godot_path(source).to_lowercase()
}

// The audit lock file for `key` (lock_key) in the coordination directory,
// opened (and created once, never removed; a link or a file with other
// names there is refused, not replaced), named by a stable hash of the key.
fn lock_file(key: &str) -> Result<File, String> {
    let dir = coordination_dir()?;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325; // FNV-1a
    for byte in key.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    let path = dir.join(format!("audit-{hash:016x}.lock"));
    let file = io::open_lock(&path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
    io::check_sole(&file, &path)?;
    Ok(file)
}

#[cfg(unix)]
mod io {
    use crate::file_identity::platform;
    use std::fs::{File, OpenOptions};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::os::unix::io::AsRawFd;
    use std::path::Path;

    pub fn create_private(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
    }

    // Opens never follow a link, and O_NONBLOCK makes a pipe in a file's
    // place refused, not waited on.
    const NO_FOLLOW: libc::c_int = libc::O_NOFOLLOW | libc::O_NONBLOCK;

    pub fn open_read(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().read(true).custom_flags(NO_FOLLOW).open(path)
    }

    // fsync needs no more than read access.
    pub fn open_verify(path: &Path) -> std::io::Result<File> {
        open_read(path)
    }

    pub fn open_append(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().append(true).custom_flags(NO_FOLLOW).open(path)
    }

    pub fn open_lock(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).custom_flags(NO_FOLLOW).open(path)
    }

    pub fn create_audit(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().append(true).create_new(true).mode(0o600).open(path)
    }

    // The identity of the open `file` if it is a regular file with no other
    // names; else why not.
    pub fn check_sole(file: &File, path: &Path) -> Result<String, String> {
        let meta = file.metadata().map_err(|e| format!("cannot inspect {}: {e}", path.display()))?;
        if !meta.is_file() {
            return Err(format!("{} is not a file", path.display()));
        }
        if meta.nlink() != 1 {
            return Err(format!("{} has {} names", path.display(), meta.nlink()));
        }
        Ok(platform::identity(&meta))
    }

    pub fn sync_directory(dir: &Path) -> std::io::Result<()> {
        let file = File::open(dir)?;
        // SAFETY: the descriptor is open for the calls.
        #[cfg(target_os = "macos")]
        let full = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) } == 0;
        #[cfg(not(target_os = "macos"))]
        let full = false;
        if full {
            return Ok(());
        }
        if unsafe { libc::fsync(file.as_raw_fd()) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }

    fn c_path(path: &Path) -> std::io::Result<std::ffi::CString> {
        std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))
    }

    // An unsupported no-clobber move (the call, or the file system) is
    // ErrorKind::Unsupported; an existing destination AlreadyExists.
    fn classify(error: std::io::Error) -> std::io::Error {
        match error.raw_os_error() {
            Some(libc::EINVAL) | Some(libc::ENOSYS) | Some(libc::ENOTSUP) => std::io::Error::from(std::io::ErrorKind::Unsupported),
            _ => error,
        }
    }

    #[cfg(target_os = "linux")]
    pub fn rename_no_clobber(from: &Path, to: &Path) -> std::io::Result<()> {
        const RENAME_NOREPLACE: libc::c_uint = 1;
        let (from, to) = (c_path(from)?, c_path(to)?);
        // SAFETY: both paths are NUL-terminated for the call.
        let result = unsafe {
            libc::syscall(libc::SYS_renameat2, libc::AT_FDCWD, from.as_ptr(), libc::AT_FDCWD, to.as_ptr(), RENAME_NOREPLACE)
        };
        if result != 0 {
            return Err(classify(std::io::Error::last_os_error()));
        }
        Ok(())
    }

    #[cfg(target_os = "macos")]
    pub fn rename_no_clobber(from: &Path, to: &Path) -> std::io::Result<()> {
        extern "C" {
            fn renamex_np(from: *const libc::c_char, to: *const libc::c_char, flags: libc::c_uint) -> libc::c_int;
        }
        const RENAME_EXCL: libc::c_uint = 0x0000_0004;
        let (from, to) = (c_path(from)?, c_path(to)?);
        // SAFETY: both paths are NUL-terminated for the call.
        if unsafe { renamex_np(from.as_ptr(), to.as_ptr(), RENAME_EXCL) } != 0 {
            return Err(classify(std::io::Error::last_os_error()));
        }
        Ok(())
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    pub fn rename_no_clobber(_from: &Path, _to: &Path) -> std::io::Result<()> {
        Err(std::io::Error::from(std::io::ErrorKind::Unsupported))
    }
}

#[cfg(windows)]
mod io {
    use crate::coord_dir::windows_owner;
    use crate::file_identity::platform;
    use std::fs::{File, OpenOptions};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::{AsRawHandle, FromRawHandle};
    use std::path::Path;
    use windows_sys::core::PWSTR;
    use windows_sys::Win32::Foundation::{LocalFree, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, MoveFileExW, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
        FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_WRITE_DATA, MOVEFILE_WRITE_THROUGH,
    };

    // Writing at the end only, as std's append does, and reading the
    // attributes check_sole asks for.
    const APPEND: u32 = (FILE_GENERIC_WRITE & !FILE_WRITE_DATA) | FILE_READ_ATTRIBUTES;
    const WRITE: u32 = FILE_GENERIC_WRITE | FILE_READ_ATTRIBUTES;

    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str().encode_wide().chain(std::iter::once(0)).collect()
    }

    // A file created only if absent, with an access list of its own (this
    // account, SYSTEM and Administrators) marked protected, so nothing is
    // inherited from its directory.
    fn create_private_with(path: &Path, access: u32) -> std::io::Result<File> {
        let user = windows_owner::process_user().map_err(std::io::Error::other)?;
        let mut text: PWSTR = std::ptr::null_mut();
        // SAFETY: `text` is written by the call and freed below.
        if unsafe { ConvertSidToStringSidW(user.sid(), &mut text) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `text` is the NUL-terminated string the call allocated.
        let sid = unsafe {
            let length = (0..).take_while(|&i| *text.add(i) != 0).count();
            let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
            LocalFree(text.cast());
            sid
        };
        let sddl: Vec<u16> = format!("D:P(A;;FA;;;{sid})(A;;FA;;;SY)(A;;FA;;;BA)").encode_utf16().chain(std::iter::once(0)).collect();
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: `sddl` is NUL-terminated; `descriptor` is freed below.
        if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, std::ptr::null_mut()) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        let attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let name = wide(path);
        // SAFETY: `name` is NUL-terminated and `attributes` lives through the call.
        let raw = unsafe {
            CreateFileW(
                name.as_ptr(),
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                &attributes,
                CREATE_NEW,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
                std::ptr::null_mut(),
            )
        };
        let error = std::io::Error::last_os_error();
        // SAFETY: allocated by the conversion above, freed once.
        unsafe { LocalFree(descriptor) };
        if raw == INVALID_HANDLE_VALUE {
            return Err(error);
        }
        // SAFETY: `raw` is a handle just opened, owned by the File from here.
        Ok(unsafe { File::from_raw_handle(raw as _) })
    }

    pub fn create_private(path: &Path) -> std::io::Result<File> {
        create_private_with(path, WRITE)
    }

    pub fn create_audit(path: &Path) -> std::io::Result<File> {
        create_private_with(path, APPEND)
    }

    pub fn open_read(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().read(true).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(path)
    }

    // Read, and the write access FlushFileBuffers needs.
    pub fn open_verify(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().access_mode(FILE_GENERIC_READ | WRITE).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(path)
    }

    pub fn open_append(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().access_mode(APPEND).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(path)
    }

    pub fn open_lock(path: &Path) -> std::io::Result<File> {
        OpenOptions::new().read(true).write(true).create(true).truncate(false).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(path)
    }

    pub fn check_sole(file: &File, path: &Path) -> Result<String, String> {
        let facts = platform::facts(file.as_raw_handle() as _)?;
        if facts.link || facts.directory {
            return Err(format!("{} is not a plain file", path.display()));
        }
        if facts.links != 1 {
            return Err(format!("{} has {} names", path.display(), facts.links));
        }
        Ok(facts.id)
    }

    // The move is made with WRITE_THROUGH; there is no directory flush.
    pub fn sync_directory(_dir: &Path) -> std::io::Result<()> {
        Ok(())
    }

    pub fn rename_no_clobber(from: &Path, to: &Path) -> std::io::Result<()> {
        let (from, to) = (wide(from), wide(to));
        // SAFETY: both paths are NUL-terminated for the call.
        if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}
