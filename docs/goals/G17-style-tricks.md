# G17 -- Style tricks: no-hander, no-footer, can-can, X-up, superman

**Competitor:** README "Tricks" table: no-hander (Ctrl + W), no-footer
(Ctrl + S), can-can (Ctrl + A/D, left/right leg), X-up (RMB + W, in the air
or a wheelie), and backflip / front flip on a double-tap of S / W. All are
held as long as the key is held, and they combine ("backflip no-hander").
Tricks are files in `lua/bicycle/tricks/*.lua` with a base-trick metatable.

**Us today:** Ctrl is **tuck** (it spins you faster, `sv_air.lua`), and W/S is
pitch. We have no **pose** tricks, only rotations. The rider IK
(`cl_rider.lua`) can already put hands and feet anywhere, so the poses are
cheap for us.

## Goal

Every pose trick they have, plus the ones they don't (superman, seat grab,
turndown, tabletop, one-footer, nothing), composable with rotations and
scored as a combo. Pose tricks are where we can **beat** them, because we score
them.

## Done when

- **A trick modifier key** (default **Alt**, rebindable in G19). Holding it
  in the air turns W/S/A/D into pose tricks, not rotations:
  - Alt + W **no-hander**, Alt + S **no-footer**, Alt + A/D **can-can** L/R,
    Alt + W + S **superman** (both off, body extended), Alt + Space
    **nothing** (no hands, no feet; huge risk, huge points).
  - RMB + W **X-up** (air or manual), RMB + A/D **turndown** (bars down,
    body twisted).
  - **Tabletop**: Alt + RMB, the bike laid flat in the air.
- Held poses score per 0.1 s held, and releasing **before** landing is
  required. If you land still in the pose, you bail.
- A pose during a rotation = a named compound ("Backflip Superman"),
  scored as both plus a compound bonus.
- The poses are IK targets in `cl_rider.lua` with a 0.15 s blend in and out,
  networked as one byte of pose id.
- **Trick registry:** `BMX.RegisterTrick{ id, name, input, points, pose,
  canStart, onTick }`, in `sh_tricks.lua`, so G20's modders and our own
  vehicles (G23 board grabs) use the same thing. The existing flips and grinds
  migrate onto it.
- Double-tap W/S for a flip, as on theirs, as an *option*
  (`bmx_flip_doubletap 1`), because a hold-to-rotate is better for skill.

## Approach

`sv_input.lua` decodes the modifier, `sv_combo.lua` already chains named
tricks, so pose tricks just add more names. The pose key frees Ctrl to keep
meaning tuck, so nothing existing changes.

## Tests

- Offline: each pose's input decodes, compound names, landing-in-pose bails.
- Offline: trick registry rejects duplicate ids and missing fields.
- Headless `superman_backflip_lands`: the bot does it off the ramp case.

## Risks

Key overload. Ship a **trick list overlay** (hold Tab or `bmx_tricks`)
showing every input. They put theirs in a README table, and a player won't
read that in-game.

## Status (2026-10-07)

Built on branch `worktree-agent-a4c9798db73feff8f` together with G03; offline
suite green (`tests/test_tricks.lua`). Headless cases written, **not run** on a
real server; poses and drawing **not seen** in the game.

| Done when | |
|---|---|
| Modifier key (Alt) turns W/S/A/D into poses in the air | **Done** (`IN_WALK`; rotation keys are zeroed under a pose). Alt + W no-hander, + S no-footer, + A/D can-can L/R, + W + S superman, + SPACE nothing. Rebinding is G19: **not done**. |
| RMB + W X-up (air or manual) | **Done, with a change**: in the air RMB + W. In a manual it takes Alt too (Alt + RMB + W), because RMB + W is a wheelie under power and a pose on it would pay every wheelie. |
| RMB + A/D turndown | **Done, with a change**: Alt + RMB + A/D. RMB + A/D stays the 360, as the task required. |
| Tabletop (Alt + RMB) | **Done**: the bike drawn laid over 70 deg. |
| Held poses pay per 0.1 s; landing in a pose bails | **Done** (`Tricks.poseTick`, `poseMinHold` 0.3 s; reason `pose`). |
| Pose + rotation = compound name, both plus a bonus | **Done**: "Backflip Superman", +25% (`compoundBonus`). A held pose lets a flip coast (`poseSpinDamp`). |
| IK targets in `cl_rider.lua`, 0.15 s blend, one byte on the wire | **Done**, visually unverified: `BMX.RiderPoses`, `UpdatePoseWeights`, `ApplyPoseTargets`; pose id is byte 3 of `TrickBits`. |
| Trick registry `BMX.RegisterTrick{...}` in `sh_tricks.lua`; flips and grinds migrate | **Done.** Flips, barrel roll, 360 score from the registry; wheelie, stoppie and both grinds take their names from it. Ground and grind *points* still come from the config (so bikes can override them); the registry holds the defaults. |
| Optional double-tap flip | **Done** (`bmx_flip_doubletap 1`, userinfo). Tested on the plant: a double-tapped front flip lands. |
| Trick list overlay (`bmx_tricks` / hold key) | **Done**: `bmx_tricks` toggles, `+bmx_tricks` shows while held (bind it); there is no default Tab binding, Tab being the scoreboard. |
| Bot: superman backflip | **Done** (`Superman`, `Superman Backflip`); headless `superman_backflip_lands` written, **not run**. |
| Tests: pose decode, compound names, landing-in-pose bails, registry rejects bad input | **Done offline.** |
