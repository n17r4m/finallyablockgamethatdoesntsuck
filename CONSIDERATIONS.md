# Considerations

Options under consideration but not adopted. Nothing here is in effect.

## GPLv3 Section 7 app-store / console exception

GPLv3 §7 allows "additional permissions". We could append one to `LICENSE` that explicitly
permits distributing the game (or modified versions) through app stores and console
platforms whose terms add restrictions incompatible with the GPL.

**For**
- Lets the community, not just the maintainer, port and ship builds on restricted platforms.
- Signals goodwill; keeps the "most GPL" spirit while acknowledging platform reality.

**Against / caveats**
- Downstream may remove additional permissions from their own modifications (§7), so forks
  can drop it. It only reliably covers code contributed back upstream under the CLA.
- Lets third parties ship competing builds on stores — mitigated by assets and name not
  being GPL (see CONTRIBUTING.md §3), but worth weighing.
- Wording must be reviewed by a lawyer; sloppy exceptions create ambiguity.

**Revisit when:** first console/iOS release is planned, or community porting interest appears.
