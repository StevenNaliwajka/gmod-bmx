--[[--------------------------------------------------------------------------
    tests/data/reference_angles.lua

    JOINT ANGLES OF REAL RIDERS, measured off footage, for tests/test_lifelike.lua.

    HOW (2026-10-22, tools/rider/refpose): MediaPipe's pose model
    (pose_landmarker_heavy) run frame by frame over each clip, its 3D "world"
    landmarks turned into the same angles tests/test_lifelike.lua measures on
    kleiner's posed skeleton:

      knee    flexion, 0 = a straight leg
      hip     flexion, the trunk to the thigh, 0 = in line (a person standing reads
              about 15 by this measure, on the footage and on kleiner's idle alike)
      trunk   lean forward of upright (the shoulders' middle over the hips')
      elbow   flexion, 0 = a straight arm
      abd     the upper arm out from the trunk's line down, 0 = at the side

    Each row is the 10th to 90th percentile of the frames in a phase where the
    tracker had the whole body (its landmarks' visibility over 0.5, or 0.3 where
    marked), so a stray frame does not set the range. The clips are children and
    adults, filmed from the front, the side and three quarters; a range here is what
    real riders do across that, not one rider's number. Only these numbers are kept:
    the clips themselves are on Wikimedia Commons under their licences.

    SOURCES
      ollie1   "Ollie 1.ogv", Medve, CC BY-SA 3.0
               https://commons.wikimedia.org/wiki/File:Ollie_1.ogv
      ollie2   "Ollie 2.ogv", Medve, CC BY-SA 3.0
               https://commons.wikimedia.org/wiki/File:Ollie_2.ogv
      kenya    "Kenyan skateboarding.webm", Drewperez1, CC BY-SA 4.0
               https://commons.wikimedia.org/wiki/File:Kenyan_skateboarding.webm
      kidbike  "Bicycle-slowmotion-ride-park-kid2013.ogv", Nesnad, CC BY-SA 4.0
               https://commons.wikimedia.org/wiki/File:Bicycle-slowmotion-ride-park-kid2013.ogv
      bmx      "Day of the Town (2017-09-09) - Freestyle BMX - 0029.webm", Zelio007, CC BY-SA 4.0
               https://commons.wikimedia.org/wiki/File:Day_of_the_Town_(2017-09-09)_-_Freestyle_BMX_-_0029.webm
----------------------------------------------------------------------------]]

return {
    board = {
        -- rolling along, before a trick (kenya 1.4-1.9 s, ollie2 2.67-3.1 s after the landing)
        cruise  = { knee = { 50, 98 }, hip = { 42, 78 }, trunk = { 7, 40 }, from = "kenya, ollie2" },
        -- the ollie's crouch, just before the pop (ollie1 1.00-1.08 s, ollie2 1.71-1.88 s)
        crouch  = { knee = { 101, 127 }, hip = { 78, 133 }, trunk = { 38, 55 }, from = "ollie1, ollie2" },
        -- the pop: the legs straightened off the tail (ollie1 1.21-1.33 s, ollie2 2.04-2.08 s)
        pop     = { knee = { 26, 73 }, trunk = { 21, 30 }, from = "ollie1, ollie2" },
        -- the top of the air, the knees pulled up (ollie1 1.50-1.62 s, ollie2 2.21-2.38 s)
        tuck    = { knee = { 85, 128 }, abd = { 60, 120 }, from = "ollie1, ollie2" },
        -- the landing's fold (ollie1 1.71-2.08 s, kenya 4.13-4.40 s)
        landing = { knee = { 47, 90 }, hip = { 54, 89 }, trunk = { 35, 60 }, from = "ollie1, kenya" },
        -- a push, the standing leg (kenya 0.0 s)
        push    = { standKnee = { 73, 103 }, from = "kenya" },
    },
    bike = {
        -- seated, pedalling along (kidbike 0.5-9.6 s): the knee over the stroke, the back
        seated  = { kneeMin = { 19, 48 }, kneeMax = { 72, 103 }, trunk = { 18, 34 }, from = "kidbike" },
        -- standing on the pedals, level (bmx 0-3.2 s) and rolling into a ramp (bmx 3.4-5.9 s, vis 0.3)
        standing = { knee = { 29, 57 }, elbow = { 29, 64 }, from = "bmx" },
        attack  = { trunk = { 5, 65 }, from = "bmx" },
    },
}
