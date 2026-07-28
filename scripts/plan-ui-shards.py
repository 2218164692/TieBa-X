#!/usr/bin/env python3
"""Work out how to split the UI tests across CI jobs.

Emits GitHub Actions outputs on stdout, so the workflow never lists a test
name: adding a UI test is just adding a test. Full coverage is structural
here — every `func test*` in the source lands in exactly one job — rather
than something a drift gate has to police after the fact.

Each test classifies itself in its own source:

  * an iPad guard (`userInterfaceIdiom == .pad`) means the iPad job,
  * a Reduce Motion guard (`isReduceMotionEnabled`) means that job,
  * a `testHomeTabReselect` name means the reselect job. Those two hold the
    refresh indicator open for seconds on purpose, and they were the ones
    failing repeatedly when everything shared a runner, so they keep their
    own. The extended-refresh launch arguments are not a usable marker: six
    other tests pass them too.

Everything else is spread over `SHARD_COUNT` iPhone shards balanced by
measured duration. Balance matters less than shard count does: each job
carries ~9.7 minutes of fixed cost, and the macOS concurrency cap puts real
parallelism near 3.6, so wall-clock time tracks total runner minutes and more
shards make a round slower. Four is the most that stays under the largest
shard already proven to run safely.
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "TiebaPureUITests" / "TiebaPureUITests.swift"
DURATIONS = ROOT / "scripts" / "ui-test-durations.tsv"
SHARD_COUNT = 4
PREFIX = "-only-testing:TiebaPureUITests/TiebaPureUITests/"

TEST_PATTERN = re.compile(r"^    func (test[A-Za-z0-9_]+)\s*\(", re.M)


def test_bodies(text):
    """Map each test name to its source, from its `func` line to the next."""
    matches = list(TEST_PATTERN.finditer(text))
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        yield match.group(1), text[match.start():end]


def load_durations():
    if not DURATIONS.exists():
        return {}
    values = {}
    for line in DURATIONS.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, _, seconds = line.partition("\t")
        try:
            values[name.strip()] = float(seconds)
        except ValueError:
            continue
    return values


def main():
    text = SOURCE.read_text()
    durations = load_durations()

    ipad, reduce_motion, reselect, shardable = [], [], [], []
    for name, body in test_bodies(text):
        if "userInterfaceIdiom == .pad" in body:
            ipad.append(name)
        elif "isReduceMotionEnabled" in body:
            reduce_motion.append(name)
        elif name.startswith("testHomeTabReselect"):
            reselect.append(name)
        else:
            shardable.append(name)

    total = len(ipad) + len(reduce_motion) + len(reselect) + len(shardable)
    if total == 0:
        sys.exit("No UI tests found; refusing to emit an empty plan.")
    if not ipad or not reduce_motion or not reselect:
        sys.exit(
            "Expected at least one iPad, Reduce Motion and reselect test. "
            "If a guard was renamed, update this script rather than letting "
            "those tests silently fall into a generic shard."
        )

    # An unmeasured test is assumed average rather than free, so a new test
    # cannot quietly pile onto one shard.
    known = [durations[n] for n in shardable if n in durations]
    fallback = sum(known) / len(known) if known else 1.0

    buckets = [[] for _ in range(SHARD_COUNT)]
    load = [0.0] * SHARD_COUNT
    for name in sorted(shardable, key=lambda n: -durations.get(n, fallback)):
        index = min(range(SHARD_COUNT), key=lambda i: load[i])
        buckets[index].append(name)
        load[index] += durations.get(name, fallback)

    include = [{"name": "reselect", "tests": " ".join(PREFIX + n for n in sorted(reselect))}]
    for index, bucket in enumerate(buckets):
        include.append({
            "name": f"shard-{chr(ord('a') + index)}",
            "tests": " ".join(PREFIX + n for n in sorted(bucket)),
        })

    print(f"matrix={json.dumps({'include': include}, separators=(',', ':'))}")
    print(f"ipad-tests={' '.join(PREFIX + n for n in sorted(ipad))}")
    print(f"reduce-motion-tests={' '.join(PREFIX + n for n in sorted(reduce_motion))}")

    plan = ", ".join(f"{e['name']} {e['tests'].count(PREFIX)}" for e in include)
    print(
        f"Planned {total} UI tests: {plan}, "
        f"ipad {len(ipad)}, reduce-motion {len(reduce_motion)}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
