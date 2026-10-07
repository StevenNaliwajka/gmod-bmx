# G26 -- High scores, leaderboards, and games to play

**Competitor:** none. Tricks give no score at all.

**Us today:** points and Tony Hawk combos with a HUD (`sv_combo.lua`,
`sv_rules.lua`, `cl_hud.lua`), `bmx_scoring` / `bmx_combos` switches. A score
disappears when the combo banks: there's no best, no table and no game.

## Goal

Turn the scoring we already have (and they don't) into reasons to come back
and to play together. It works across every vehicle (G22).

## Done when

- **Personal bests:** best combo, best single trick, longest grind, longest
  manual and biggest air, per player per map per vehicle. Saved server-side in
  `data/bmx/scores/<map>.json` (sql.* optional), and shown in a
  `bmx_scores` panel and as a "NEW BEST" banner on the HUD.
- **Server leaderboard:** top 10 per map for each stat. An in-world
  **leaderboard sign entity** that admins can place in the park, drawn with
  3D2D.
- **Games** (each one a small mode entity or command, run by anyone unless
  CAMI-restricted):
  - **SKATE / HORSE:** 2-8 players take turns. The setter lands a trick,
    the others must land the same one (same trick id, any vehicle of the same
    family) or get a letter. It's our trick names that make this possible.
  - **Trick Attack** (THPS 2-minute run): the best total in 2:00, with a
    countdown HUD.
  - **Combo Mambo:** best single combo in the time limit.
  - **Trials / time trial:** checkpoint entities and a lap timer. Dabs
    count as faults (G15's Trials, but for every vehicle).
  - **Collect** (THPS S-K-A-T-E letters): admins drop letter pickups on
    hard-to-reach spots.
- Gamemode hooks for everything (G20), so DarkRP can pay money for
  combos and Petopia/TTT servers can run a BMX round.
- Anti-cheat basics: scores from bot riders (`bmx_bot_*`) and from
  noclip/physgun-carried bikes don't count.

## Approach

`sv_scores.lua` listens to `BMX_ComboBanked` / `BMX_TrickLanded`. Each game is
a small state machine in `sv_games/<id>.lua` with join/leave/turn/end and its
own HUD panel. The trick bot can be a SKATE opponent (`bmx_bot_trick` already
does named tricks), which gives a single player someone to play.

## Tests

- Offline: bests update and persist, leaderboards sort and cap, the SKATE
  letter logic, the bot and physgun exclusions.
- Headless `skate_game_with_bots`: two bots play to a result without errors.

## Risks

Persistence on servers with lots of players. Write on change, batched every
30 s, and keep the top 10 only.
