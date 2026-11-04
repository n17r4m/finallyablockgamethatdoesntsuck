#!/usr/bin/env python3
"""Checks replays and hash vectors against docs/engine-contract.md, with no Godot involved.

    python3 tools/replay_check.py tests/golden
    python3 tools/replay_check.py some_game.fbgr

This reads the spec's byte layout independently of sim/replay.gd. It can't re-simulate, so
it doesn't prove a game is genuine: that needs a sim. It proves the formats don't depend on
the engine: if the two ever disagree, either the code or the spec is wrong.
"""
import hashlib
import json
import pathlib
import struct
import sys

MAGIC = b"FBGR"
TRAILER = 8
INPUT_BITS = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | (1 << 16) | (0x7 << 8) | (0xF << 12)


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, n):
        if self.pos + n > len(self.data):
            raise ValueError("truncated")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u8(self):
        return self.take(1)[0]

    def var(self):
        value = shift = 0
        while True:
            byte = self.u8()
            if shift > 55 or (byte == 0 and shift > 0):
                raise ValueError("bad varint")
            value |= (byte & 0x7F) << shift
            if byte < 0x80:
                return value
            shift += 7


def parse(raw):
    if len(raw) < 18 + TRAILER:
        raise ValueError("too short")
    body, trailer = raw[:-TRAILER], raw[-TRAILER:]
    if hashlib.sha256(body).digest()[:TRAILER] != trailer:
        raise ValueError("trailer mismatch")
    r = Reader(body)
    if r.take(4) != MAGIC:
        raise ValueError("bad magic")
    out = {"format": r.u8()}
    if out["format"] != 1:
        raise ValueError("unknown format")
    out["rules"], out["tick_hz"] = struct.unpack("<HH", r.take(4))
    out["solo"] = r.u8() == 1
    out["seed"] = struct.unpack("<q", r.take(8))[0]
    out["end_tick"] = r.var()
    out["start_hash"] = r.take(8)
    setup = []
    for _ in range(r.var()):
        kind, board = r.u8(), r.u8()
        args = {0: 0, 1: 3, 2: 2}[kind]
        setup.append((kind, board) + tuple(r.take(args)))
    out["setup"] = setup
    out["inputs"] = []
    for _ in range(2):
        events = []
        tick = -1
        for _ in range(r.var()):
            delta = r.var()
            mask = r.var()
            if delta < 1:
                raise ValueError("input ticks must ascend")
            tick += delta
            if tick >= out["end_tick"] or mask & ~INPUT_BITS:
                raise ValueError("bad input event")
            events.append((tick, mask))
        out["inputs"].append(events)
    checks = []
    tick = 0
    for _ in range(r.var()):
        delta = r.var()
        if delta < 1:
            raise ValueError("checkpoints must ascend")
        tick += delta
        checks.append((tick, r.take(8)))
    out["checkpoints"] = checks
    if not checks or tick != out["end_tick"]:
        raise ValueError("last checkpoint isn't the end")
    if r.pos != len(body):
        raise ValueError("trailing bytes")
    return out


# The field table from docs/engine-contract.md: b = bytes, i = i32s, n = int, f = bool.
BOARD_FIELDS = [
    ("color", "b"), ("st", "b"), ("tm", "i"), ("aux", "i"), ("chain", "b"), ("gid", "i"),
    ("reveal", "b"), ("next_row", "b"), ("cursor_x", "n"), ("cursor_y", "n"),
    ("prev_input", "n"), ("hold", "n"), ("rise", "n"), ("stop_t", "n"), ("health", "n"),
    ("rng", "n"), ("score", "n"), ("lost", "f"), ("busy", "f"), ("need_scan", "f"),
    ("need_support", "f"), ("has_matched", "f"), ("chain_n", "n"), ("outbox", "i"),
    ("gar_q", "i"), ("gar_t", "n"), ("gar_side", "n"), ("next_gid", "n"), ("fx_combo", "n"),
    ("fx_chain", "n"), ("fx_t", "n"), ("age", "n"), ("sent", "n"), ("best_chain", "n"),
    ("swaps", "n"), ("time_rate", "n"), ("world_acc", "n"), ("ramp_t", "n"),
    ("cracking", "f"), ("crack_hang", "n"),
]
CELLS = 6 * 24


def parse_board(r):
    board = {}
    for name, kind in BOARD_FIELDS:
        if kind == "n":
            board[name] = struct.unpack("<q", r.take(8))[0]
        elif kind == "f":
            board[name] = r.u8()
            if board[name] > 1:
                raise ValueError(f"{name} isn't 0 or 1")
        else:
            count = struct.unpack("<I", r.take(4))[0]
            size = 1 if kind == "b" else 4
            board[name] = r.take(count * size)
            expected = {"color": CELLS, "st": CELLS, "tm": CELLS, "aux": CELLS, "chain": CELLS,
                        "gid": CELLS, "reveal": CELLS, "next_row": 6}.get(name)
            if expected is not None and count != expected:
                raise ValueError(f"{name} has {count} elements, not {expected}")
    return board


def parse_state(data):
    """Walks the canonical bytes by the spec's table. Every byte must be accounted for."""
    r = Reader(data)
    tick = struct.unpack("<q", r.take(8))[0]
    solo = r.u8()
    winner = struct.unpack("<q", r.take(8))[0]
    if solo > 1 or winner not in (-1, 0, 1, 2):
        raise ValueError("bad state header")
    boards = [parse_board(r), parse_board(r)]
    if r.pos != len(data):
        raise ValueError(f"{len(data) - r.pos} bytes left over")
    for b in boards:
        if not 0 <= b["cursor_x"] <= 4 or not 12 <= b["cursor_y"] <= 23:
            raise ValueError("cursor out of bounds, so the fields are misaligned")
    return tick, boards


def check_vectors(path, replays):
    """Each vector's bytes must fit the spec's table, hash to its hash, and tie to its replay."""
    vectors = json.loads(path.read_text())
    for v in vectors:
        data = bytes.fromhex(v["bytes"])
        parse_state(data)
        digest = hashlib.sha256(data).digest()[:8]
        if digest.hex() != v["hash"]:
            raise ValueError(f"vector {v['replay']}@{v['tick']}: hash mismatch")
        if struct.unpack("<q", data[:8])[0] != v["tick"]:
            raise ValueError(f"vector {v['replay']}@{v['tick']}: bytes don't start with the tick")
        replay = replays[v["replay"]]
        if v["tick"] == 0 and digest != replay["start_hash"]:
            raise ValueError(f"vector {v['replay']}@0: not the replay's start hash")
        for tick, digest_at in replay["checkpoints"]:
            if tick == v["tick"] and digest != digest_at:
                raise ValueError(f"vector {v['replay']}@{v['tick']}: not the replay's checkpoint")
    return len(vectors)


def main(args):
    if len(args) != 1:
        print(__doc__)
        return 2
    target = pathlib.Path(args[0])
    files = sorted(target.glob("*.fbgr")) if target.is_dir() else [target]
    replays = {}
    failed = 0
    for f in files:
        try:
            replays[f.stem] = parse(f.read_bytes())
        except (ValueError, KeyError, struct.error) as e:
            print(f"FAIL {f.name}: {e}")
            failed += 1
    if not target.is_dir() and failed == 0:
        r = replays[target.stem]
        print(f"format {r['format']}, rules {r['rules']}, {r['tick_hz']} Hz, seed {r['seed']}, "
              f"{r['end_tick']} ticks, solo {r['solo']}, {len(r['setup'])} setup ops, "
              f"inputs {len(r['inputs'][0])}/{len(r['inputs'][1])}, {len(r['checkpoints'])} checkpoints")
    vectors = 0
    if target.is_dir() and (target / "vectors.json").exists():
        try:
            vectors = check_vectors(target / "vectors.json", replays)
        except (ValueError, KeyError) as e:
            print(f"FAIL vectors: {e}")
            failed += 1
    if target.is_dir():
        print(f"{len(replays)} replays parsed, {vectors} hash vectors checked")
    print("PASS" if failed == 0 else f"FAIL ({failed})")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
