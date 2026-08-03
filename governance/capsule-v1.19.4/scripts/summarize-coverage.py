#!/usr/bin/env python3
import json
import pathlib
import sys


CONSOLE_FILES = (
    "src/devices/src/virtio/console/device.rs",
    "src/devices/src/virtio/console/port.rs",
    "src/devices/src/virtio/console/port_io.rs",
    "src/devices/src/virtio/console/process_tx.rs",
)
METRICS = ("functions", "lines", "regions")


def compact_metric(metric):
    count = int(metric["count"])
    covered = int(metric["covered"])
    return {
        "count": count,
        "covered": covered,
        "notCovered": count - covered,
        "percent": round((covered * 100 / count) if count else 0.0, 6),
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: summarize-coverage.py RAW_JSON OUTPUT_JSON")
    raw = json.loads(pathlib.Path(sys.argv[1]).read_text())
    source_files = raw["data"][0]["files"]
    selected = []
    for expected in CONSOLE_FILES:
        matches = [item for item in source_files if item["filename"].endswith(expected)]
        if len(matches) != 1:
            raise SystemExit(f"expected one coverage record for {expected}, got {len(matches)}")
        selected.append({
            "file": expected,
            **{name: compact_metric(matches[0]["summary"][name]) for name in METRICS},
        })

    aggregate = {}
    for name in METRICS:
        count = sum(item[name]["count"] for item in selected)
        covered = sum(item[name]["covered"] for item in selected)
        aggregate[name] = compact_metric({"count": count, "covered": covered})

    result = {
        "status": "local library coverage only; not real transport, guest, VMM, or admission evidence",
        "scope": "four files changed by the retained console correctness patch",
        "aggregate": aggregate,
        "files": selected,
        "wholeKrunDevicesCrate": {
            name: compact_metric(raw["data"][0]["totals"][name]) for name in METRICS
        },
    }
    pathlib.Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
