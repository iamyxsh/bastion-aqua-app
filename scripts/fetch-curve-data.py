#!/usr/bin/env python3
"""Pin Binance aggregate trades and build causal, integer-only Foundry fixtures.

No third-party dependencies. Downloads are separate from the offline test runner.
Each event has 11 big-endian uint256 words:
  time_us, agg_id, base_in, quantity_wad, market_price_wad,
  anchor_1s_time_us, anchor_1s_price_wad,
  anchor_5s_time_us, anchor_5s_price_wad,
  anchor_30s_time_us, anchor_30s_price_wad.
"""
import argparse
from collections import deque
import csv
from datetime import date, timedelta
from decimal import Decimal
import hashlib
import io
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT = ROOT / "experiments/curves"
WAD = 10**18
LAGS = (1, 5, 30)


def wad(value):
    scaled = Decimal(value) * WAD
    if scaled != scaled.to_integral_value() or scaled <= 0:
        raise ValueError(f"invalid positive fixed-point value: {value}")
    return int(scaled)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


class CausalPrices:
    """Retain the latest observation at/before each lagged execution cutoff."""
    def __init__(self):
        self.pending = {lag: deque() for lag in LAGS}
        self.latest = {}

    def observe(self, time_us, price):
        for lag, pending in self.pending.items():
            pending.append((time_us, price))
            cutoff = time_us - lag * 1_000_000
            while pending and pending[0][0] <= cutoff:
                self.latest[lag] = pending.popleft()

    def anchors(self):
        if len(self.latest) != len(LAGS):
            return None
        return [word for lag in LAGS for word in self.latest[lag]]


def build_fixture(rows, prices, interval_us):
    events = bytearray()
    stats = {"raw_trades": 0, "sampled_trades": 0, "buy_base_requests": 0,
             "sell_base_requests": 0, "first_time_us": None, "last_time_us": None,
             "max_anchor_age_us": {str(lag): 0 for lag in LAGS}}
    last_time, last_id, last_bucket = -1, -1, None
    for row in rows:
        if len(row) != 8:
            raise ValueError(f"expected 8 aggregate-trade columns, got {len(row)}")
        trade_id, price, quantity, _, _, stamp, buyer_maker, _ = row
        trade_id, stamp = int(trade_id), int(stamp)
        # Binance spot archives changed from milliseconds to microseconds in 2025.
        if stamp < 10**15:
            raise ValueError("expected microsecond timestamps (2025+ spot data)")
        if stamp < last_time or trade_id <= last_id:
            raise ValueError("archive is not chronological / trade IDs are not unique")
        last_time, last_id = stamp, trade_id
        price, quantity = wad(price), wad(quantity)
        if buyer_maker.lower() not in ("true", "false"):
            raise ValueError("invalid buyer-maker flag")
        base_in = int(buyer_maker.lower() == "true")
        stats["raw_trades"] += 1
        prices.observe(stamp, price)
        anchors = prices.anchors()
        bucket = stamp // interval_us
        if bucket == last_bucket or anchors is None:
            continue
        last_bucket = bucket
        words = [stamp, trade_id, base_in, quantity, price, *anchors]
        for word in words:
            events.extend(word.to_bytes(32, "big"))
        stats["sampled_trades"] += 1
        stats["sell_base_requests" if base_in else "buy_base_requests"] += 1
        stats["first_time_us"] = stats["first_time_us"] or stamp
        stats["last_time_us"] = stamp
        for j, lag in enumerate(LAGS):
            age = stamp - anchors[2 * j]
            if age < lag * 1_000_000:
                raise AssertionError("future price used")
            stats["max_anchor_age_us"][str(lag)] = max(stats["max_anchor_age_us"][str(lag)], age)
    if not stats["sampled_trades"]:
        raise ValueError("empty fixture")
    return events, stats


def download(url, path):
    subprocess.run(["curl", "-L", "--fail", "--silent", "--show-error",
                    "--retry", "2", "--max-time", "180", url, "-o", str(path)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="require already cached raw archives")
    args = parser.parse_args()
    config_path = EXPERIMENT / "replay.json"
    config = json.loads(config_path.read_text())
    folder = EXPERIMENT / "data"
    raw = folder / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    prices = CausalPrices()
    manifest = {"schema": "11 uint256 words/event, big endian; prices and quantities 1e18",
                "config_sha256": digest(config_path), "source": "https://github.com/binance/binance-public-data",
                "days": []}
    for index in range(config["days"]):
        day = date.fromisoformat(config["start_date"]) + timedelta(days=index)
        name = f'{config["symbol"]}-aggTrades-{day.isoformat()}'
        url = f'https://data.binance.vision/data/spot/daily/aggTrades/{config["symbol"]}/{name}.zip'
        archive = raw / f"{name}.zip"
        checksum = raw / f"{name}.zip.CHECKSUM"
        if not checksum.exists():
            if args.offline:
                raise FileNotFoundError(checksum)
            download(url + ".CHECKSUM", checksum)
        expected = checksum.read_text().split()[0]
        if len(expected) != 64:
            raise ValueError("invalid checksum document")
        if not archive.exists():
            if args.offline:
                raise FileNotFoundError(archive)
            download(url, archive)
        actual = digest(archive)
        if actual != expected:
            raise ValueError(f"checksum mismatch for {archive}: {actual} != {expected}")
        with zipfile.ZipFile(archive) as zipped:
            with zipped.open(name + ".csv") as source:
                fixture, stats = build_fixture(csv.reader(io.TextIOWrapper(source)), prices,
                                               config["sample_seconds"] * 1_000_000)
        fixture_path = folder / f"{day.isoformat()}.bin"
        fixture_path.write_bytes(fixture)
        entry = {"date": day.isoformat(), "phase": "training" if index < config["training_days"] else "evaluation",
                 "url": url, "archive_sha256": actual, "fixture": fixture_path.name,
                 "fixture_sha256": digest(fixture_path), **stats}
        manifest["days"].append(entry)
        print(f'{day}: verified {stats["raw_trades"]:,} real trades -> {stats["sampled_trades"]:,} requests', flush=True)
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
