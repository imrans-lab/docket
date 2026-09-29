"""Self-checks for write_bench.py. Standard library unittest:

  python3 -m unittest scripts/bench/test_write_bench.py

Each check compares what the bench reports with an observation the bench did
not make. The end-to-end check starts a headless Docket server on a free port
and runs only when DOCKET_BENCH_GODOT names a Godot 4.7+ binary; it hashes the
scratch canonical itself around every tool call and compares each row.
"""

import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import write_bench  # noqa: E402

REPO = Path(__file__).resolve().parents[2]

# Contents and their sha256 as printed by coreutils sha256sum, not by Python.
ALPHA = b'{"k":"alpha"}\n'
ALPHA_SHA256 = "2eccd9e23ab992f9be45e7813d9347125ee7ba35494b217c352a78efad23a122"
BETA = b'{"k":"beta"}\n{"n":2}\n'
BETA_SHA256 = "4700a0cc3f1fe1b1eefb2cce9d79203cf9fd2c6584d26701b96ab57c752bc628"


class FixtureTest(unittest.TestCase):
    def test_fixture_reports_known_bytes_and_hashes_and_leaves_sources_alone(self):
        with tempfile.TemporaryDirectory() as live, tempfile.TemporaryDirectory() as scratch:
            alpha = Path(live, "alpha.dct")
            beta = Path(live, "beta.dct")
            alpha.write_bytes(ALPHA)
            beta.write_bytes(BETA)
            mtimes = {p: p.stat().st_mtime_ns for p in (alpha, beta)}

            manifest = write_bench.build_fixture([alpha, beta], Path(scratch))

            reported = {Path(f["source"]).name: f for f in manifest["files"]}
            self.assertEqual(reported["alpha.dct"]["bytes"], len(ALPHA))
            self.assertEqual(reported["alpha.dct"]["sha256"], ALPHA_SHA256)
            self.assertEqual(reported["beta.dct"]["bytes"], len(BETA))
            self.assertEqual(reported["beta.dct"]["sha256"], BETA_SHA256)
            for f in manifest["files"]:
                copy = Path(f["copy"])
                self.assertTrue(Path(scratch).resolve() in copy.parents)
                self.assertEqual(copy.name, Path(f["source"]).name)
            self.assertEqual(Path(reported["beta.dct"]["copy"]).read_bytes(), BETA)
            self.assertEqual(alpha.read_bytes(), ALPHA)
            self.assertEqual(beta.read_bytes(), BETA)
            for p, m in mtimes.items():
                self.assertEqual(p.stat().st_mtime_ns, m)


@unittest.skipUnless(os.environ.get("DOCKET_BENCH_GODOT"), "set DOCKET_BENCH_GODOT to a Godot 4.7+ binary")
class EndToEndTest(unittest.TestCase):
    def test_bench_figures_match_files_read_independently(self):
        fixture = REPO / "test" / "fixtures" / "dynamic_types_record_order_v2.jsonl"
        with tempfile.TemporaryDirectory() as live, tempfile.TemporaryDirectory() as scratch:
            source = Path(live, "bench-selfcheck.dct")
            source.write_bytes(fixture.read_bytes())
            source_bytes = source.read_bytes()
            source_mtime = source.stat().st_mtime_ns
            run_dir = Path(scratch, "run")
            target = run_dir / "fixture" / "0" / source.name

            # Wraps the real MCP call: this test hashes the scratch canonical
            # itself just before and just after each tool call, so every row's
            # before/after can be checked against a read the bench did not make.
            observed = []
            real_call = write_bench.Mcp.call

            def observing_call(mcp, tool, arguments):
                if tool == "docket_project_list":
                    return real_call(mcp, tool, arguments)
                pre = hashlib.sha256(target.read_bytes()).hexdigest()
                result = real_call(mcp, tool, arguments)
                observed.append((tool, pre, hashlib.sha256(target.read_bytes()).hexdigest()))
                return result

            write_bench.Mcp.call = observing_call
            try:
                code = write_bench.main([
                    "--source", str(source), "--scratch", str(run_dir),
                    "--godot", os.environ["DOCKET_BENCH_GODOT"], "--rounds", "1",
                    "--kinds", "tags,comment", "--item", "ORD-0001",
                    "--report", "report.json",
                ])
            finally:
                write_bench.Mcp.call = real_call
            # 1 means a watched file changed, which the owner's own Docket can
            # also cause; this test checks its source below by itself.
            self.assertIn(code, (0, 1))
            report = json.loads((run_dir / "report.json").read_text())

            start = report["fixture"]["files"][0]
            self.assertEqual(Path(start["copy"]), target.resolve())
            self.assertEqual(start["bytes"], len(source_bytes))
            self.assertEqual(start["sha256"], hashlib.sha256(source_bytes).hexdigest())

            rows = [(m["tool"], m["before"]["sha256"], m["after"]["sha256"])
                    for m in report["mutations"]]
            self.assertEqual(rows, observed)
            self.assertTrue(any(pre != post for _, pre, post in observed),
                            "no call changed the canonical, so the boundaries prove nothing")

            final_bytes = target.read_bytes()
            final = report["fixture_final"][start["copy"]]
            self.assertEqual(final["bytes"], len(final_bytes))
            self.assertEqual(final["sha256"], hashlib.sha256(final_bytes).hexdigest())
            self.assertNotEqual(final["sha256"], start["sha256"], "mutations left no trace")
            self.assertTrue(all(m["error"] is None for m in report["mutations"]),
                            report["mutations"])

            self.assertEqual(source.read_bytes(), source_bytes)
            self.assertEqual(source.stat().st_mtime_ns, source_mtime)

if __name__ == "__main__":
    unittest.main()
