# Contributing

Thanks for wanting to help. Please read the licensing model below before opening a PR —
it's what lets this game stay GPL *and* ship on consoles and iOS.

## Licensing model

### 1. Copyright stays consolidated (CLA required)
The project maintainer must hold the right to relicense every line of code in this repo.
Before your first PR can be merged you'll be asked to sign a Contributor License Agreement
(via CLA Assistant on the PR). It grants the maintainer a perpetual, irrevocable right to
use, modify, sublicense and relicense your contribution, including under proprietary terms.
You keep your own copyright and may reuse your work however you like.

Without a signed CLA, contributions cannot be merged — no exceptions, since a single
unlicensed contribution would block platform releases.

### 2. Dual licensing: public GPL, private platform ports
- **This repository** is licensed under the **GNU GPL v3** (see `LICENSE`). It must always
  build and run as a complete game on desktop and web from public code alone.
- **Console and app-store builds** are distributed by the maintainer under separate
  proprietary terms, as permitted by (1).
- **Platform SDK code** (console SDKs, NDA-covered APIs, store integrations) never enters
  this repo. It lives in a private porting repository. Don't submit PRs containing NDA material.

### 3. Code is GPL; assets and name are not
- **Code** (`.gd`, `.tscn`, `.godot`, tooling, tests): GPLv3.
- **Assets** (art, audio, music, fonts we commission, and anything under `assets/`):
  **all rights reserved** unless a file or `assets/LICENSE` says otherwise. Forks may use
  the code but must supply their own assets.
- **Name and branding** ("Finally A Block Game That Doesn't Suck", logos): trademarks of
  the maintainer. Forks must ship under a different name.

Never port code or assets from other GPL games (including Crack Attack, which inspired this
one): we don't hold their copyright, so it couldn't be relicensed for platform builds. Matching
behaviour from observation is fine; copying is not.

When contributing assets, state their origin and license in the PR. Only original work or
work under a license compatible with the above is accepted.

## Practicalities
- Run `godot --headless --path . -s tests/test_netcode.gd` and make sure it prints PASS
  before opening a PR touching `sim/`.
- Everything that affects gameplay goes in `sim/`: integer-only, no nodes, no engine RNG.
- Short imperative commit messages (`Add garbage blocks`, `Fix cursor wrap`).

*This document describes project policy, not legal advice.*
