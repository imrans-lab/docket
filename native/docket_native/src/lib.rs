//! Docket's native extension: what GDScript cannot do safely on its own.

use godot::prelude::*;

mod coord_dir;
mod coord_lock;

struct DocketNative;

#[gdextension]
unsafe impl ExtensionLibrary for DocketNative {}
