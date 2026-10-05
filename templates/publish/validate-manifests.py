#!/usr/bin/env python3
"""Validate every examples/*/manifest.json against templates/publish/schema/eastsea-app-1.json.

Exit code 0 = all manifests valid. Intended for local pre-flight and CI:

    python3 templates/publish/validate-manifests.py [--root /path/to/repo]

Requires: pip install jsonschema  (or brew install yq -- not needed, jsonschema only)
"""

import json
import pathlib
import sys

try:
    import jsonschema
except ImportError:
    print("error: jsonschema not installed - pip install jsonschema", file=sys.stderr)
    sys.exit(2)


def main() -> int:
    root = pathlib.Path(sys.argv[sys.argv.index("--root") + 1]) if "--root" in sys.argv else pathlib.Path(__file__).resolve().parent.parent.parent
    schema_path = root / "templates" / "publish" / "schema" / "eastsea-app-1.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    manifests = sorted((root / "examples").glob("*/manifest.json"))
    if not manifests:
        print("error: no manifests found under examples/", file=sys.stderr)
        return 2

    failed = 0
    for path in manifests:
        try:
            instance = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"FAIL {path.relative_to(root)}: invalid JSON: {e}")
            failed += 1
            continue
        validator = jsonschema.Draft202012Validator(schema)
        errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
        if errors:
            failed += 1
            for err in errors:
                loc = ".".join(str(p) for p in err.absolute_path) or "<root>"
                print(f"FAIL {path.relative_to(root)}: {loc}: {err.message}")
        else:
            # toolbox convention: every manifest carries the placeholder warning until published
            note = instance.get("x-toolbox-note", "")
            placeholders = [k for k in ("app_id",) if str(instance.get(k, "")).strip("0x") == ""]
            placeholders += ["bundle.sha256"] if str(instance.get("bundle", {}).get("sha256", "")).strip("0x") == "" else []
            state = "TEMPLATE (placeholders unfilled)" if placeholders else "publishable"
            print(f"OK   {path.relative_to(root)} - {instance.get('name', '?')} [{state}]")

    total = len(manifests)
    print(f"\n{total - failed}/{total} manifests valid")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
