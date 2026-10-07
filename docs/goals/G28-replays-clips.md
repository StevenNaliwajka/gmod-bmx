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
