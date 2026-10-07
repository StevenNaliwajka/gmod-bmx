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
        -- Slow enough to watch: 600 units/s (about 30 mph) puts a train over
        -- the park for 7-8 seconds, and one comes along on some line every
        -- 10 seconds or so. Each run is shorter than its period, so a line
        -- never has two trains on it.
        { name = "line1", axis = "y", at = 1685, from = -1792, to = 768, deck = 1000,
          period = 24, offset = 0, cars = 3, speed = 600, runout = 800 },
        { name = "line2", axis = "y", at = 2665, from = -1792, to = 768, deck = 1000,
          period = 29, offset = 9, cars = 4, speed = 600, runout = 800 },
        { name = "line3", axis = "x", at = -300, from = -256, to = 3584, deck = 1400,
          period = 35, offset = 17, cars = 4, speed = 700, runout = 800 },
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

    -- The signs: billboard advertisements for Quahog, Rhode Island, the
    -- Family Guy town (Petopia is Peter's nation, founded in his back yard),
    -- station signs for the metro and green street signs. Family friendly:
    -- the town's businesses and Peter's catchphrases, nothing edgier.
    -- pos is the panel's centre on the face; normal points at the park.
    signs = {
        -- north wall
        { look = "ad", text = "THE DRUNKEN CLAM", sub = "Our chowder is now 40% clam!", burst = "NOW WITH\nSPOONS!", fine = "*The other 60% is a mystery. Ask Horace.", bg = { 255, 214, 60 }, bg2 = { 255, 120, 30 }, fg = { 220, 30, 40 }, band = { 20, 60, 120 }, burstColor = { 230, 30, 30 },
          pos = { 1000, 758, 640 }, normal = { 0, -1, 0 }, w = 640, h = 240 },
        { look = "street", text = "SPOONER ST", sub = "31",
          pos = { 2200, 762, 300 }, normal = { 0, -1, 0 }, w = 320, h = 72 },
        -- the metro: a station sign over each portal
        { look = "transit", line = "1", text = "SPOONER ST", sub = "Quahog Metro", color = { 220, 40, 40 },
          pos = { 1685, 758, 1350 }, normal = { 0, -1, 0 }, w = 480, h = 120 },
        { look = "transit", line = "1", text = "SPOONER ST", sub = "Quahog Metro", color = { 220, 40, 40 },
          pos = { 1685, -1782, 1350 }, normal = { 0, 1, 0 }, w = 480, h = 120 },
        { look = "transit", line = "2", text = "TOY FACTORY", sub = "Quahog Metro", color = { 30, 120, 220 },
          pos = { 2665, 758, 1350 }, normal = { 0, -1, 0 }, w = 480, h = 120 },
        { look = "transit", line = "2", text = "TOY FACTORY", sub = "Quahog Metro", color = { 30, 120, 220 },
          pos = { 2665, -1782, 1350 }, normal = { 0, 1, 0 }, w = 480, h = 120 },
        { look = "transit", line = "3", text = "DOWNTOWN", sub = "Quahog Metro", color = { 30, 160, 70 },
          pos = { -246, 20, 1480 }, normal = { 1, 0, 0 }, w = 480, h = 120 },
        { look = "transit", line = "3", text = "DOWNTOWN", sub = "Quahog Metro", color = { 30, 160, 70 },
          pos = { 3574, -620, 1480 }, normal = { -1, 0, 0 }, w = 480, h = 120 },
        -- west wall
        { look = "ad", text = "GOLDMAN'S PHARMACY", sub = "Feeling sick? Have you tried feeling better?", burst = "ASK\nMORT!", fine = "*Mort is not a doctor. Mort is barely a pharmacist.", bg = { 120, 255, 170 }, bg2 = { 20, 170, 110 }, fg = { 255, 255, 255 }, band = { 10, 80, 50 }, burstColor = { 240, 40, 160 },
          pos = { -248, 200, 440 }, normal = { 1, 0, 0 }, w = 560, h = 210 },
        { look = "street", text = "SPOONER ST", sub = "",
          pos = { -250, -1000, 300 }, normal = { 1, 0, 0 }, w = 320, h = 72 },
        -- east wall
        { look = "ad", text = "QUAHOG 5 NEWS", sub = "Local man rides bike. Film at 11.", burst = "LIVE\nAT 6!", fine = "Tom Tucker: usually right, always confident.", bg = { 60, 110, 255 }, bg2 = { 10, 20, 90 }, fg = { 255, 220, 40 }, band = { 200, 20, 30 }, burstColor = { 230, 20, 30 },
          pos = { 3576, -1300, 640 }, normal = { -1, 0, 0 }, w = 600, h = 225 },
        -- south wall
        { look = "ad", text = "HAPPY-GO-LUCKY TOYS", sub = "So safe, we tested them on Peter!", burst = "SAFE-\nISH!", fine = "*Batteries, instructions and happiness sold separately.", bg = { 255, 150, 220 }, bg2 = { 170, 60, 255 }, fg = { 255, 255, 80 }, band = { 60, 20, 120 }, burstColor = { 255, 120, 0 },
          pos = { 2200, -1784, 620 }, normal = { 0, 1, 0 }, w = 680, h = 255 },
        { look = "ad", text = "SPOONER ST BMX", sub = "Brakes sold separately. Hehehehehe.", burst = "SALE!\nSALE!", fine = "Helmets strongly recommended. Ask Peter why.", bg = { 120, 230, 255 }, bg2 = { 0, 140, 220 }, fg = { 255, 90, 0 }, band = { 20, 30, 60 }, burstColor = { 255, 200, 0 },
          pos = { 400, -1784, 640 }, normal = { 0, 1, 0 }, w = 600, h = 225 },
    },

    -- Rooftop billboards, standing on whatever frontage building is there.
    billboards = {
        { look = "ad", side = "north", at = 1150, w = 1280, h = 480, back = 64,
          text = "VISIT PETORIA", sub = "The world's smallest nation! (It's a back yard.)", burst = "NO\nPASSPORT!", fine = "Customs: please wipe your feet and do not pet the dog.", bg = { 130, 220, 255 }, bg2 = { 30, 120, 230 }, fg = { 255, 255, 255 }, band = { 0, 50, 120 }, burstColor = { 255, 60, 60 } },
        { look = "ad", side = "east", at = 200, w = 1024, h = 384, back = 64,
          text = "WELCOME TO QUAHOG", sub = "Rhode Island's #1 town for giant chicken fights", burst = "EST.\n1635", fine = "Pop. 75,000 and one very large chicken.", bg = { 255, 240, 200 }, bg2 = { 255, 170, 90 }, fg = { 30, 80, 170 }, band = { 160, 30, 30 }, burstColor = { 30, 140, 60 } },
        { look = "ad", side = "south", at = 2900, w = 960, h = 360, back = 64,
          text = "JAMES WOODS HIGH", sub = "Home of the Fighting Clams. Go... Clams?", burst = "GO\nTEAM!", fine = "Mascot still missing. Last seen near the Drunken Clam.", bg = { 255, 90, 90 }, bg2 = { 150, 10, 40 }, fg = { 255, 255, 255 }, band = { 60, 0, 20 }, burstColor = { 255, 210, 0 } },
    },

    -- Greenery (sh_city.lua, B:greenery). The beds stand on the park floor
    -- against the wall, each in a lane measured clear of every ramp by 40+
    -- units (tests/test_city.lua checks it against the live footprints):
    --   north  x 1480..3584: east of the quarterpipes (x <= 1431)
    --   south  four gaps between the spine, flat ramps, funbox and the
    --          quarterpipe in the corner
    --   west   y -1160..440: between the spine (y <= -1208) and the flat
    --          ramp (y >= 481)
    --   east   y -1020..672: north of the quarterpipe (y <= -1067)
    greenery = {
        kerb = 20,
        treeEvery = { 224, 352 },
        beds = {
            { side = "north", from = 1480, to = 3584, depth = 88 },
            { side = "south", from = 200, to = 515, depth = 88 },
            { side = "south", from = 960, to = 1340, depth = 88 },
            { side = "south", from = 2010, to = 2350, depth = 88 },
            { side = "south", from = 2990, to = 3250, depth = 88 },
            { side = "west", from = -1160, to = 440, depth = 88 },
            { side = "east", from = -1020, to = 672, depth = 88 },
        },
        roofs = 0.8,
        terraces = true,
        balconies = 0.45,
        ivy = 0.55,
        -- a street lamp every ~560 along each bed, arm over the park
        lampEvery = 560,
    },

    -- The park's floor, laid over the map's bare concrete: slabs to ride on,
    -- brick paving along the walls, cobbles round the piers, a kerb line,
    -- leaves. Lit per vertex: ambient afternoon light and the lamps' pools.
    floor = {
        cell = 64, walk = 176, lift = 0.6, plaza = 288,
        litter = 170,
        ambient = { 0.74, 0.65, 0.56 },
        lampRadius = 440, lampColor = { 0.6, 0.4, 0.18 },
    },

    -- A late autumn afternoon (cl_city_mood.lua): the sun low in the west
    -- behind heavy cloud. `light` warms every surface of the city; the sky is
    -- HL2's golden-hour sky, dimmed; the haze is thin and far.
    mood = {
        light = { 1.0, 0.86, 0.72 },
        sky = "skybox/sky_day01_08", skyTint = { 0.8, 0.72, 0.66 }, skyYaw = 0,
        fog = { start = 3000, finish = 15000, density = 0.5, color = { 120, 92, 74 } },
        grade = { brightness = -0.04, contrast = 1.06, colour = 0.88, mulr = 0.1, mulg = 0.03, addr = 0.015, addg = 0.004 },
        lampColor = { 255, 186, 112 }, lampBrightness = 1.3, lampSize = 560,
        leafEvery = 0.22,
    },
}

-- The same park, renamed for its autumn edition: the server runs a copy of
-- gm_skatepark's BSP as petopia_bmx_fall (docs/CITY.md, "The map").
BMX.City.Maps.petopia_bmx_fall = BMX.City.Maps.gm_skatepark
