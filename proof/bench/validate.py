#!/usr/bin/env python3
"""Validate benchmark records against proof/bench/schema.json.

Checks records/**/*.json and examples/*.json, plus two derived-value rules
the JSON schema cannot express:
  - fee_at_floor_wei == state_units * state_floor_wei_per_unit
  - sustained_per_day == refill_units_per_block * 86,400 // state_units
Exit status 1 on any error. Requires: pip install jsonschema
"""

import json
import sys
from pathlib import Path

import jsonschema

HERE = Path(__file__).resolve().parent
BLOCKS_PER_DAY = 86_400  # ~1 s blocks


def derived_errors(rec: dict) -> list[str]:
    env = rec["environment"]
    floor = int(env.get("state_floor_wei_per_unit", "0"))
    refill = env.get("limits", {}).get("state_refill_units_per_block")
    errs = []
    for i, a in enumerate(rec["actions"]):
        units = a.get("state_units")
        if units is None:
            continue
        if "fee_at_floor_wei" in a and floor and int(a["fee_at_floor_wei"]) != units * floor:
            errs.append(f"actions[{i}]: fee_at_floor_wei != state_units x floor")
        if a.get("sustained_per_day") is not None and refill and units:
            if a["sustained_per_day"] != refill * BLOCKS_PER_DAY // units:
                errs.append(f"actions[{i}]: sustained_per_day != refill x 86,400 // state_units")
    return errs


def main() -> int:
    validator = jsonschema.Draft202012Validator(json.loads((HERE / "schema.json").read_text()))
    files = sorted(HERE.glob("records/**/*.json")) + sorted(HERE.glob("examples/*.json"))
    failed = 0
    for path in files:
        rec = json.loads(path.read_text())
        errs = [f"{'/'.join(map(str, e.path))}: {e.message}" for e in validator.iter_errors(rec)]
        if not errs:
            errs = derived_errors(rec)
        status = "ok" if not errs else "FAIL"
        print(f"{status:4}  {path.relative_to(HERE)}")
        for e in errs:
            print(f"      {e}")
        failed += bool(errs)
    print(f"{len(files) - failed}/{len(files)} records valid")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
