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

## Status (2026-10-07)

Done, with offline tests; **not yet seen on a real server** (see the last
bullet).

- **Personal bests** (`lua/bmx/sv_scores.lua`): best combo, best trick, longest
  grind, longest manual, biggest air, per player (SteamID64) per map per bike,
  fed by the public hooks `BMX_TrickLanded` / `BMX_ComboBanked`. The scoring now
  puts `air`, `held` and `grind` on the trick tables it already built.
  Saved to `data/bmx/scores/<map>.json`, batched at most every 30 s and on
  `ShutDown`. Only the **top ten of each stat** is kept, so a player outside it
  has a session-only best until they make the table (stated in the file).
- **Panel and banner** (`cl_scores.lua`): `bmx_scores` with a tab per stat and a
  bike filter, and a NEW BEST banner. The banner is its own `HUDPaint` hook
  rather than code in `cl_hud.lua`, so the HUD can be redesigned without
  touching it (it borrows that file's fonts and `bmx_hud`).
- **Leaderboard sign** (`entities/bmx_leaderboard`): 3D2D, cycles the five
  stats or shows one (`bmx_leaderboard_set <stat|all> [bike]`), admin-only
  spawn. Asks for the table only when someone is within reading range.
- **Games** (`sv_games.lua` + `lua/bmx/games/`): small state machines (lobby,
  running, done), one at a time, with `bmx_game_start skate|attack|mambo
  [bot]`, `bmx_game_join`, `bmx_game_leave`, `bmx_game_status`,
  `bmx_games_admin_only`, and one generic HUD panel (`cl_games.lua`).
  - **SKATE**: 2-8 players, set/follow, letters, trick-id match (and count),
    setter who bails gets no letter, timeouts, leavers handled.
  - **Trick Attack** (2:00, trick points + combo bonuses) and **Combo Mambo**
    (1:00, best single combo), both take latecomers.
  - **The trick bot** is a SKATE opponent (`bmx_game_start skate bot`): it sets
    from `BMX.Bot.TrickList` and follows with `BMX.Bot.Perform`, through the
    same scoring hooks a human's tricks use; sent home when the game ends.
- **Exclusions** (`BMX.Scores.Counts`): bots, scripted riders, noclip, and a
  bike held (or dropped within 3 s) by a physgun do not count, for the table
  and for games. A bot the game itself invited counts in that game only.
- **Hooks for gamemodes**: `BMX_NewBest`, `BMX_GameStarted`, `BMX_GameEnded`,
  `BMX_GameLetter` (documented in `docs/MODDING.md`).
- **Tests**: `tests/test_scores.lua`, `tests/test_games.lua` (bests, persistence,
  batching, sort and cap, SKATE turn by turn, timed games, exclusions, the wire
  and HUD), plus `skate_game_with_bots` in `sv_test_cases.lua` (two bots).
  **The headless case has not been run**: there is no GMod server in this
  environment. It only asserts that a game reaches a result, not who wins.

Left: the time trial / checkpoint entities and the letter-Collect pickups (not
started; the framework takes them as new `Register`ed games plus entities);
CAMI restriction (a convar, `bmx_games_admin_only`, stands in); a real-server
look at the sign's 3D2D layout and the panel; `sql.*` storage; a vehicle
family match for SKATE once G22 gives vehicles families.
