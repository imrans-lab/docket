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

use std::path::PathBuf;
use std::sync::OnceLock;

// Resolved once per process; later calls report the same answer.
static DIR: OnceLock<Result<PathBuf, String>> = OnceLock::new();

/// The coordination directory, created with user-only access if missing.
pub fn coordination_dir() -> Result<PathBuf, String> {
    DIR.get_or_init(|| {
        let dir = platform_dir()?;
        create_private(&dir)?;
        Ok(dir)
    })
    .clone()
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

// Local application data is already private to the account.
#[cfg(windows)]
fn create_private(dir: &PathBuf) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("cannot create the coordination directory {}: {e}", dir.display()))
}
