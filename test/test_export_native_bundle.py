#!/usr/bin/env python3
"""Broad real-export oracle: positive native behavior and missing-helper refusal."""
import argparse
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts/build"))
from verify_native_bundle import (ROOT, BundleError, copy_bundle, find_helper,
                                  helper_name, verify)


def exercise(platform):
    verify(platform)
    # Only the disposable negative copy loses its helper; signed positives stay sealed.
    with tempfile.TemporaryDirectory(prefix="docket-export-negative-") as temporary:
        root = pathlib.Path(temporary).resolve()
        (root / "build").mkdir()
        copy_bundle(platform, ROOT / "build" / platform, root / "build" / platform)
        name = helper_name(platform)
        helper = find_helper(platform, root, name)
        helper.unlink()
        try:
            verify(platform, root)
        except BundleError as error:
            assert str(error) == f"missing mapped release helper: {name}", error
        else:
            raise AssertionError("missing exported helper was accepted")
        print(f"EXPORT_NATIVE NEGATIVE PASS platform={platform} reason=missing-mapped-release-helper")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["linux", "macos", "windows"])
    exercise(parser.parse_args().platform)
