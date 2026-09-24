"""A Docket release export as package_plugin.py takes it into a plugin: the
whole export root of one target (Godot's --export-release output), checked
before it is staged and compared after it is copied.

The names checked come from the project, not from a list kept here: the
executable (or macOS bundle) from the target's preset in export_presets.cfg,
and the libraries every export must carry from each GDExtension's release
entry for the target. Everything else the export holds is copied as it is,
layout, modes and internal symlinks included, since a macOS bundle is signed
as exported and must not be rearranged.
"""
import hashlib
import os
import plistlib
import posixpath
import re
import shutil
import stat
import struct
import subprocess
import sys

# target → the export preset's name, the GDExtension release key, and the
# binary format its executable and libraries must have.
TARGETS = {
    "linux": ("Linux", "linux.release.x86_64", "elf-x86_64"),
    "windows": ("Windows", "windows.release.x86_64", "pe-x86_64"),
    "macos": ("macOS", "macos.release", "mach-o"),
}
EXTENSIONS = ["addons/docket_native/docket_native.gdextension", "addons/godot-sqlite/gdsqlite.gdextension"]


class ExportError(Exception):
    pass


class Export:
    """A checked export: `source` is copied to package directory `dest`, and
    the host starts package path `entrypoint`."""

    def __init__(self, source, dest, entrypoint, bundle):
        self.source, self.dest, self.entrypoint, self.bundle = source, dest, entrypoint, bundle


def inspect(root, target, export_root):
    """The export of `target` at `export_root`, or ExportError saying what
    it lacks."""
    if target not in TARGETS:
        raise ExportError("unknown target %s (one of %s)" % (target, ", ".join(sorted(TARGETS))))
    preset, key, binary = TARGETS[target]
    name, embedded_pck = _preset_export(root, preset)
    libraries = [_release_library(root, extension, key) for extension in EXTENSIONS]
    export_root = os.path.abspath(export_root)
    if target == "macos":
        # The bundle itself, not the directory holding it, so nothing else
        # beside it (an older archive) comes along.
        if os.path.basename(export_root) != name or not os.path.isdir(export_root):
            raise ExportError("the macOS export is the bundle %s itself, not %s" % (name, export_root))
        contents = os.path.join(export_root, "Contents")
        executable = _plist_value(os.path.join(contents, "Info.plist"), "CFBundleExecutable")
        executable_path = os.path.join(contents, "MacOS", executable)
        library_dir = os.path.join(contents, "Frameworks")
        resources = os.path.join(contents, "Resources")
        packs = [os.path.join(resources, entry) for entry in
                 (os.listdir(resources) if os.path.isdir(resources) else []) if entry.endswith(".pck")]
        if not packs:
            raise ExportError("the bundle has no exported .pck in Contents/Resources")
        for pack in packs:
            _check_pack(pack)
        dest = "bin/" + name
        entrypoint = "%s/Contents/MacOS/%s" % (dest, executable)
    else:
        if not os.path.isdir(export_root):
            raise ExportError("%s is not an export directory" % export_root)
        executable_path = os.path.join(export_root, name)
        library_dir = export_root
        dest = "bin/export"
        entrypoint = "%s/%s" % (dest, name)
    _check_binary(executable_path, binary, executable=target != "windows")
    if target != "macos":
        if embedded_pck:
            _check_embedded_pack(executable_path)
        else:
            _check_pack(os.path.splitext(executable_path)[0] + ".pck")
    for library in libraries:
        path = os.path.join(library_dir, library)
        if library.endswith(".framework"):
            path = _framework_executable(path)
        _check_binary(path, binary, executable=False)
    _check_links(export_root)
    return Export(export_root, dest, entrypoint, target == "macos")


def copy(export, out):
    """Copy the export under `out` and confirm the copy: every file's bytes
    and mode, every directory's mode and every symlink's target as in the
    export. A macOS bundle is copied with ditto, which keeps the extended
    attributes its signature seals, and its signature is verified before and
    after; it is never re-signed or altered."""
    target = os.path.join(out, export.dest)
    if export.bundle:
        if sys.platform != "darwin":
            raise ExportError("a macOS package is staged on macOS, where ditto and codesign keep and check its signature")
        _verify_signature(export.source)
        _run(["ditto", export.source, target])
        _verify_signature(target)
    else:
        # Symlinks stay links; files and directories keep their modes.
        shutil.copytree(export.source, target, symlinks=True)
    if _listing(export.source) != _listing(target):
        raise ExportError("the staged export differs from %s" % export.source)


def _verify_signature(bundle):
    _run(["codesign", "--verify", "--deep", "--strict", bundle])


def _run(command):
    try:
        done = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        raise ExportError("%s could not run: %s" % (command[0], error))
    if done.returncode != 0:
        raise ExportError("%s failed: %s" % (" ".join(command), (done.stderr or done.stdout).strip()))


# Preset `preset`'s export name (the basename of its export_path) and whether
# it embeds the PCK in the executable. A preset's section runs up to the next
# one, its [preset.N.options] included.
def _preset_export(root, preset):
    text = open(os.path.join(root, "export_presets.cfg"), encoding="utf-8").read()
    for section in re.split(r"^\[preset\.\d+\]$", text, flags=re.M)[1:]:
        if re.search(r'^name="%s"$' % re.escape(preset), section, re.M):
            path = re.search(r'^export_path="([^"]+)"$', section, re.M)
            if path:
                embedded = re.search(r"^binary_format/embed_pck=true$", section, re.M) is not None
                return posixpath.basename(path.group(1)), embedded
    raise ExportError("export_presets.cfg has no export path for preset %s" % preset)


PACK_MAGIC = b"GDPC"


# A PCK file of its own: non-empty, starting with the pack magic.
def _check_pack(path):
    if not os.path.isfile(path):
        raise ExportError("the export has no %s" % path)
    with open(path, "rb") as handle:
        if handle.read(4) != PACK_MAGIC:
            raise ExportError("%s is not a Godot pack" % path)


# A PCK embedded in `path`: Godot appends the pack, then its size (u64) and
# the pack magic, so the pack starts size + 12 bytes before the end, with
# the magic again. (A Windows signature, were the preset to sign, would come
# after the trailer, and this check would need to skip it.)
def _check_embedded_pack(path):
    length = os.path.getsize(path)
    with open(path, "rb") as handle:
        if length < 16:
            raise ExportError("%s has no embedded pack" % path)
        handle.seek(length - 12)
        size = struct.unpack("<Q", handle.read(8))[0]
        magic = handle.read(4)
        start = length - 12 - size
        if magic != PACK_MAGIC or size < 4 or start <= 0:
            raise ExportError("%s has no embedded pack" % path)
        handle.seek(start)
        if handle.read(4) != PACK_MAGIC:
            raise ExportError("%s's embedded pack does not start where its size says" % path)


# The basename of `extension`'s library for release key `key`.
def _release_library(root, extension, key):
    text = open(os.path.join(root, extension), encoding="utf-8").read()
    found = re.search(r'^%s\s*=\s*"([^"]+)"' % re.escape(key), text, re.M)
    if not found:
        raise ExportError("%s names no %s library" % (extension, key))
    return posixpath.basename(found.group(1))


def _plist_value(path, key):
    try:
        with open(path, "rb") as handle:
            value = plistlib.load(handle).get(key, "")
    except (OSError, plistlib.InvalidFileException) as error:
        raise ExportError("%s could not be read: %s" % (path, error))
    if not isinstance(value, str) or not value or "/" in value:
        raise ExportError("%s has no usable %s" % (path, key))
    return value


# The executable of framework bundle `path`, as its Info.plist names it.
def _framework_executable(path):
    for resources in ("Resources", "Versions/Current/Resources"):
        plist = os.path.join(path, resources, "Info.plist")
        if os.path.isfile(plist):
            executable = _plist_value(plist, "CFBundleExecutable")
            for candidate in (os.path.join(path, executable), os.path.join(path, "Versions", "Current", executable)):
                if os.path.isfile(candidate):
                    return candidate
            raise ExportError("%s names %s, which it does not contain" % (plist, executable))
    raise ExportError("%s is missing or has no Info.plist" % path)


def _check_binary(path, binary, executable):
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        raise ExportError("the export has no %s" % path)
    if executable and not os.stat(path).st_mode & stat.S_IXUSR:
        raise ExportError("%s is not executable" % path)
    with open(path, "rb") as handle:
        head = handle.read(4096)
        if binary == "mach-o":
            if not _macho_architectures(handle, os.path.getsize(path)) >= MACOS_ARCHITECTURES:
                raise ExportError("%s is not a universal (x86_64 and arm64) Mach-O binary" % path)
            return
    try:
        if binary == "elf-x86_64":
            ok = head[:5] == b"\x7fELF\x02" and struct.unpack_from("<H", head, 18)[0] == 0x3E
        elif binary == "pe-x86_64":
            offset = struct.unpack_from("<I", head, 0x3C)[0]
            ok = (head[:2] == b"MZ" and head[offset:offset + 4] == b"PE\0\0"
                  and struct.unpack_from("<H", head, offset + 4)[0] == 0x8664)
        else:
            ok = False
    except struct.error:  # too short for its header
        ok = False
    if not ok:
        raise ExportError("%s is not a %s binary" % (path, binary))


# CPU types (mach/machine.h) a macOS export is built for: universal.
MACOS_ARCHITECTURES = {0x01000007, 0x0100000C}  # x86_64, arm64


MACHO_64 = b"\xcf\xfa\xed\xfe"


# The CPU types of the Mach-O file open as `handle` (`length` bytes): a
# universal (fat) one's slices, each a 64-bit Mach-O within the file, or a
# 64-bit one's own. Anything else has none.
def _macho_architectures(handle, length):
    handle.seek(0)
    head = handle.read(8)
    if head[:4] == MACHO_64 and len(head) == 8:
        return {struct.unpack_from("<I", head, 4)[0]}
    if head[:4] != b"\xca\xfe\xba\xbe" or len(head) < 8:
        return set()
    count = struct.unpack_from(">I", head, 4)[0]
    if not 0 < count <= 16:  # a real universal binary has a few slices
        return set()
    table = handle.read(20 * count)
    if len(table) != 20 * count:
        return set()
    found = set()
    for index in range(count):
        cputype, _subtype, offset, size, _align = struct.unpack_from(">5I", table, 20 * index)
        if offset < 8 + 20 * count or size < 8 or offset + size > length:
            return set()
        handle.seek(offset)
        slice_head = handle.read(8)
        if slice_head[:4] != MACHO_64 or struct.unpack_from("<I", slice_head, 4)[0] != cputype:
            return set()
        found.add(cputype)
    return found


# Every symlink in the export must point, relatively, at something inside it,
# as the filesystem resolves it (through any other links on the way).
def _check_links(export_root):
    real_root = os.path.realpath(export_root)
    for base, dirs, files in os.walk(export_root):
        for name in dirs + files:
            path = os.path.join(base, name)
            if not os.path.islink(path):
                continue
            link = os.readlink(path)
            resolved = os.path.realpath(path)
            if os.path.isabs(link) or os.path.commonpath([real_root, resolved]) != real_root \
                    or not os.path.exists(resolved):
                raise ExportError("%s links to %s, outside the export or nowhere" % (path, link))


def file_digest(path):
    """The SHA-256 of file `path`, read in chunks (exports hold large files)."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# path → what it is: ("link", target), ("dir", mode) or ("file", mode, sha256).
def _listing(root):
    entries = {}
    for base, dirs, files in os.walk(root):
        for name in dirs + files:
            path = os.path.join(base, name)
            relative = os.path.relpath(path, root)
            mode = stat.S_IMODE(os.lstat(path).st_mode)
            if os.path.islink(path):
                entries[relative] = ("link", os.readlink(path))
            elif os.path.isdir(path):
                entries[relative] = ("dir", mode)
            else:
                entries[relative] = ("file", mode, file_digest(path))
    return entries
