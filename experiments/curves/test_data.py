"""Data-pipeline boundary tests; all market fixtures come from the download script."""
import importlib.util
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("fetch_curves", ROOT / "scripts/fetch-curve-data.py")
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)


class CausalDataTest(unittest.TestCase):
    def test_latest_observation_at_cutoff_and_no_future_price(self):
        prices = fetch.CausalPrices()
        prices.observe(0, 100)
        prices.observe(1_000_000, 101)
        prices.observe(25_000_000, 125)
        prices.observe(29_000_000, 129)
        prices.observe(30_000_000, 130)
        self.assertEqual(prices.anchors(), [29_000_000, 129, 25_000_000, 125, 0, 100])
        prices.observe(30_100_000, 999)
        self.assertEqual(prices.anchors(), [29_000_000, 129, 25_000_000, 125, 0, 100])

    def test_decimal_conversion_has_no_binary_float_rounding(self):
        self.assertEqual(fetch.wad("2411.66"), 2411660000000000000000)
        self.assertEqual(fetch.wad("0.000000000000000001"), 1)
        with self.assertRaises(ValueError):
            fetch.wad("0.0000000000000000001")

    def test_sampling_keeps_actual_direction_size_and_lagged_history(self):
        start = 1_800_000_000_000_000
        def row(i, seconds, price="2500.01", side="true"):
            return [str(i), price, "0.1234", str(i), str(i), str(start + seconds * 1_000_000), side, "true"]
        rows = [row(1, 0), row(2, 30), row(3, 31, "9999"), row(4, 60, "2501", "false")]
        raw, stats = fetch.build_fixture(rows, fetch.CausalPrices(), 60_000_000)
        words = [int.from_bytes(raw[i:i+32], "big") for i in range(0, len(raw), 32)]
        self.assertEqual(stats["sampled_trades"], 2)
        self.assertEqual(words[1:5], [2, 1, fetch.wad("0.1234"), fetch.wad("2500.01")])
        self.assertEqual(words[11 + 2], 0)
        # The unsampled tick at second 31 is still the 1-second-lag anchor at second 60.
        self.assertEqual(words[11 + 5:11 + 7], [start + 31_000_000, fetch.wad("9999")])

    def test_rejects_duplicate_or_reordered_trade_ids(self):
        row = ["1", "2500", "1", "1", "1", "1800000000000000", "false", "true"]
        with self.assertRaises(ValueError):
            fetch.build_fixture([row, row], fetch.CausalPrices(), 60_000_000)

    def test_rejects_millisecond_timestamp(self):
        row = ["1", "2500", "1", "1", "1", "1800000000000", "false", "true"]
        with self.assertRaises(ValueError):
            fetch.build_fixture([row], fetch.CausalPrices(), 60_000_000)

    def test_pinned_fixtures_match_dates_hashes_counts_and_causal_anchors(self):
        folder = ROOT / "experiments/curves/data"
        manifest = json.loads((folder / "manifest.json").read_text())
        previous = 0
        for day in manifest["days"]:
            raw = (folder / day["fixture"]).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), day["fixture_sha256"])
            self.assertEqual(len(raw), day["sampled_trades"] * 11 * 32)
            for offset in range(0, len(raw), 11 * 32):
                words = [int.from_bytes(raw[i:i+32], "big") for i in range(offset, offset+11*32, 32)]
                stamp = words[0]
                self.assertGreater(stamp, previous)
                self.assertEqual(datetime.fromtimestamp(stamp // 1_000_000, timezone.utc).date().isoformat(), day["date"])
                self.assertIn(words[2], (0, 1))
                self.assertGreater(words[3], 0)
                self.assertGreater(words[4], 0)
                for j, lag in enumerate((1, 5, 30)):
                    self.assertLessEqual(words[5+2*j], stamp-lag*1_000_000)
                    self.assertGreater(words[6+2*j], 0)
                previous = stamp


if __name__ == "__main__":
    unittest.main()
