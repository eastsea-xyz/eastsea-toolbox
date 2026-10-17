"""The consumer screen of a template front-end (x-eastsea-template.screen).

A screen is a small declarative description of the template's main job,
written against the agent-readable interface of the primary contract:

    {"lede": "...", "reads": [...], "inputs": [...], "action": {...},
     "progress": {"value": "<read id>", "max": "<read id>"}, "more": [...]}

reads    view calls shown as labelled values ("show" picks the format)
inputs   fields the person fills ("unit" native/token converts decimals)
action   the one primary write; "value" attaches native coin
more     optional secondary writes (shown smaller)

Argument and value sources: "$account", "$<input id>", "$read:<read id>"
or a literal string. The page gets the same screen compiled with selectors
and ABI argument types (compile_screen); the full console stays available
under "개발자 보기". The validator checks every call against the interface.
"""

from __future__ import annotations

import re

SHOW = {"native", "token", "count", "bps", "time", "duration", "per-day", "bool", "state", "address", "hash", "text"}
UNITS = {"native", "token", "uint", "address", "bytes32", "text", "list"}
ID = re.compile(r"^[a-z][a-zA-Z0-9]{0,23}$")
TEXT_MAX = 160
SCREEN_KEYS = {"lede", "reads", "inputs", "action", "progress", "more", "note"}
READ_KEYS = {"id", "call", "args", "word", "label", "show", "map", "decimals", "suffix"}
INPUT_KEYS = {"id", "label", "unit", "placeholder", "default", "decimals", "hint"}
ACTION_KEYS = {"call", "args", "value", "label"}

# ---------------------------------------------------------------- keccak-256 (selectors only)
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
       0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
       0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_MASK = (1 << 64) - 1


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _MASK if n else x


def _keccak_f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data) + b"\x01" + b"\x00" * ((rate - (len(data) + 1) % rate) % rate)
    padded[-1] |= 0x80
    state = [[0] * 5 for _ in range(5)]
    for offset in range(0, len(padded), rate):
        block = padded[offset:offset + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            state[x][y] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")
        state = _keccak_f(state)
    out = b"".join(state[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


def selector(signature: str) -> str:
    return "0x" + keccak256(signature.encode()).hex()[:8]


# ---------------------------------------------------------------- signatures
def arg_types(signature: str) -> list[str]:
    """The page's ABI encoder types for a flat signature."""
    inner = signature[signature.index("(") + 1:-1]
    out = []
    for raw in filter(None, inner.split(",")):
        if re.fullmatch(r"u?int\d*", raw):
            out.append("uint")
        elif raw in ("address", "bytes32", "string", "bytes", "bytes32[]", "bytes[]"):
            out.append(raw)
        else:
            raise ValueError(f"{signature}: argument type {raw} is not supported on the consumer screen")
    return out


# ---------------------------------------------------------------- validation
def validate(screen: dict, interface: dict[str, dict]) -> list[str]:
    """interface: signature -> interface row of the primary contract."""
    errors = []
    if not isinstance(screen, dict) or set(screen) - SCREEN_KEYS or "action" not in screen or "lede" not in screen:
        return [f"screen needs lede and action and only {sorted(SCREEN_KEYS)}"]
    for key in ("lede", "note"):
        if key in screen and not (isinstance(screen[key], str) and 0 < len(screen[key]) <= TEXT_MAX):
            errors.append(f"screen.{key} must be 1..{TEXT_MAX} characters")
    inputs = screen.get("inputs", [])
    input_ids = [i.get("id") for i in inputs]
    if len(set(input_ids)) != len(input_ids):
        errors.append("screen input ids must be unique")
    for i in inputs:
        if set(i) - INPUT_KEYS or not ID.fullmatch(str(i.get("id"))) or i.get("unit") not in UNITS or not i.get("label"):
            errors.append(f"screen input {i.get('id')!r}: needs id, label and a unit in {sorted(UNITS)}")
    reads = screen.get("reads", [])
    read_ids = [r["id"] for r in reads if "id" in r]
    if len(set(read_ids)) != len(read_ids):
        errors.append("screen read ids must be unique")

    def source_ok(src, allow_reads):
        if not isinstance(src, str):
            return False
        if src == "$account":
            return True
        if src.startswith("$read:"):
            return allow_reads and src[6:] in read_ids
        if src.startswith("$"):
            return src[1:] in input_ids
        return True

    def check_call(where, entry, writes):
        row = interface.get(entry.get("call"))
        if row is None:
            errors.append(f"screen {where}: {entry.get('call')!r} is not a function of the primary contract's interface")
            return
        view = row["mutability"] in ("view", "pure")
        if view == writes:
            errors.append(f"screen {where}: {entry['call']} must be {'a write' if writes else 'a read'}")
        try:
            types = arg_types(entry["call"])
        except ValueError as error:
            errors.append(f"screen {where}: {error}")
            return
        args = entry.get("args", [])
        if len(args) != len(types):
            errors.append(f"screen {where}: {entry['call']} takes {len(types)} arguments, got {len(args)}")
        for src in args:
            if not source_ok(src, writes):
                errors.append(f"screen {where}: unknown source {src!r}")
        if writes and "value" in entry:
            if row["mutability"] != "payable":
                errors.append(f"screen {where}: {entry['call']} is not payable but has a value")
            if not source_ok(entry["value"], True) or not str(entry["value"]).startswith("$"):
                errors.append(f"screen {where}: value must come from an input or a read")
        if writes and row["mutability"] == "payable" and "value" not in entry:
            errors.append(f"screen {where}: {entry['call']} is payable; say where the value comes from")

    for n, r in enumerate(reads):
        if set(r) - READ_KEYS or r.get("show") not in SHOW or not r.get("label"):
            errors.append(f"screen read {n}: needs call, label and a show in {sorted(SHOW)}")
            continue
        if r["show"] in ("bool", "state") and not isinstance(r.get("map"), dict):
            errors.append(f"screen read {n}: show {r['show']} needs a map")
        check_call(f"read {n}", r, writes=False)
        for src in r.get("args", []):
            if isinstance(src, str) and src.startswith("$read:"):
                errors.append(f"screen read {n}: reads cannot depend on other reads")
    for where, entry in [("action", screen["action"])] + [(f"more {n}", m) for n, m in enumerate(screen.get("more", []))]:
        if set(entry) - ACTION_KEYS or not entry.get("label"):
            errors.append(f"screen {where}: needs call and label")
            continue
        check_call(where, entry, writes=True)
    if any(ch in text for text in labels(screen) for ch in "<>&\"`"):
        errors.append("screen text may not contain < > & \" or ` (it is placed into the page as text)")
    progress = screen.get("progress")
    if progress is not None and (set(progress) != {"value", "max"} or not set(progress.values()) <= set(read_ids)):
        errors.append("screen progress needs value and max read ids")
    return errors


def labels(screen: dict) -> list[str]:
    """Every person-facing string, for the neutral-wording check."""
    out = [screen.get("lede", ""), screen.get("note", "")]
    for group in ("reads", "inputs", "more"):
        for entry in screen.get(group, []):
            out += [entry.get("label", ""), entry.get("hint", ""), entry.get("placeholder", "")]
            out += [str(v) for v in entry.get("map", {}).values()]
    out.append(screen["action"].get("label", ""))
    return [s for s in out if s]


# ---------------------------------------------------------------- page form
def compile_screen(screen: dict) -> dict:
    """The screen as the page embeds it: calls gain sel and ABI types."""
    def call(entry):
        return {**entry, "args": list(entry.get("args", [])), "sel": selector(entry["call"]), "types": arg_types(entry["call"])}
    page = {"lede": screen["lede"], "inputs": [dict(i) for i in screen.get("inputs", [])],
            "reads": [call(r) for r in screen.get("reads", [])], "action": call(screen["action"]),
            "more": [call(m) for m in screen.get("more", [])]}
    for key in ("note", "progress"):
        if key in screen:
            page[key] = screen[key]
    return page
