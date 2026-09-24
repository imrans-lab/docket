//! Where every Docket process of one OS account coordinates: a fixed directory
//! per account, the same for the Docket app, hosts that embed it and headless
//! runs alike.
//!
//! It is found from the OS itself, never from HOME, XDG variables or a Godot
//! project's user:// directory, since those can differ between processes of
//! the same account and would split them into separate lock domains:
//!
//! - Linux: `<account home>/.local/state/docket/coordination`
//! - macOS: `<account home>/Library/Application Support/Docket/coordination`
//! - Windows: `<FOLDERID_LocalAppData>/Docket/coordination`
//!
//! The account home comes from the OS account database. There is no override
//! and no fallback: if it cannot be found or created, coordination fails, and
//! stays failed until the process restarts.
//!
//! A host may state the directory it expects (`expect`). A different one
//! fails coordination for the rest of the process rather than redirecting it.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

// Resolved once per process; later calls report the same answer.
static DIR: OnceLock<Result<PathBuf, String>> = OnceLock::new();
// Set by the first expected directory that did not match; never cleared.
static MISMATCH: OnceLock<String> = OnceLock::new();

/// The coordination directory, created private to the account if missing.
pub fn coordination_dir() -> Result<PathBuf, String> {
    if let Some(mismatch) = mismatch() {
        return Err(mismatch);
    }
    resolved()
}

/// Why coordination is off for this process after a host's expected
/// directory did not match, if it is.
pub fn mismatch() -> Option<String> {
    MISMATCH.get().cloned()
}

fn resolved() -> Result<PathBuf, String> {
    DIR.get_or_init(|| {
        let dir = platform_dir()?;
        create_private(&dir)?;
        Ok(dir)
    })
    .clone()
}

/// Checks that the coordination directory is `expected`, as a host resolved
/// it: the same directory, however the path is spelled. If it is not,
/// coordination fails from now on in this process.
pub fn expect(expected: &Path) -> Result<(), String> {
    if let Some(mismatch) = mismatch() {
        return Err(mismatch);
    }
    let dir = resolved()?;
    if same_directory(&dir, expected) {
        return Ok(());
    }
    let mismatch = format!(
        "the coordination directory is {}, not {} as this host expects; coordination is off until it restarts",
        dir.display(),
        expected.display()
    );
    Err(MISMATCH.get_or_init(|| mismatch).clone())
}

#[cfg(unix)]
fn same_directory(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

#[cfg(windows)]
fn same_directory(a: &Path, b: &Path) -> bool {
    match (windows_owner::identity(a), windows_owner::identity(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

#[cfg(target_os = "linux")]
fn platform_dir() -> Result<PathBuf, String> {
    Ok(account_home()?.join(".local/state/docket/coordination"))
}

#[cfg(target_os = "macos")]
fn platform_dir() -> Result<PathBuf, String> {
    Ok(account_home()?.join("Library/Application Support/Docket/coordination"))
}

#[cfg(windows)]
fn platform_dir() -> Result<PathBuf, String> {
    Ok(local_app_data()?.join("Docket").join("coordination"))
}

#[cfg(unix)]
fn account_home() -> Result<PathBuf, String> {
    use std::ffi::CStr;
    use std::os::unix::ffi::OsStrExt;

    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    loop {
        // SAFETY: every pointer refers to storage owned here and sized as passed.
        let status = unsafe {
            libc::getpwuid_r(libc::geteuid(), &mut entry, buffer.as_mut_ptr(), buffer.len(), &mut found)
        };
        match status {
            0 => break,
            libc::ERANGE if buffer.len() < 1024 * 1024 => buffer.resize(buffer.len() * 2, 0),
            _ => {
                let error = std::io::Error::from_raw_os_error(status);
                return Err(format!("cannot read this account from the OS account database: {error}"));
            }
        }
    }
    if found.is_null() || entry.pw_dir.is_null() {
        return Err("the OS account database has no home directory for this account".to_string());
    }
    // SAFETY: pw_dir points into `buffer`, NUL-terminated by getpwuid_r.
    let home = unsafe { CStr::from_ptr(entry.pw_dir) };
    let home = PathBuf::from(std::ffi::OsStr::from_bytes(home.to_bytes()));
    if !home.is_absolute() {
        return Err(format!("the account's home directory is not absolute: {}", home.display()));
    }
    Ok(home)
}

#[cfg(windows)]
fn local_app_data() -> Result<PathBuf, String> {
    use std::os::windows::ffi::OsStringExt;
    use windows_sys::Win32::System::Com::CoTaskMemFree;
    use windows_sys::Win32::UI::Shell::{FOLDERID_LocalAppData, SHGetKnownFolderPath, KF_FLAG_DEFAULT};

    let mut raw: windows_sys::core::PWSTR = std::ptr::null_mut();
    // SAFETY: SHGetKnownFolderPath allocates `raw`, freed below in every case.
    let status = unsafe { SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_DEFAULT as u32, std::ptr::null_mut(), &mut raw) };
    let result = if status == 0 && !raw.is_null() {
        // SAFETY: on success `raw` is a NUL-terminated UTF-16 string.
        let len = unsafe { (0..).take_while(|&i| *raw.add(i) != 0).count() };
        let wide = unsafe { std::slice::from_raw_parts(raw, len) };
        Ok(PathBuf::from(std::ffi::OsString::from_wide(wide)))
    } else {
        Err(format!("Windows did not report the local application data folder (0x{status:08x})"))
    };
    unsafe { CoTaskMemFree(raw as *const _) };
    result
}

// The directory must be a real one owned by this account; an existing one
// that is not is refused rather than repaired.
#[cfg(unix)]
fn create_private(dir: &PathBuf) -> Result<(), String> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("cannot create the coordination directory {}: {e}", dir.display()))?;
    let found = std::fs::symlink_metadata(dir).map_err(|e| format!("cannot inspect {}: {e}", dir.display()))?;
    // SAFETY: geteuid has no preconditions.
    if !found.is_dir() || found.uid() != unsafe { libc::geteuid() } {
        return Err(format!("{} is not a directory owned by this account", dir.display()));
    }
    // A directory that already existed keeps its mode; make sure it is private.
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("cannot make {} private: {e}", dir.display()))
}

// Local application data is private to the account (and, like all of it, to
// SYSTEM and Administrators). The directory and its Docket parent must also
// be real directories (no junction or other reparse point, which could lead
// elsewhere) owned by this account, or by SYSTEM or Administrators, which own
// what an elevated process creates and are trusted more than the account.
// Each is checked before anything is created inside it. Only the owner is
// checked, not the access list: a directory made beforehand by its owner with
// access for other accounts would pass.
#[cfg(windows)]
fn create_private(dir: &PathBuf) -> Result<(), String> {
    let user = windows_owner::process_user()?;
    let parent = dir.parent().ok_or_else(|| format!("{} has no parent directory", dir.display()))?;
    for path in [parent, dir.as_path()] {
        match std::fs::create_dir(path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(format!("cannot create the coordination directory {}: {e}", path.display())),
        }
        windows_owner::check_directory(path, &user)?;
    }
    Ok(())
}

#[cfg(windows)]
mod windows_owner {
    use std::os::windows::ffi::OsStrExt;
    use std::path::Path;
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Security::Authorization::{GetSecurityInfo, SE_FILE_OBJECT};
    use windows_sys::Win32::Security::{
        EqualSid, GetTokenInformation, IsWellKnownSid, TokenUser, WinBuiltinAdministratorsSid, WinLocalSystemSid,
        OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, TOKEN_QUERY, TOKEN_USER,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION, FILE_ATTRIBUTE_DIRECTORY,
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE,
        FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING, READ_CONTROL,
    };
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    // Closes a handle when dropped.
    struct Handle(HANDLE);

    impl Drop for Handle {
        fn drop(&mut self) {
            // SAFETY: the handle was opened here and is closed once.
            unsafe { CloseHandle(self.0) };
        }
    }

    /// The process user's TOKEN_USER, kept as the buffer holding it and its
    /// SID; usize elements keep it aligned for the pointer TOKEN_USER holds.
    pub struct User(Vec<usize>);

    impl User {
        fn sid(&self) -> PSID {
            // SAFETY: the buffer was filled by GetTokenInformation(TokenUser).
            unsafe { (*(self.0.as_ptr() as *const TOKEN_USER)).User.Sid }
        }
    }

    pub fn process_user() -> Result<User, String> {
        let mut token: HANDLE = std::ptr::null_mut();
        // SAFETY: GetCurrentProcess returns a pseudo-handle; `token` is written.
        if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
            return Err("cannot read this process's account".to_string());
        }
        let token = Handle(token);
        let mut size = 0u32;
        // SAFETY: a size query with no buffer.
        unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut size) };
        let mut buffer = vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
        // SAFETY: `buffer` has the size just reported.
        if size == 0 || unsafe { GetTokenInformation(token.0, TokenUser, buffer.as_mut_ptr().cast(), size, &mut size) } == 0 {
            return Err("cannot read this process's account".to_string());
        }
        Ok(User(buffer))
    }

    // The directory itself, never what a reparse point leads to.
    fn open_directory(path: &Path) -> Result<(Handle, BY_HANDLE_FILE_INFORMATION), String> {
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        // SAFETY: `wide` is NUL-terminated; the handle is closed by `Handle`.
        let raw = unsafe {
            CreateFileW(
                wide.as_ptr(),
                READ_CONTROL,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                std::ptr::null_mut(),
            )
        };
        if raw == INVALID_HANDLE_VALUE {
            return Err(format!("cannot open {}", path.display()));
        }
        let handle = Handle(raw);
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        // SAFETY: `info` is written by the call.
        if unsafe { GetFileInformationByHandle(handle.0, &mut info) } == 0 {
            return Err(format!("cannot inspect {}", path.display()));
        }
        if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 || info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
            return Err(format!("{} is not a plain directory", path.display()));
        }
        Ok((handle, info))
    }

    /// What identifies a directory on this machine: its volume and file index.
    pub fn identity(path: &Path) -> Result<(u32, u32, u32), String> {
        let (_, info) = open_directory(path)?;
        Ok((info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow))
    }

    pub fn check_directory(path: &Path, user: &User) -> Result<(), String> {
        let (handle, _) = open_directory(path)?;
        let mut owner: PSID = std::ptr::null_mut();
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: `owner` points into `descriptor`, freed below after use.
        let status = unsafe {
            GetSecurityInfo(
                handle.0,
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION,
                &mut owner,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor,
            )
        };
        // SAFETY: `owner` is a valid SID inside `descriptor` when status is 0.
        let owned = status == 0
            && !owner.is_null()
            && unsafe {
                EqualSid(owner, user.sid()) != 0
                    || IsWellKnownSid(owner, WinBuiltinAdministratorsSid) != 0
                    || IsWellKnownSid(owner, WinLocalSystemSid) != 0
            };
        if !descriptor.is_null() {
            unsafe { LocalFree(descriptor) };
        }
        if !owned {
            return Err(format!("{} is not owned by this account", path.display()));
        }
        Ok(())
    }
}
