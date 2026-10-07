# G28 -- Replays and a clip camera

**Competitor:** none.

**Us today:** a cinematic camera (`cl_cinematic.lua`, L) and an eased chase
cam. The bikes network a small state struct, which is the raw material for a
replay.

## Goal

A rider can watch their last line back from any angle and record it.
Shareable clips are the cheapest marketing a Workshop item gets, because
every YouTube/TikTok clip of our addon is an ad (G29).

## Done when

- The client keeps a rolling **ring buffer** of the last 30 s of its own
  vehicle state at 33 Hz (position, angles, wheel/part angles, rider pose id,
  trick events), plus nearby riders' networked states.
- `bmx_replay` (or a key after a combo banks): plays back the buffer with
  free camera, chase, fixed filmer (G21) and a **fisheye "filmer follow"**
  (the classic skate video look), with slow-motion and scrub.
- The HUD replays the combo text in sync.
- Saves a replay to `data/bmx/replays/*.txt` (compressed) to watch later
  or send to a friend, who can play it on the same map.
- No server load: entirely client-side.

## Approach

Playback spawns client-only `ClientsideModel` stand-ins (or draws the
procedural vehicle at the buffered pose), and the rider model is a clientside
ragdoll-free model with the IK from `cl_rider.lua` fed buffered targets.

## Tests

- Offline: ring buffer wraparound, compress/decompress round-trip,
  playback interpolation.

## Risks

Player-model animation playback in a clientside model needs care. Start
with the vehicle plus a static rider pose.

## Status (2026-10-07)

Built, client-only, in `lua/bmx/cl_replay.lua` (and `cl_filmer.lua` for the
camera maths). **Unverified in a live client**: everything below is tested
offline as maths and data, none of it has been watched on screen.

- **Ring buffer:** the last 30 s at 33 Hz of your bike and every bike within
  3000 units: position, angles, steer, both wheel angles, crank, frame and
  bar spin (tailwhips, barspins), style pose id, stance, in-air. Plus two
  event streams from the HUD (tricks landed, the combo as it builds / lands /
  bails). `bmx_replay_buffer 0` turns recording off.
- **Playback:** `bmx_replay` (or `bmx_replay_key`, default J) with four
  cameras: `chase` (orbit), `free` (WASD, Space/Ctrl, Shift), `filmer`
  (fixed: a real `bmx_filmer_cam` if the map has one, else a spot beside the
  run) and `follow` (low, close, lagged, `bmx_replay_fov` 112 plus a
  vignette: the skate-video look). `bmx_replay_speed` (negative plays
  backwards), `bmx_replay_seek`, `bmx_replay_pause`, and keys P / arrows /
  1-4 while it plays. The combo text replays in sync, as a function of time,
  so scrubbing back works.
- **Stand-ins:** ENT:Draw cannot be called on a buffered pose (it reads the
  entity and traces the wheels), so a replay draws a simplified wireframe
  bike (two wheel rings with a spoke, frame, steering fork, whip) in the
  bike's colour plus a static clientside rider in the airboat pose with the
  stance's torso lean. No IK on the replayed rider yet.
- **Save / load:** `bmx_replay_save [name]`, `bmx_replay_load <name>`,
  `bmx_replay_list`: `data/bmx/replays/<name>.txt`, `BMXR1` + util.Compress'd
  JSON, or `BMXR0` + plain JSON when there is no compressor. Integers
  throughout. A loaded file is size- and type-checked and refused on a
  different map unless forced.
- **Left:** the rider's seat offset (`BMX.Replay.RiderOffset`) is eyeballed;
  IK and the pedalling legs on the replayed rider; a clip exporter (G29);
  recording other riders' combo text (only your own events are kept).
  Your live bike gets no input while a replay plays (it is cleared in
  CreateMove), so stop the replay before riding on.
- **Tests:** `tests/test_replay.lua`: ring wraparound (and the real 30 s
  window), sampler interpolation (angle wrap, holes, discrete state), the
  overlay's timing, compress/decompress round trip with and without a
  compressor, a stranger's malformed file, save/load by name, the recorder
  against a client bike, the commands, and the stand-in's geometry.
