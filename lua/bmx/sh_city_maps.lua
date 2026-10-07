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

    Every ramp in the map was measured too (each one's WorldSpaceAABB on the
    running server, in tests/test_city.lua; NOT the models' vertices, which
    studiomdl stores turned 90 degrees from entity space -- the first layout
    was checked against those and put a pier on the halfpipe): the piers stand in the lanes between
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
        { name = "line1", axis = "y", at = 1685, from = -1792, to = 768, deck = 1000,
          period = 41, offset = 0, cars = 3 },
        { name = "line2", axis = "y", at = 2665, from = -1792, to = 768, deck = 1000,
          period = 53, offset = 17, cars = 4 },
        { name = "line3", axis = "x", at = -300, from = -256, to = 3584, deck = 1400,
          period = 67, offset = 33, cars = 4, speed = 1300 },
    },

    -- Piers under the crossings, in clear lanes (tests/test_city.lua proves
    -- the clearance against every ramp). Each carries the low line on its cap
    -- and a steel post up to the high line.
    --   (1685, -300): the lane between the halfpipe (x <= 1515) and the funbox
    --                 (x >= 1855), north of the spine (y <= -1327)
    --   (2665, -300): between the funbox (x <= 2401) and the rail (x >= 2914),
    --                 north of the spines (y <= -505)
    piers = {
        { name = "pier1", x = 1685, y = -300, size = 96, top = 1000 - 40 - 64,
          postFrom = 1000 + 224 + 16, postTo = 1400 - 40 - 64 },
        { name = "pier2", x = 2665, y = -300, size = 96, top = 1000 - 40 - 64,
          postFrom = 1000 + 224 + 16, postTo = 1400 - 40 - 64 },
    },

    -- The signs, in Petopia's look (the server's site, naliwajka.com/petopia:
    -- a 1998 desktop, navy and silver, Peter's sayings). Family friendly.
    -- pos is the panel's centre on the face; normal points at the park.
    signs = {
        { look = "window", title = "BMX.EXE", text = "BMX PARK", sub = "Hold on to your butts.",
          pos = { 1000, 760, 660 }, normal = { 0, -1, 0 }, w = 560, h = 280, color = { 0, 255, 255 } },
        { look = "window", title = "Petopia Metro", text = "LINE 1", sub = "SPOONER ST",
          pos = { 1685, 758, 1350 }, normal = { 0, -1, 0 }, w = 256, h = 112, color = { 255, 80, 80 } },
        { look = "window", title = "Petopia Metro", text = "LINE 1", sub = "SPOONER ST",
          pos = { 1685, -1782, 1350 }, normal = { 0, 1, 0 }, w = 256, h = 112, color = { 255, 80, 80 } },
        { look = "window", title = "Petopia Metro", text = "LINE 2", sub = "TOY FACTORY",
          pos = { 2665, 758, 1350 }, normal = { 0, -1, 0 }, w = 256, h = 112, color = { 0, 255, 255 } },
        { look = "window", title = "Petopia Metro", text = "LINE 2", sub = "TOY FACTORY",
          pos = { 2665, -1782, 1350 }, normal = { 0, 1, 0 }, w = 256, h = 112, color = { 0, 255, 255 } },
        { look = "window", title = "Petopia Metro", text = "LINE 3", sub = "CROSSTOWN",
          pos = { -246, 20, 1480 }, normal = { 1, 0, 0 }, w = 256, h = 112, color = { 0, 255, 0 } },
        { look = "window", title = "Petopia Metro", text = "LINE 3", sub = "CROSSTOWN",
          pos = { 3574, -620, 1480 }, normal = { -1, 0, 0 }, w = 256, h = 112, color = { 0, 255, 0 } },
        { look = "neon", text = "ROADHOUSE", sub = "OPEN LATE",
          pos = { -248, 200, 420 }, normal = { 1, 0, 0 }, w = 448, h = 140, color = { 255, 0, 255 } },
        { look = "window", title = "Notepad - RULEZ.TXT", text = "RIDE", sub = "No walking on the ramps.",
          pos = { 3576, -1300, 640 }, normal = { -1, 0, 0 }, w = 480, h = 240, color = { 255, 255, 0 } },
        { look = "neon", text = "FREAKIN' SWEET", sub = "PETOPIA BMX CITY",
          pos = { 2200, -1784, 620 }, normal = { 0, 1, 0 }, w = 640, h = 160, color = { 255, 255, 0 } },
        { look = "neon", text = "HEHEHEHE", sub = "PETER'S TIP: PEDAL",
          pos = { 400, -1784, 640 }, normal = { 0, 1, 0 }, w = 512, h = 140, color = { 0, 255, 255 } },
    },

    -- Rooftop billboards, standing on whatever frontage building is there.
    billboards = {
        { look = "billboard", side = "north", at = 1150, w = 1280, h = 380, back = 64,
          text = "PETOPIA", sub = "PETER GRIFFIN'S BMX CITY", color = { 255, 255, 0 } },
        { look = "billboard", side = "east", at = 200, w = 960, h = 300, back = 64,
          text = "HEHEHEHE", sub = "TRICKS  *  GRINDS  *  COMBOS", color = { 255, 0, 255 } },
    },
}
