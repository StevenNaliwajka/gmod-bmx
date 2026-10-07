--[[--------------------------------------------------------------------------
    bmx/sh_city_maps.lua

    The city, per map. One table per map name; sh_city.lua builds it. To give
    another map a city, measure its play box and add an entry -- nothing else
    changes.

    THE NUMBERS FOR gm_skatepark ARE MEASURED FROM ITS BSP, not eyeballed
    (2026-10-07, from the brush and entity lumps):

        play box     x -256..3584, y -1792..768, floor z 64
        brick wall   to z 528 on all four sides, 256 thick
        sky brushes  above the wall, ceiling at z 1720
        sun          light_environment pitch -28, yaw 0: light travels +x, so
                     the sun sits low in the WEST and the east row's fronts
                     catch it

    Every ramp in the map was measured too (footprints from the models' own
    vertices, in tests/test_city.lua): the piers stand in the lanes between
    them, the viaducts pass 500+ units above the tallest coping, and nothing
    the city adds touches the floor anywhere else.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.City = BMX.City or {}
BMX.City.Maps = BMX.City.Maps or {}

local ALL_OLD = { "brick", "white", "grey", "ped", "yellow", "ochre", "tan", "red", "stone", "dark", "cream" }

BMX.City.Maps.gm_skatepark = {
    seed = 20261007,

    -- x0, y0, z0, x1, y1, z1: the inside of the box. Faces are only built if
    -- some point in here can see them.
    park = { -256, -1792, 64, 3584, 768, 1720 },
    ground = 64,
    sunPitch = 28, sunYaw = 180,

    -- The buildings standing on the wall. Their facades stand `inset` inside
    -- it, so they cover the brick from the floor up; their bodies go out into
    -- the void. 5 to 13 floors: z 704 to 1728, the low ones well clear of the
    -- sky ceiling, the tall ones rising past it.
    frontage = {
        inset = 4,
        minWidth = 384, maxWidth = 768,
        minDepth = 512, maxDepth = 896,
        minFloors = 5, maxFloors = 13,
        jitter = 0,
        styles = ALL_OLD,
        towerChance = 0.35, towerMin = 3, towerMax = 9,
    },

    -- Taller blocks behind, seen over the frontage's roofs.
    backRow = {
        offset = 1280, inset = 0, street = false,
        minWidth = 512, maxWidth = 1024,
        minDepth = 512, maxDepth = 1024,
        minFloors = 12, maxFloors = 24,
        jitter = 512,
        styles = { "office", "glass", "cream", "dark", "stone", "grey", "white" },
        towerChance = 0.4, towerMin = 4, towerMax = 12,
    },

    -- Free-standing towers further out, all the way round: the skyline.
    skyline = {
        count = 44,
        minDist = 3200, maxDist = 9000,  -- from the park's edge
        clear = 3000,                    -- never inside the inner rows
        minWidth = 512, maxWidth = 1280,
        minFloors = 20, maxFloors = 58,
        styles = { "glass", "office", "glass", "dark", "cream", "stone" },
        crownChance = 0.5,
    },

    -- The subway. Two lines cross the park north-south on the low level; one
    -- crosses east-west above them, over both. The low decks at z 1000 sit
    -- 517 above the halfpipe's coping (z 483), the tallest thing in the park.
    -- Truss tops 1224; the high line's girders bottom out at 1296; its truss
    -- top at 1624 stays under the sky ceiling at 1720.
    viaducts = {
        { name = "line1", axis = "y", at = 1400, from = -1792, to = 768, deck = 1000,
          period = 41, offset = 0, cars = 3 },
        { name = "line2", axis = "y", at = 2600, from = -1792, to = 768, deck = 1000,
          period = 53, offset = 17, cars = 4 },
        { name = "line3", axis = "x", at = -480, from = -256, to = 3584, deck = 1400,
          period = 67, offset = 33, cars = 4, speed = 1300 },
    },

    -- Piers under the crossings, in clear lanes (tests/test_city.lua proves
    -- the clearance against every ramp). Each carries the low line on its cap
    -- and a steel post up to the high line.
    --   (1400, -480): between the halfpipe (x <= 1195) and the spine (x >= 1495)
    --   (2600, -480): between the funbox (x <= 2367) and the spine (y <= -613)
    piers = {
        { name = "pier1", x = 1400, y = -480, size = 96, top = 1000 - 40 - 64,
          postFrom = 1000 + 224 + 16, postTo = 1400 - 40 - 64 },
        { name = "pier2", x = 2600, y = -480, size = 96, top = 1000 - 40 - 64,
          postFrom = 1000 + 224 + 16, postTo = 1400 - 40 - 64 },
    },

    -- Lit text panels, drawn by cl_city.lua. pos is the panel's centre on the
    -- face, normal points at the park.
    signs = {
        { text = "BMX", sub = "PARK  &  PLAZA", pos = { 1664, 760, 600 }, normal = { 0, -1, 0 },
          w = 512, h = 192, color = { 255, 200, 40 } },
        { text = "LINE 1", sub = "UPTOWN", pos = { 1400, 758, 1320 }, normal = { 0, -1, 0 },
          w = 192, h = 48, color = { 230, 70, 60 } },
        { text = "LINE 1", sub = "DOWNTOWN", pos = { 1400, -1782, 1320 }, normal = { 0, 1, 0 },
          w = 192, h = 48, color = { 230, 70, 60 } },
        { text = "LINE 2", sub = "UPTOWN", pos = { 2600, 758, 1320 }, normal = { 0, -1, 0 },
          w = 192, h = 48, color = { 60, 150, 230 } },
        { text = "LINE 2", sub = "DOWNTOWN", pos = { 2600, -1782, 1320 }, normal = { 0, 1, 0 },
          w = 192, h = 48, color = { 60, 150, 230 } },
        { text = "LINE 3", sub = "CROSSTOWN", pos = { -246, -160, 1480 }, normal = { 1, 0, 0 },
          w = 192, h = 48, color = { 80, 200, 90 } },
        { text = "LINE 3", sub = "CROSSTOWN", pos = { 3574, -800, 1480 }, normal = { -1, 0, 0 },
          w = 192, h = 48, color = { 80, 200, 90 } },
        { text = "SKATE", sub = "OPEN LATE", pos = { -248, 200, 400 }, normal = { 1, 0, 0 },
          w = 384, h = 128, color = { 90, 220, 255 } },
        { text = "RIDE", sub = "NO WALKING ON RAMPS", pos = { 3576, -1300, 620 }, normal = { -1, 0, 0 },
          w = 384, h = 128, color = { 255, 90, 160 } },
    },
}
