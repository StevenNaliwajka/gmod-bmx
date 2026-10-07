# G08 -- A public place for bugs and suggestions

**Competitor:** [#8](https://github.com/luttje/gmod-bicycle/issues/8) (closed):
the "Which bike?" field became optional, with an "All bikes" option. That's a
detail, but it shows how far along they are: they have **structured issue
templates** (bug, suggestion, tuning feedback with a "tuning dump" field), and
their players use them. 12 of their 16 issues came from that process.

**Us today:** the repo is on a LAN GitLab (`gitlab.lan`) that players can't
reach. The Workshop page is our only channel, and it has no comments yet. We
have `bmx_dump_config`, which is the same idea as their tuning dump.

## Goal

Players and server owners can report a bug or suggest a trick in under a
minute, in a form we can act on, and they can see it get done.

## Done when

- A public tracker exists. Either a GitHub mirror of the repo (read-only,
  pushed from GitLab CI) with Issues on, or Issues only on an empty public repo.
  **The owner chooses.**
- Templates: **Bug** (map, gamemode, SP/MP, branch, console errors,
  `bmx_dump_config` output, which vehicle with "all" allowed), **Feel**
  (what feels off, which vehicle, a video), **Suggestion**.
- `bmx_report` (client) prints a ready-to-paste block: version, map, tick,
  vehicle, config diff from default and the last 20 `[BMX]` console lines.
- The Workshop description links to the tracker. A "Change Notes" entry per
  update says which reports it fixed.

## Approach

GitLab CI already runs on push. Add a `mirror-github` job (deploy key, push
`main` and tags only) if the mirror route is chosen. Templates go in
`.github/ISSUE_TEMPLATE/*.yml`.

## Tests

- Offline: `bmx_report` output contains every field and stays under 4 KB.

## Risks

Making the code public. `docs/DESIGN.md` is very detailed, and a
competitor could read it. They are already ahead on reach, though, and an
open repo is what got them their issue reports. The owner decides.

## Status (2026-10-07)

Only the in-repo parts are done, on the worktree branch. **No public repo, no
mirror job** (the owner has not decided), and the Workshop description does not
link a tracker yet.

- `lua/bmx/cl_report.lua`: client command `bmx_report` prints and copies a block
  with version, map, gamemode, SP/MP, tick rate, the bike you are on, every
  setting that is not at its default (the tuning convars plus the server and
  volume settings, each with its default), and the last 20 `[BMX]` console lines.
  The console is buffered by wrapping `MsgN` / `ErrorNoHalt` once. Capped at
  4000 bytes: oldest console lines go first, then the settings list; the header
  never does. Only the client's console is covered; the report says so.
- `.github/ISSUE_TEMPLATE/bug.yml`, `feel.yml`, `suggestion.yml` (GitHub issue
  forms). They will take effect only once a GitHub repo exists; the GitLab
  instance ignores them.
- Tests: `tests/test_report.lua` (fields, defaults diff, 20-line window, 4 KB cap
  and squeeze, command, template shape).
- Left: the owner's choice of tracker, the mirror job if any, a Workshop
  description link, and "Change Notes" naming fixed reports.
