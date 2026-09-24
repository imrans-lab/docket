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
//! Within a process, the lock is held for logical operations. GDScript gets
//! each one as a DocketCoordOperation object: DocketCoordLock.open() starts
//! an operation, `nested()` on it starts a step of the same operation that
//! reuses its hold, and `close()` gives either back (as does freeing the
//! object, as a safety net). The operation's id never leaves Rust. Code that
//! is not handed an operation starts its own: it shares a SHARED hold, but
//! waits for an EXCLUSIVE one like any other process, so no unrelated callback
//! or thread ever acts under another operation's administration. Asking for
//! EXCLUSIVE within a SHARED operation is refused at once rather than
//! upgraded. The file is locked once per process and unlocked when the last
//! operation ends; a hold lasts until it is closed, whatever its caller
//! stopped waiting for.
//!
//! An operation object acts as its operation for whoever holds it, and nothing
//! checks who they are. Its owner passes it only to the steps of that same
//! operation, never to unrelated code. Operation objects are Godot objects,
//! and this build of godot-rust supports them only on Godot's main thread: they
//! are opened, used, closed and freed there, and never handed to a worker
//! thread. (The lock state itself is thread-safe; the objects are not.)
//!
//! Waiting is not fair: a stream of SHARED operations can keep an EXCLUSIVE
//! one waiting until it reports busy. A wait blocks its thread for up to the
//! deadline, so an operation must not hold EXCLUSIVE while it waits on the
//! thread that would wait for it (Godot's main thread, say).

use crate::coord_dir::{self, coordination_dir};
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

    /// Starts an operation holding the lock in `mode`: {operation} (a
    /// DocketCoordOperation) or {error, kind}: kind "busy" when another holder
    /// kept it past the eight-second deadline, "io" when the lock file could
    /// not be used, "refused" for a request that can never succeed.
    #[func]
    fn open(&self, mode: i64) -> VarDictionary {
        opened(begin(mode, 0), mode)
    }

    /// A step of `parent` in `mode` when it is given, else a new operation:
    /// {operation} or {error, kind}. `parent` must be a live
    /// DocketCoordOperation; anything else is refused, never treated as no
    /// parent.
    #[func]
    fn join(&self, parent: Option<Gd<Object>>, mode: i64) -> VarDictionary {
        match parent.map(operation_of) {
            None => opened(begin(mode, 0), mode),
            Some(Ok(id)) => opened(begin(mode, id), mode),
            Some(Err(f)) => failed(f),
        }
    }

    /// Checks that the coordination directory is `expected` (an absolute
    /// path a host resolved); "" when it is. A mismatch fails coordination for
    /// the rest of the process, and says why.
    #[func]
    fn expect_directory(&self, expected: GString) -> GString {
        let expected = expected.to_string();
        GString::from(coord_dir::expect(std::path::Path::new(&expected)).err().unwrap_or_default().as_str())
    }

    /// The lock file's path, for diagnostics, or "" when it cannot be found.
    #[func]
    fn lock_path(&self) -> GString {
        let path = coordination_dir().map(|dir| dir.join(LOCK_FILE).display().to_string());
        GString::from(path.unwrap_or_default().as_str())
    }
}

/// One hold of a logical operation, owned by whoever holds this object.
/// `close()` gives it back; freeing an unclosed one does too.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct DocketCoordOperation {
    id: i64,
    mode: i64,
    open: bool,
}

#[godot_api]
impl DocketCoordOperation {
    /// A step of this same operation, reusing its hold: {operation} or
    /// {error, kind}. EXCLUSIVE within a SHARED operation is refused.
    #[func]
    fn nested(&self, mode: i64) -> VarDictionary {
        if !self.open {
            return failed(failure("refused", "the operation has been closed"));
        }
        opened(begin(mode, self.id), mode)
    }

    /// Gives this hold back; "" or why not. Closing twice does nothing.
    #[func]
    fn close(&mut self) -> GString {
        if !self.open {
            return GString::new();
        }
        self.open = false;
        GString::from(end(self.id).err().unwrap_or_default().as_str())
    }

    #[func]
    fn is_open(&self) -> bool {
        self.open
    }

    /// Whether `other` is a live hold of this same logical operation (itself,
    /// or another step of it). False when either is closed or `other` is not
    /// an operation.
    #[func]
    fn same_operation(&self, other: Option<Gd<Object>>) -> bool {
        match (self.live_id(), other.map(operation_of)) {
            (Ok(id), Some(Ok(other_id))) => id == other_id,
            _ => false,
        }
    }

    /// SHARED or EXCLUSIVE, as requested for this hold; a SHARED step of an
    /// EXCLUSIVE operation reports SHARED.
    #[func]
    fn mode(&self) -> i64 {
        self.mode
    }
}

impl DocketCoordOperation {
    /// The live operation id, for native work done within it.
    pub(crate) fn live_id(&self) -> Result<i64, Failure> {
        if self.open { Ok(self.id) } else { Err(failure("refused", "the operation has been closed")) }
    }
}

impl Drop for DocketCoordOperation {
    fn drop(&mut self) {
        if self.open {
            let _ = end(self.id);
        }
    }
}

// The live operation id behind `object`, which must be a DocketCoordOperation.
fn operation_of(object: Gd<Object>) -> Result<i64, Failure> {
    match object.try_cast::<DocketCoordOperation>() {
        Ok(operation) => operation.bind().live_id(),
        Err(_) => Err(failure("refused", "that is not a coordination operation")),
    }
}

fn opened(result: Result<i64, Failure>, mode: i64) -> VarDictionary {
    match result {
        Ok(id) => {
            let mut dictionary = VarDictionary::new();
            dictionary.set("operation", Gd::from_object(DocketCoordOperation { id, mode, open: true }));
            dictionary
        }
        Err(f) => failed(f),
    }
}

fn failed(f: Failure) -> VarDictionary {
    let mut dictionary = VarDictionary::new();
    dictionary.set("error", f.message.as_str());
    dictionary.set("kind", f.kind);
    dictionary
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
    // Checked before any operation or nested step is admitted, so an id
    // taken before a mismatch cannot be used after it; end() still works.
    if let Some(mismatch) = coord_dir::mismatch() {
        return Err(failure("refused", mismatch));
    }
    if within != 0 {
        let mut state = state();
        let operation = state
            .operations
            .get_mut(&within)
            .ok_or_else(|| failure("refused", "the operation is not running"))?;
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
            // Again on every pass: a mismatch reported while this waited
            // must not be followed by granting it.
            if let Some(mismatch) = coord_dir::mismatch() {
                return Err(failure("refused", mismatch));
            }
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
    let operation = state.operations.get_mut(&op).ok_or_else(|| "the operation is not running".to_string())?;
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
