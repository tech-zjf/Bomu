import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/summarize-animation-hitches.py"
spec = importlib.util.spec_from_file_location("animation_hitches", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AnimationHitchesSummaryTests(unittest.TestCase):
    def test_resolves_references_deduplicates_display_updates_and_filters_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hangs = root / "hangs.xml"
            updates = root / "updates.xml"
            hangs.write_text("""<trace-query-result><node>
              <schema name="potential-hangs">
                <col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col>
                <col><mnemonic>hang-type</mnemonic></col><col><mnemonic>thread</mnemonic></col>
                <col><mnemonic>process</mnemonic></col>
              </schema>
              <row><start-time id="1">100</start-time><duration id="2">122380000</duration>
                <hang-type id="3" fmt="Brief Unresponsiveness"/><thread id="4" fmt="Main Thread (Bomu, pid: 42)"/>
                <process/></row>
              <row><start-time id="5">200</start-time><duration id="6">35940000</duration>
                <hang-type id="7" fmt="Potential Interaction Delay"/><thread ref="4"/><process/></row>
              <row><start-time id="8">300</start-time><duration id="9">50000000</duration>
                <hang-type ref="7"/><thread id="10" fmt="Main Thread (Other, pid: 9)"/><process/></row>
            </node></trace-query-result>""")
            updates.write_text("""<trace-query-result><node>
              <schema name="hitches-updates">
                <col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col>
                <col><mnemonic>process</mnemonic></col><col><mnemonic>display</mnemonic></col>
              </schema>
              <row><start-time id="1">100</start-time><duration id="2">141630000</duration>
                <process id="3" fmt="Bomu (42)"/><display-name id="4" fmt="Display 3"/></row>
              <row><start-time ref="1"/><duration ref="2"/><process ref="3"/><display-name ref="4"/></row>
              <row><start-time id="5">200</start-time><duration id="6">33000000</duration>
                <process ref="3"/><display-name ref="4"/></row>
              <row><start-time id="7">300</start-time><duration id="8">90000000</duration>
                <process id="9" fmt="Other (9)"/><display-name ref="4"/></row>
            </node></trace-query-result>""")

            result = module.summarize(hangs, updates)
            self.assertEqual(result["main_thread_delays"]["count"], 2)
            self.assertEqual(result["main_thread_delays"]["max_ms"], 122.38)
            self.assertEqual(result["main_thread_delays"]["types"], {
                "Brief Unresponsiveness": 1,
                "Potential Interaction Delay": 1,
            })
            self.assertEqual(result["display_updates"], {
                "raw_rows": 3,
                "unique_events": 2,
                "above_threshold": 1,
                "max_above_threshold_ms": 141.63,
            })

    def test_rejects_unknown_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "invalid.xml"
            path.write_text("""<trace-query-result><node><schema name="hitches-updates">
              <col><mnemonic>start</mnemonic></col></schema>
              <row><start-time ref="missing"/></row></node></trace-query-result>""")
            with self.assertRaisesRegex(ValueError, "Unknown XML value reference"):
                module.table_rows(path, "hitches-updates")

    def test_failed_export_still_removes_private_trace(self):
        benchmark_root = SCRIPT.parent.parent / ".build/benchmarks"
        benchmark_root.mkdir(parents=True, exist_ok=True)
        trace = Path(tempfile.mkdtemp(prefix="failed-export-", suffix=".trace",
                                      dir=benchmark_root))
        (trace / "recording.data").write_text("private process environment")
        try:
            with mock.patch("sys.argv", [str(SCRIPT), str(trace), "--remove-trace"]), \
                 mock.patch.object(module, "export_table", side_effect=RuntimeError("export failed")):
                with self.assertRaisesRegex(RuntimeError, "export failed"):
                    module.main()
            self.assertFalse(trace.exists())
        finally:
            if trace.exists():
                import shutil
                shutil.rmtree(trace)


if __name__ == "__main__":
    unittest.main()
