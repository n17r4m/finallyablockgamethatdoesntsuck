#!/usr/bin/env python3
"""Summarise tools/league.gd output: per-pairing records with Wilson 95% intervals,
Bradley-Terry ratings (Elo scale), and per-agent averages. Stdlib only.

    python3 tools/league_report.py data/run1 [data/run2 ...]
"""
import glob
import json
import math
import sys
from collections import defaultdict


def wilson(wins, n, z=1.96):
    """95% Wilson score interval for a win rate (draws counted as half)."""
    if n == 0:
        return (0.0, 1.0)
    p = wins / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def bradley_terry(pairs, agents, iters=500):
    """MM fit of Bradley-Terry strengths; returns Elo-scaled ratings, mean 1500."""
    s = {a: 1.0 for a in agents}
    wins = defaultdict(float)
    games = defaultdict(float)
    for (a, b), (wa, wb, n) in pairs.items():
        wins[a] += wa
        wins[b] += wb
        games[(a, b)] += n
        games[(b, a)] += n
    for _ in range(iters):
        new = {}
        for a in agents:
            denom = sum(games[(a, b)] / (s[a] + s[b]) for b in agents if b != a and games[(a, b)])
            new[a] = max(wins[a], 0.5) / denom if denom else s[a]  # 0.5 prior keeps 0-win agents finite
        g = math.exp(sum(math.log(v) for v in new.values()) / len(new))
        s = {a: v / g for a, v in new.items()}
    return {a: 1500 + 400 * math.log10(v) for a, v in s.items()}


def main(dirs):
    recs = []
    for d in dirs:
        for path in glob.glob(f"{d}/games-w*.jsonl"):
            with open(path) as f:
                recs += [json.loads(line) for line in f if line.strip()]
    if not recs:
        sys.exit("no games found")

    pairs = {}  # (a, b) sorted -> [wins a, wins b, games]; draws count half each
    per = defaultdict(lambda: defaultdict(list))
    for r in recs:
        a, b = sorted((r["a"], r["b"]))
        side_a = 0 if r["a"] == a else 1
        p = pairs.setdefault((a, b), [0.0, 0.0, 0])
        p[2] += 1
        if r["winner"] == 2:
            p[0] += 0.5
            p[1] += 0.5
        else:
            p[0 if r["winner"] == side_a else 1] += 1
        for side, agent in enumerate((r["a"], r["b"])):
            st = per[agent]
            st["len"].append(r["frames"] / 60)
            st["timeout"].append(1 if r.get("timeout") else 0)
            for k in ("score", "sent", "best_chain", "swaps", "think_avg_us", "think_max_us"):
                st[k].append(r[k][side])

    agents = sorted(per)
    print(f"{len(recs)} games, {len(agents)} agents\n")
    print("Pairings (win rate of left agent, draws = 1/2, Wilson 95% CI):")
    for (a, b), (wa, wb, n) in sorted(pairs.items()):
        lo, hi = wilson(wa, n)
        sig = "  *" if lo > 0.5 or hi < 0.5 else ""
        print(f"  {a:28s} vs {b:28s} {wa:5.1f}-{wb:<5.1f} n={n:<4d} {wa / n:5.0%} [{lo:4.0%}, {hi:4.0%}]{sig}")
    print("  (* = interval excludes 50%)\n")

    ratings = bradley_terry(pairs, agents)
    mean = lambda xs: sum(xs) / len(xs) if xs else 0
    print(f"{'agent':28s} {'rating':>6s} {'games':>5s} {'len s':>6s} {'t/o':>4s} {'sent':>6s} "
          f"{'chain':>5s} {'swaps':>6s} {'think':>7s} {'worst':>7s}")
    for a in sorted(agents, key=lambda a: -ratings[a]):
        st = per[a]
        print(f"{a:28s} {ratings[a]:6.0f} {len(st['len']):5d} {mean(st['len']):6.0f} "
              f"{mean(st['timeout']):4.0%} {mean(st['sent']):6.0f} {mean(st['best_chain']):5.1f} "
              f"{mean(st['swaps']):6.0f} {mean(st['think_avg_us']):5.0f}us {max(st['think_max_us']) / 1000:5.1f}ms")


if __name__ == "__main__":
    main(sys.argv[1:] or ["data/league"])
