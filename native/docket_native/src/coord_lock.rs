//! The cross-process lock every Docket process of one OS account coordinates
//! vault administration and project writes through.
//!
//! One lock file in the account's coordination directory (coord_dir), locked
//! with the operating system's advisory file locks: SHARED for ordinary work,
//! EXCLUSIVE for vault administration. SHARED holders do not exclude each
//! other, only administration. The file is only ever opened, never removed,
//! renamed or replaced, so every process locks the same file. The OS drops a
//! process's lock when it exits, however it exits (on Windows possibly a
//! moment later, which the polling absorbs).
//!
//! Within a process, the lock is held for logical operations. `begin` starts
//! one and returns its id; a nested step of the same operation passes that id
//! and reuses its hold, and `end` gives it back. A caller that does not pass
//! the id is a different operation: it shares a SHARED hold, but waits for
//! an EXCLUSIVE one like any other process, so no unrelated callback or thread
//! ever acts under another operation's administration. Asking for EXCLUSIVE
//! within a SHARED operation is refused at once rather than upgraded. The
//! file is locked once per process and unlocked when the last operation ends;
//! an operation's hold lasts until `end`, whatever its caller stopped waiting
//! for.
//!
//! An operation id is a bearer token: whoever holds it acts as that operation,
//! and nothing checks who they are. Its owner passes it only to the steps and
//! workers of that same operation, never to unrelated code, and a worker it is
//! handed to keeps the operation until that worker's own step has ended.
//!
//! Waiting is not fair: a stream of SHARED operations can keep an EXCLUSIVE
//! one waiting until it reports busy. A wait blocks its thread for up to the
//! deadline, so an operation must not hold EXCLUSIVE while it waits on the
//! thread that would wait for it (Godot's main thread, say).

use crate::coord_dir::coordination_dir;
use godot::prelude::*;
use std::collections::BTreeMap;
use std::fs::{File, OpenOptions, TryLockError};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::thread::sleep;
use std::time::{Duration, Instant};

pub(crate) const SHARED: i64 = 0;
pub(crate) const EXCLUSIVE: i64 = 1;
const LOCK_FILE: &str = "docket_coord.lock";
const DEADLINE: Duration = Duration::from_secs(8);
const POLL: Duration = Duration::from_millis(25);

struct Operation {
    mode: i64,
    depth: u32,
}

struct State {
    // Open and locked in `mode` while any operation holds the lock.
    file: Option<File>,
    mode: i64,
    operations: BTreeMap<i64, Operation>,
    next_id: i64,
}

static STATE: Mutex<State> =
    Mutex::new(State { file: None, mode: SHARED, operations: BTreeMap::new(), next_id: 1 });

// Every change to the state completes before its guard is dropped, so a
// panic elsewhere while it was locked cannot have left it half-changed.
fn state() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(PoisonError::into_inner)
}

/// GDScript's handle on the lock; every instance shares the process's state.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct DocketCoordLock;

#[godot_api]
impl DocketCoordLock {
    #[constant]
    const SHARED: i64 = SHARED;
    #[constant]
    const EXCLUSIVE: i64 = EXCLUSIVE;

    /// Starts a logical operation holding the lock in `mode`, or, with
    /// `within` set to a live operation's id, a nested step of that one.
    /// Returns {op} or {error, kind}: kind "busy" when another holder kept it
    /// past the eight-second deadline, "io" when the lock file could not be
    /// used, "refused" for a request that can never succeed.
    #[func]
    fn begin(&self, mode: i64, within: i64) -> VarDictionary {
        let mut result = VarDictionary::new();
        match begin(mode, within) {
            Ok(op) => result.set("op", op),
            Err(Failure { kind, message }) => {
                result.set("error", message.as_str());
                result.set("kind", kind);
            }
        }
        result
    }

    /// Ends one `begin` of operation `op`; "" or why not.
    #[func]
    fn end(&self, op: i64) -> GString {
        GString::from(end(op).err().unwrap_or_default().as_str())
    }

    /// The lock file's path, for diagnostics, or "" when it cannot be found.
    #[func]
    fn lock_path(&self) -> GString {
        let path = coordination_dir().map(|dir| dir.join(LOCK_FILE).display().to_string());
        GString::from(path.unwrap_or_default().as_str())
    }
}

pub(crate) struct Failure {
    pub(crate) kind: &'static str,
    pub(crate) message: String,
}

pub(crate) fn failure(kind: &'static str, message: impl Into<String>) -> Failure {
    Failure { kind, message: message.into() }
}

pub(crate) fn begin(mode: i64, within: i64) -> Result<i64, Failure> {
    if mode != SHARED && mode != EXCLUSIVE {
        return Err(failure("refused", format!("unknown lock mode {mode}")));
    }
    if within != 0 {
        let mut state = state();
        let operation = state
            .operations
            .get_mut(&within)
            .ok_or_else(|| failure("refused", format!("operation {within} is not running")))?;
        if mode == EXCLUSIVE && operation.mode == SHARED {
            return Err(failure("refused", "vault administration cannot start inside ordinary work"));
        }
        operation.depth += 1;
        return Ok(within);
    }
    let path = coordination_dir().map_err(|e| failure("io", e))?.join(LOCK_FILE);
    let deadline = Instant::now() + DEADLINE;
    loop {
        {
            let mut state = state();
            if state.file.is_none() {
                let file = OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .open(&path)
                    .map_err(|e| failure("io", format!("cannot open {}: {e}", path.display())))?;
                let attempt = if mode == EXCLUSIVE { file.try_lock() } else { file.try_lock_shared() };
                match attempt {
                    Ok(()) => {
                        state.file = Some(file);
                        state.mode = mode;
                    }
                    Err(TryLockError::WouldBlock) => {}
                    Err(TryLockError::Error(e)) => {
                        return Err(failure("io", format!("cannot lock {}: {e}", path.display())))
                    }
                }
            }
            // A SHARED hold is shared by SHARED operations; anything else
            // waits for the process's current operations to end.
            let joinable = state.file.is_some()
                && state.mode == mode
                && (mode == SHARED || state.operations.is_empty());
            if joinable {
                let id = state.next_id;
                state.next_id += 1;
                state.operations.insert(id, Operation { mode, depth: 1 });
                return Ok(id);
            }
        }
        if Instant::now() >= deadline {
            return Err(failure("busy", "another Docket operation is busy; try again shortly"));
        }
        sleep(POLL);
    }
}

pub(crate) fn end(op: i64) -> Result<(), String> {
    let mut state = state();
    let operation = state.operations.get_mut(&op).ok_or_else(|| format!("operation {op} is not running"))?;
    operation.depth -= 1;
    if operation.depth == 0 {
        state.operations.remove(&op);
        if state.operations.is_empty() {
            // Closing the file releases its lock.
            state.file = None;
        }
    }
    Ok(())
}
