//! The system credential store, where the vault password is kept as a tagged
//! record (CoordRecord in GDScript) under one of three fixed accounts.
//!
//! - Linux: Secret Service, the account's persistent default collection only.
//! - macOS: the account's default keychain (normally the login keychain),
//!   as generic passwords.
//! - Windows: Credential Manager, as generic credentials.
//!
//! Every call runs inside a coordination operation (coord_lock) and keeps it
//! held until the store has answered: reads need any operation, changes an
//! EXCLUSIVE one. Nothing here asks the user anything: a locked store, or one
//! that wants confirmation, is reported and the request dropped. The store is
//! reached only when called, so the extension loads, and the lock works,
//! without one.
//!
//! Failures come back as a kind: "no_store" (no usable store for this
//! account), "unreachable" (it did not answer in time; for a write or removal
//! the outcome is then unknown, marked "indeterminate"), "locked", "denied",
//! "not_found" (it answered, and has no such entry), "refused" (a request
//! that can never succeed) or "other". Values never appear in messages.

use crate::coord_lock::{begin, end, failure, DocketCoordOperation, Failure, EXCLUSIVE, SHARED};
use godot::prelude::*;

const SERVICE: &str = "Docket";
const ACCOUNTS: [&str; 3] = ["vault-password", "vault-rotation-old", "vault-rotation-new"];

/// GDScript's handle on the store. Results are {ok: true, ...} on success,
/// {error, kind} on failure.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct DocketCredentialStore;

#[godot_api]
impl DocketCredentialStore {
    /// {ok, value}: the value stored under `account`, within `operation` (a
    /// DocketCoordOperation).
    #[func]
    fn read(&self, account: GString, operation: Option<Gd<DocketCoordOperation>>) -> VarDictionary {
        let account = account.to_string();
        reply(within(operation, SHARED, &account, || platform::read(&account)).map(Some))
    }

    /// Stores `value` under `account`, replacing what was there, within
    /// EXCLUSIVE `operation`. A failure marked indeterminate may still have
    /// stored it.
    #[func]
    fn write(&self, account: GString, value: GString, operation: Option<Gd<DocketCoordOperation>>) -> VarDictionary {
        let account = account.to_string();
        let value = value.to_string();
        changed(within(operation, EXCLUSIVE, &account, || platform::write(&account, &value)))
    }

    /// Removes `account`'s entry, within EXCLUSIVE `operation`; an entry
    /// that is already absent is kind "not_found". A failure marked
    /// indeterminate may still have removed it.
    #[func]
    fn remove(&self, account: GString, operation: Option<Gd<DocketCoordOperation>>) -> VarDictionary {
        let account = account.to_string();
        changed(within(operation, EXCLUSIVE, &account, || platform::remove(&account)))
    }

    /// Whether the store can be used now, within `operation`: {ok} or the
    /// failure that stops it. A diagnostic only; the next call may still fail.
    #[func]
    fn status(&self, operation: Option<Gd<DocketCoordOperation>>) -> VarDictionary {
        let probe = within(operation, SHARED, ACCOUNTS[0], || match platform::read(ACCOUNTS[0]) {
            Ok(_) => Ok(()),
            Err(f) if f.kind == "not_found" => Ok(()),
            Err(f) => Err(f),
        });
        reply(probe.map(|_| None))
    }
}

// A change that ran out of time may still be carried out by the store, so
// its failure also says the outcome is unknown: {indeterminate: true}.
fn changed(result: Result<(), Failure>) -> VarDictionary {
    let indeterminate = matches!(&result, Err(f) if f.kind == "unreachable");
    let mut dictionary = reply(result.map(|_| None));
    if indeterminate {
        dictionary.set("indeterminate", true);
    }
    dictionary
}

fn reply(result: Result<Option<String>, Failure>) -> VarDictionary {
    let mut dictionary = VarDictionary::new();
    match result {
        Ok(value) => {
            dictionary.set("ok", true);
            if let Some(value) = value {
                dictionary.set("value", value.as_str());
            }
        }
        Err(f) => {
            dictionary.set("error", f.message.as_str());
            dictionary.set("kind", f.kind);
        }
    }
    dictionary
}

// Ends a nested step when dropped, so a panic in the store call still gives
// the operation back.
struct Step(i64);

impl Drop for Step {
    fn drop(&mut self) {
        let _ = end(self.0);
    }
}

// Runs `work` as a nested step of `operation`, so the operation stays held
// until the store has answered even if its owner closes it meanwhile.
fn within<T>(
    operation: Option<Gd<DocketCoordOperation>>,
    mode: i64,
    account: &str,
    work: impl FnOnce() -> Result<T, Failure>,
) -> Result<T, Failure> {
    if !ACCOUNTS.contains(&account) {
        return Err(failure("refused", format!("'{account}' is not a Docket credential account")));
    }
    let Some(operation) = operation else {
        return Err(failure("refused", "the credential store is used only within a coordination operation"));
    };
    let id = operation.bind().live_id()?;
    let _step = Step(begin(mode, id)?);
    work()
}

fn not_text(account: &str) -> Failure {
    failure("other", format!("the '{account}' credential is not text"))
}

#[cfg(target_os = "linux")]
mod platform {
    //! Secret Service through the `secret-service` crate, in an encrypted
    //! (DH) session only, never falling back to a plain one. Each call runs
    //! on a single-threaded runtime of its own, within one deadline for all
    //! of it (connecting included); the runtime is shut down before the call
    //! returns. The crate is a copy patched never to show a prompt: one the
    //! service asks for is dismissed and the request refused.
    //!
    //! A change that runs out of time may still be carried out by the service
    //! afterwards, so its outcome is unknown ("indeterminate").

    use super::{failure, not_text, Failure, SERVICE};
    use secret_service::{Collection, EncryptionType, Error, SecretService};
    use std::collections::HashMap;
    use std::future::Future;
    use std::time::Duration;
    use tokio::time::{timeout_at, Instant};

    const DEADLINE: Duration = Duration::from_secs(8);
    // Each D-Bus call as well, so no single one uses the whole deadline.
    const METHOD_TIMEOUT: Duration = Duration::from_secs(3);
    const CLEANUP: Duration = Duration::from_millis(250);
    // The in-memory collection some services offer; it does not persist.
    const SESSION_COLLECTION: &str = "/org/freedesktop/secrets/collection/session";
    // Keeps Docket's entries apart from other applications' attributes.
    const SCHEMA: &str = "org.docket.Vault";

    fn unreachable() -> Failure {
        failure("unreachable", "the Secret Service did not answer in time")
    }

    fn kind(error: Error) -> Failure {
        match error {
            Error::Unavailable | Error::NoResult => failure("no_store", "no Secret Service with a persistent default collection is available"),
            Error::Locked => failure("locked", "the Secret Service collection is locked"),
            Error::Prompt | Error::PromptDisconnected => {
                failure("denied", "the Secret Service wanted confirmation, which Docket does not ask for")
            }
            Error::Zbus(e) => zbus_kind(&e),
            // The conversion unwraps an fdo error that only carries a zbus one,
            // such as a timed-out property read.
            Error::ZbusFdo(e) => zbus_kind(&zbus::Error::from(e)),
            _ => failure("other", "the Secret Service gave an unreadable answer"),
        }
    }

    fn zbus_kind(error: &zbus::Error) -> Failure {
        let name = match error {
            zbus::Error::InputOutput(e) if e.kind() == std::io::ErrorKind::TimedOut => return unreachable(),
            zbus::Error::InputOutput(_) | zbus::Error::Handshake(_) | zbus::Error::Connection(_, _) => {
                return failure("unreachable", "the connection to the Secret Service failed")
            }
            zbus::Error::MethodError(name, _, _) => name.as_str().to_string(),
            zbus::Error::FDO(e) => zbus::DBusError::name(e.as_ref()).as_str().to_string(),
            _ => String::new(),
        };
        match name.as_str() {
            "org.freedesktop.Secret.Error.IsLocked" => failure("locked", "the Secret Service collection is locked"),
            "org.freedesktop.DBus.Error.ServiceUnknown" | "org.freedesktop.DBus.Error.NameHasNoOwner" => {
                failure("no_store", "no Secret Service is running for this account")
            }
            "org.freedesktop.DBus.Error.AccessDenied" => failure("denied", "the Secret Service refused access"),
            "org.freedesktop.DBus.Error.NotSupported" => {
                failure("refused", "the Secret Service does not offer an encrypted session")
            }
            "org.freedesktop.DBus.Error.NoReply" | "org.freedesktop.DBus.Error.TimedOut" => unreachable(),
            _ => failure("other", "the Secret Service failed"),
        }
    }

    // Runs `work` to completion or the deadline on a runtime of its own.
    fn run<T>(work: impl Future<Output = Result<T, Failure>>) -> Result<T, Failure> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()
            .map_err(|_| failure("other", "the Secret Service client could not start"))?;
        let result = runtime.block_on(async {
            let deadline = Instant::now() + DEADLINE;
            timeout_at(deadline, work).await.unwrap_or_else(|_| Err(unreachable()))
        });
        runtime.shutdown_timeout(CLEANUP);
        result
    }

    // The account's session bus socket: a filesystem Unix socket only (no
    // TCP, no launching a bus, no abstract socket).
    fn bus_socket() -> Result<String, Failure> {
        let address = match std::env::var("DBUS_SESSION_BUS_ADDRESS") {
            Ok(address) => address,
            Err(_) => match std::env::var("XDG_RUNTIME_DIR") {
                Ok(runtime_dir) if std::path::Path::new(&runtime_dir).is_absolute() => {
                    return Ok(format!("{runtime_dir}/bus"))
                }
                _ => return Err(failure("no_store", "this account has no session bus")),
            },
        };
        let first = address.split(';').next().unwrap_or_default();
        let path = first
            .strip_prefix("unix:")
            .and_then(|options| options.split(',').find_map(|option| option.strip_prefix("path=")))
            .and_then(unescape)
            .ok_or_else(|| failure("no_store", "this account's session bus is not a local socket Docket can use"))?;
        if !std::path::Path::new(&path).is_absolute() {
            return Err(failure("no_store", "this account's session bus is not a local socket Docket can use"));
        }
        Ok(path)
    }

    // D-Bus address values escape bytes as %XX.
    fn unescape(value: &str) -> Option<String> {
        let bytes = value.as_bytes();
        let mut out = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'%' {
                let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            } else {
                out.push(bytes[i]);
                i += 1;
            }
        }
        String::from_utf8(out).ok()
    }

    async fn service() -> Result<SecretService<'static>, Failure> {
        // Connected here, without blocking, so the deadline can always end it.
        let stream = tokio::net::UnixStream::connect(bus_socket()?).await.map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => {
                failure("no_store", "no session bus is running for this account")
            }
            _ => failure("unreachable", "the session bus could not be reached"),
        })?;
        let bus = zbus::connection::Builder::unix_stream(stream)
            .method_timeout(METHOD_TIMEOUT)
            .build()
            .await
            .map_err(|e| zbus_kind(&e))?;
        SecretService::connect_with_existing(EncryptionType::Dh, bus).await.map_err(kind)
    }

    // The persistent default collection, refused while locked: unlocking it
    // would prompt.
    async fn collection<'a>(service: &'a SecretService<'a>) -> Result<Collection<'a>, Failure> {
        let collection = service.get_default_collection().await.map_err(kind)?;
        // An unknown alias is NoResult; any other failure could hide a session
        // collection, so it refuses.
        let session = match service.get_collection_by_alias("session").await {
            Ok(session) => Some(session.collection_path.clone()),
            Err(Error::NoResult) => None,
            Err(error) => return Err(kind(error)),
        };
        if collection.collection_path.as_str() == SESSION_COLLECTION || session.as_ref() == Some(&collection.collection_path) {
            return Err(kind(Error::NoResult));
        }
        if collection.is_locked().await.map_err(kind)? {
            return Err(kind(Error::Locked));
        }
        Ok(collection)
    }

    fn attributes(account: &str) -> HashMap<&str, &str> {
        HashMap::from([("xdg:schema", SCHEMA), ("service", SERVICE), ("account", account)])
    }

    fn not_found(account: &str) -> Failure {
        failure("not_found", format!("no '{account}' credential is stored"))
    }

    fn several(account: &str) -> Failure {
        failure("other", format!("several '{account}' credentials are stored"))
    }

    pub fn read(account: &str) -> Result<String, Failure> {
        run(async {
            let service = service().await?;
            let collection = collection(&service).await?;
            let items = collection.search_items(attributes(account)).await.map_err(kind)?;
            let item = match items.as_slice() {
                [] => return Err(not_found(account)),
                [item] => item,
                _ => return Err(several(account)),
            };
            if item.is_locked().await.map_err(kind)? {
                return Err(kind(Error::Locked));
            }
            let secret = item.get_secret().await.map_err(kind)?;
            String::from_utf8(secret).map_err(|_| not_text(account))
        })
    }

    pub fn write(account: &str, value: &str) -> Result<(), Failure> {
        run(async {
            let service = service().await?;
            let collection = collection(&service).await?;
            // Replacing updates one match and leaves the others, so several
            // are refused before anything changes.
            if collection.search_items(attributes(account)).await.map_err(kind)?.len() > 1 {
                return Err(several(account));
            }
            let label = format!("Docket {account}");
            collection
                .create_item(&label, attributes(account), value.as_bytes(), true, "text/plain")
                .await
                .map(|_| ())
                .map_err(kind)
        })
    }

    pub fn remove(account: &str) -> Result<(), Failure> {
        run(async {
            let service = service().await?;
            let collection = collection(&service).await?;
            let items = collection.search_items(attributes(account)).await.map_err(kind)?;
            match items.as_slice() {
                [] => Err(not_found(account)),
                [item] => item.delete().await.map_err(kind),
                _ => Err(several(account)),
            }
        })
    }
}

#[cfg(target_os = "macos")]
mod platform {
    //! Generic passwords in the account's default keychain, and only there:
    //! other keychains in the search list (a mounted backup, say) are never
    //! read or changed. The keychain's no-prompt switch is global to the
    //! process, so calls are serialised while Docket has it off, and a host
    //! that already had it off keeps it that way.

    use super::{failure, not_text, Failure, SERVICE};
    use core_foundation::base::TCFType;
    use security_framework::base::Error;
    use security_framework::os::macos::keychain::SecKeychain;
    use security_framework::os::macos::keychain_item::SecKeychainItem;
    use security_framework_sys::keychain_item::SecKeychainItemDelete;
    use std::sync::{Mutex, PoisonError};

    // Status codes from Apple's SecBase.h.
    const ITEM_NOT_FOUND: i32 = -25300;
    const INTERACTION_NOT_ALLOWED: i32 = -25308;
    const AUTH_FAILED: i32 = -25293;
    const NO_SUCH_KEYCHAIN: i32 = -25294;
    const NO_DEFAULT_KEYCHAIN: i32 = -25307;
    const NOT_AVAILABLE: i32 = -25291;

    static QUIET: Mutex<()> = Mutex::new(());

    fn kind(error: Error, account: &str) -> Failure {
        match error.code() {
            ITEM_NOT_FOUND => failure("not_found", format!("no '{account}' credential is stored")),
            // Also what a keychain entry made by another application answers
            // when it would need the user's confirmation.
            INTERACTION_NOT_ALLOWED => failure("locked", "the keychain is locked, or wants confirmation Docket does not ask for"),
            AUTH_FAILED => failure("denied", "the keychain refused access"),
            NO_SUCH_KEYCHAIN | NO_DEFAULT_KEYCHAIN | NOT_AVAILABLE => {
                failure("no_store", "no keychain is available for this account")
            }
            code => failure("other", format!("the keychain failed ({code})")),
        }
    }

    // Runs `work` on the default keychain; calls that would show a dialog fail
    // instead while it runs.
    fn quietly<T>(account: &str, work: impl FnOnce(&SecKeychain) -> Result<T, Error>) -> Result<T, Failure> {
        let _serialised = QUIET.lock().unwrap_or_else(PoisonError::into_inner);
        let allowed = SecKeychain::user_interaction_allowed().map_err(|e| kind(e, account))?;
        // Dropping the lock turns interaction back on, so it is taken only
        // when interaction was on to begin with.
        let _no_prompts = if allowed {
            Some(SecKeychain::disable_user_interaction().map_err(|e| kind(e, account))?)
        } else {
            None
        };
        let keychain = SecKeychain::default().map_err(|e| kind(e, account))?;
        work(&keychain).map_err(|e| kind(e, account))
    }

    fn found(keychain: &SecKeychain, account: &str) -> Result<Option<(Vec<u8>, SecKeychainItem)>, Error> {
        match keychain.find_generic_password(SERVICE, account) {
            Ok((password, item)) => Ok(Some((password.to_vec(), item))),
            Err(e) if e.code() == ITEM_NOT_FOUND => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub fn read(account: &str) -> Result<String, Failure> {
        let secret = quietly(account, |keychain| {
            found(keychain, account)?.map(|(password, _)| password).ok_or_else(|| Error::from_code(ITEM_NOT_FOUND))
        })?;
        String::from_utf8(secret).map_err(|_| not_text(account))
    }

    pub fn write(account: &str, value: &str) -> Result<(), Failure> {
        quietly(account, |keychain| match found(keychain, account)? {
            Some((_, mut item)) => item.set_password(value.as_bytes()),
            None => keychain.add_generic_password(SERVICE, account, value.as_bytes()),
        })
    }

    pub fn remove(account: &str) -> Result<(), Failure> {
        quietly(account, |keychain| {
            let (_, item) = found(keychain, account)?.ok_or_else(|| Error::from_code(ITEM_NOT_FOUND))?;
            // SAFETY: `item` is a live keychain item reference.
            match unsafe { SecKeychainItemDelete(item.as_concrete_TypeRef()) } {
                0 => Ok(()),
                code => Err(Error::from_code(code)),
            }
        })
    }
}

#[cfg(windows)]
mod platform {
    //! Credential Manager generic credentials, kept on this machine only.

    use super::{failure, not_text, Failure, SERVICE};
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND, ERROR_NO_SUCH_LOGON_SESSION};
    use windows_sys::Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }

    fn target(account: &str) -> Vec<u16> {
        wide(&format!("{SERVICE}/{account}"))
    }

    fn last_error(account: &str) -> Failure {
        // SAFETY: GetLastError has no preconditions.
        match unsafe { GetLastError() } {
            ERROR_NOT_FOUND => failure("not_found", format!("no '{account}' credential is stored")),
            ERROR_NO_SUCH_LOGON_SESSION => failure("no_store", "this session has no Credential Manager"),
            code => failure("other", format!("Credential Manager failed ({code})")),
        }
    }

    pub fn read(account: &str) -> Result<String, Failure> {
        let target = target(account);
        let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
        // SAFETY: `target` is NUL-terminated; CredReadW allocates `credential`,
        // freed below once its blob has been copied.
        if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) } == 0 {
            return Err(last_error(account));
        }
        let blob = unsafe {
            let c = &*credential;
            if c.CredentialBlobSize == 0 || c.CredentialBlob.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize).to_vec()
            }
        };
        unsafe { CredFree(credential as *const _) };
        String::from_utf8(blob).map_err(|_| not_text(account))
    }

    pub fn write(account: &str, value: &str) -> Result<(), Failure> {
        let mut target = target(account);
        let mut user = wide("Docket");
        let mut blob = value.as_bytes().to_vec();
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: target.as_mut_ptr(),
            UserName: user.as_mut_ptr(),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            ..Default::default()
        };
        // SAFETY: every pointer in `credential` refers to a buffer alive here.
        if unsafe { CredWriteW(&credential, 0) } == 0 {
            return Err(last_error(account));
        }
        Ok(())
    }

    pub fn remove(account: &str) -> Result<(), Failure> {
        let target = target(account);
        // SAFETY: `target` is NUL-terminated.
        if unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } == 0 {
            return Err(last_error(account));
        }
        Ok(())
    }
}
