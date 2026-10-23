#!/usr/bin/env python3
"""Fit the CPU's board-shape weights from league positions (tools/league.gd --positions).

Each sample is (own features - opponent features) at one moment, labelled +1 if
that side went on to win. A linear model with no bias on that difference is a
ranking model: its weights score each board on its own, which is exactly how
CpuPlayer._shape uses them. Fits an L2-SVM (squared hinge) and logistic
regression with numpy, splits train/test by game so positions never leak, and
scores the hand-tuned styles as predictors on the same test set.

    python3 tools/fit_weights.py data/march1 [--min-frame 600]
"""
import glob
import json
import sys

import numpy as np

FEATURES = ["pairs", "bump", "height", "danger"]  # matches CpuPlayer.FEATURES
SIGN = np.array([1.0, -1.0, -1.0, -1.0])  # style weights: pairs rewarded, the rest subtracted
STYLES = {  # shape weights from ai/cpu_player.gd STYLES
    "balanced": [2.0, 3.0, 0.5, 40.0],
    "chainer": [4.0, 2.0, 0.3, 40.0],
    "comboer": [3.0, 3.0, 0.5, 40.0],
    "turtle": [1.0, 5.0, 2.0, 90.0],
}


def load(dirs, min_frame):
    xs, ys, seeds, left = [], [], [], []
    length = {}
    for d in dirs:
        for path in glob.glob(f"{d}/games-w*.jsonl"):
            with open(path) as f:
                for line in f:
                    g = json.loads(line)
                    length[g["seed"]] = g["frames"]
    for d in dirs:
        for path in glob.glob(f"{d}/positions-w*.jsonl"):
            with open(path) as f:
                for line in f:
                    r = json.loads(line)
                    if r["label"] == 0.5 or r["frame"] < min_frame:
                        continue
                    xs.append(np.subtract(r["own"], r["opp"]))
                    ys.append(1.0 if r["label"] == 1.0 else -1.0)
                    seeds.append(r["seed"])
                    left.append((length.get(r["seed"], r["frame"]) - r["frame"]) / 60)
    return np.array(xs), np.array(ys), np.array(seeds), np.array(left)


def fit_svm(x, y, lam=1e-3, iters=3000, lr=0.5):
    """L2-regularised squared-hinge SVM, no bias, full-batch gradient descent."""
    w = np.zeros(x.shape[1])
    for _ in range(iters):
        m = np.maximum(0.0, 1.0 - y * (x @ w))
        grad = lam * w - 2.0 * (x * (y * m)[:, None]).mean(axis=0)
        w -= lr * grad
    return w


def fit_logistic(x, y, iters=50):
    """Newton's method, tiny ridge for stability."""
    w = np.zeros(x.shape[1])
    t = (y + 1) / 2
    for _ in range(iters):
        p = 1 / (1 + np.exp(-(x @ w)))
        g = x.T @ (p - t) / len(t) + 1e-6 * w
        h = (x * (p * (1 - p))[:, None]).T @ x / len(t) + 1e-6 * np.eye(len(w))
        w -= np.linalg.solve(h, g)
    return w


def acc(w, x, y):
    s = x @ w
    keep = s != 0  # ties (identical boards) say nothing
    return float((np.sign(s[keep]) == y[keep]).mean()), float(keep.mean())


def main(argv):
    min_frame = 600
    if "--min-frame" in argv:
        i = argv.index("--min-frame")
        min_frame = int(argv[i + 1])
        del argv[i:i + 2]
    x, y, seeds, left = load(argv or ["data/march1"], min_frame)
    test = seeds % 2 == 1
    print(f"{len(y)} positions ({test.sum()} test), frame >= {min_frame}, {(y > 0).mean():.0%} positive\n")

    scale = x[~test].std(axis=0)
    scale[scale == 0] = 1.0
    xs = x / scale
    w_svm = fit_svm(xs[~test], y[~test]) / scale
    w_log = fit_logistic(xs[~test], y[~test]) / scale

    print(f"{'model':12s} {'test acc':>8s} {'decided':>8s}   " + " ".join(f"{f:>8s}" for f in FEATURES))
    rows = [("svm", w_svm), ("logistic", w_log)] + [(n, SIGN * np.array(v)) for n, v in STYLES.items()]
    for name, w in rows:
        a, dec = acc(w, x[test], y[test])
        print(f"{name:12s} {a:8.1%} {dec:8.0%}   " + " ".join(f"{v:8.3f}" for v in w))

    print("\ntest accuracy by seconds before the game ended:")
    buckets = [(0, 5), (5, 15), (15, 30), (30, 60), (60, 1e9)]
    print(f"  {'model':12s} " + " ".join(f"{f'{a:.0f}-{b:.0f}s' if b < 1e9 else f'{a:.0f}s+':>8s}" for a, b in buckets))
    for name, w in rows:
        cells = []
        for a, b in buckets:
            sel = test & (left >= a) & (left < b)
            cells.append(f"{acc(w, x[sel], y[sel])[0]:8.1%}" if sel.any() else f"{'-':>8s}")
        print(f"  {name:12s} " + " ".join(cells))

    # Match the learned heuristic's typical magnitude to balanced's so it sits in
    # the same range as the reward terms; the ring then tries multiples.
    bal = SIGN * np.array(STYLES["balanced"])
    k = (x @ bal).std() / (x @ w_svm).std()
    style = SIGN * w_svm * k  # back to style convention
    print("\nlearned style weights (svm, calibrated to balanced's range):")
    print("  " + ", ".join(f'"{f}": {v:.3f}' for f, v in zip(FEATURES, style)))
    for mult in (0.5, 1.0, 2.0):
        print("  spec x%.1f: ?" % mult + "&".join(f"{f}={v * mult:.3f}" for f, v in zip(FEATURES, style)))


if __name__ == "__main__":
    main(sys.argv[1:])
