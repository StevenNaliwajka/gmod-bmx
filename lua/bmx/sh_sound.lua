--[[--------------------------------------------------------------------------
    bmx/sh_sound.lua

    Every sound this addon plays, in one table, on both realms.

    WHY ALMOST NOTHING IS SHIPPED IN THE ADDON. Two reasons, and the second is the one
    that matters. The addon has zero content dependencies on purpose (see
    docs/DESIGN.md section 8): clone it, ride it, no mounts, no downloads, no
    missing-content errors for half a server. And audio lifted out of another
    game is the fastest way to have a public Workshop item and its repository
    taken down. Base-game sounds have neither problem -- they are already on
    every client, they cost nothing to license, and they add not one byte to
    the .gma.

    The exceptions are sounds the addon MAKES (sound/bmx/: the bell, the horn, the
    freewheel's tick, the engines, the motor and the rolling wheels, all
    synthesised by tools/sound/make_sounds.py), which are original, so neither
    reason applies; the server sends them to clients without the Workshop copy
    (sv_icons.lua).

    THE REST ARE PLACEHOLDERS, chosen by reading filenames on a headless server.
    Nobody has heard them. Every entry says what it is standing in for, so
    replacing one with something recorded or CC0 is a one-line edit against a
    stated intent rather than a guess at what the last person meant.

    ONE TABLE, ON BOTH REALMS, because the loops are client-side (they change
    pitch many times a second and everything they read is already networked)
    while the one-shots are server-side (they are events, at a moment only the
    server knows). Splitting the paths across the two files is how you end up
    shipping a reference to a file that does not exist -- which is silent for
    the player and noisy in their console. The `variants` field lets
    Tests/the suite walk every numbered file and prove it is really there.
----------------------------------------------------------------------------]]

BMX = BMX or {}

BMX.Sounds = {
    -- Tyres rolling on the ground: a low tread hum and road noise (the addon's
    -- own, sound/bmx/roll_tyre.wav). A real BMX is very quiet, so this sits low
    -- and is mostly felt rather than heard. It used to be a grenade rolling on
    -- metal, which is what a bike does not sound like.
    roll = {
        path   = "bmx/roll_tyre.wav",
        vol    = 0.32,
        pitch  = { 70, 130 },      -- mapped across 0 -> topSpeed
        level  = 68,
    },
    -- Hard urethane wheels on concrete (the skateboard, the scooter, the skates):
    -- brighter and grittier than a tyre, and louder, as anyone who has heard a
    -- skateboard go past knows. cl_sound.lua picks it by family.
    roll_wheel = {
        path   = "bmx/roll_wheel.wav",
        vol    = 0.42,
        pitch  = { 75, 135 },
        level  = 70,
    },

    -- Sliding tyre. rubber_tire_strain is the closest thing base GMod has to a
    -- tyre being asked for more than it has. Standing in for: a skid.
    skid = {
        path   = "physics/rubber/rubber_tire_strain1.wav",
        vol    = 0.55,
        pitch  = { 80, 130 },
        level  = 75,
    },

    -- THE FREEWHEEL, which is the sound a BMX actually makes. Coasting with the
    -- cranks still is a rising tick-tick-tick that everyone recognises, and it
    -- is the one piece of this that is not generic vehicle noise. Fired as
    -- discrete ticks at a rate proportional to wheel speed rather than as a
    -- loop, because that IS what a pawl ratchet is. The addon's own: one pawl
    -- over one tooth, three of them so a coast is not one file repeated. Only a
    -- vehicle with a freewheel ticks (BMX.HasFreewheel, below).
    tick = {
        path   = "bmx/tick%d.wav",
        variants = 3,
        vol    = 0.22,
        pitch  = { 92, 112 },
        level  = 62,
    },
    -- ...and the same pawls when they come too fast to hear apart (past ~24 a
    -- second, about a jogging pace): a loop of clicks made at 60 a second, pitched to
    -- the real rate. One EmitSound per click could not keep up there anyway.
    freewheel = {
        path    = "bmx/freewheel.wav",
        clickHz = 60,
        vol     = 0.2,
        pitch   = { 40, 250 },     -- the clamp: 24 to 150 clicks a second
        level   = 62,
    },

    -- THE CHAIN, while the cranks turn: rollers seating on the chainring's teeth.
    -- Made at 50 meshes a second (a 25-tooth ring at 120 rpm), pitched to the real
    -- crank speed, and quiet: mostly felt, a little louder when stamping.
    chain = {
        path    = "bmx/chain.wav",
        meshHz  = 50,
        teeth   = 25,
        vol     = 0.16,
        pitch   = { 30, 200 },
        level   = 60,
    },

    -- Frame or pegs sliding on a rail (cl_grind.lua). Standing in for: a grind.
    grind = {
        path   = "physics/metal/metal_box_scrape_rough_loop1.wav",
        vol    = 0.55,
        pitch  = { 85, 125 },
        level  = 75,
    },

    -- THE MOTORS (G14, G15; cl_motor.lua). Loops whose PITCH follows the networked rpm,
    -- and the addon's own (sound/bmx/, tools/sound/make_sounds.py): they were the
    -- airboat's fan and a V8's idle, and a moped is not a V8.
    --   motor      the electric whine: the e-bike's hub motor, the e-moto
    --   engine     the dirt bike: a four-stroke single
    --   engine2t   the moped: a 50 cc two-stroke (its registry entry's drive.sound)
    -- An ENGINE's file was made at `baseRpm`, so its pitch is simply rpm / baseRpm:
    -- the note is the firing rate, and the firing rate is the rpm. `pitch` is only
    -- the range the engine can reach (Source plays 0-255 %). The whine has no single
    -- rpm (a hub motor's electrical frequency depends on its poles), so it is mapped
    -- across the motor's range as before.
    motor = {
        path   = "bmx/motor.wav",
        vol    = 0.3,
        pitch  = { 70, 230 },      -- mapped across 0 -> the motor's top rpm
        level  = 62,
    },
    engine = {
        path    = "bmx/engine_4t.wav",
        baseRpm = 5040,
        vol     = 0.55,
        pitch   = { 20, 255 },     -- the clamp, not a mapping
        level   = 78,
    },
    engine2t = {
        path    = "bmx/engine_2t.wav",
        baseRpm = 4200,
        vol     = 0.45,
        pitch   = { 20, 255 },
        level   = 74,
    },

    -- THE WIND, which is what sells speed on a downhill or a big air. A loop,
    -- client-side, whose volume follows speed SQUARED (BMX.WindVolume): air
    -- resistance is quadratic, so a rider hears almost nothing at a walk and a
    -- great deal at the bottom of a halfpipe. Standing in for: rushing air.
    wind = {
        path   = "ambient/wind/wind_med1.wav",
        vol    = 0.5,
        pitch  = { 70, 125 },
        level  = 60,
    },

    ----------------------------------------------------------------------
    -- ONE-SHOTS. `variants` means the path carries a %d and the files are
    -- numbered 1..variants, which is how the suite proves every one of them is
    -- really on disk -- a missing sound is silent for the player and noisy in
    -- their console, and neither says which line referenced it.
    ----------------------------------------------------------------------

    -- Tyres arriving. Standing in for: a landing.
    land_soft = { path = "physics/rubber/rubber_tire_impact_soft%d.wav",
                  variants = 3, vol = 0.6, level = 68 },
    land_hard = { path = "physics/rubber/rubber_tire_impact_hard%d.wav",
                  variants = 3, vol = 1.0, level = 78 },

    -- A deck arriving instead of tyres (BMX.LandSoundKey): the skateboard's wood,
    -- the scooter's metal. Standing in for: a deck landing.
    land_wood  = { path = "physics/wood/wood_box_impact_hard%d.wav",
                   variants = 3, vol = 0.85, level = 74 },
    land_metal = { path = "physics/metal/metal_solid_impact_soft%d.wav",
                   variants = 3, vol = 0.8, level = 74 },

    -- THE BIKE'S MECHANISM, one-shots, all the addon's own (sound/bmx/): a gear
    -- change (the derailleur, or a motorbike's gearbox pitched down), the chain
    -- slapping the stay as a bike lands, the kickstand going down and coming up.
    shift      = { path = "bmx/shift%d.wav", variants = 2, vol = 0.45, level = 64 },
    chainslap  = { path = "bmx/chainslap%d.wav", variants = 3, vol = 0.5, level = 68 },
    stand_down = { path = "bmx/kickstand_down.wav", vol = 0.55, level = 64 },
    stand_up   = { path = "bmx/kickstand_up.wav", vol = 0.5, level = 64 },

    -- The rider's own effort as they unweight. Standing in for: the pop of a
    -- bunny hop, which is mostly body and tyre rather than bike.
    hop = { path = "physics/body/body_medium_impact_soft%d.wav",
            variants = 4, vol = 0.4, level = 65 },

    -- The puff of smoke when a bike changes colour (sh_color.lua).
    recolor = { path = "garrysmod/balloon_pop_cute.wav", vol = 0.45, level = 68 },

    -- The bike bell (R, on the ground). Played on every client from a net
    -- message (sh_bell.lua) so each listener's own bmx_vol_bell applies.
    -- A bike may name another key in its registry entry (`bell = "horn"`) or
    -- `bell = false` for none.
    --
    -- THESE TWO ARE THE ADDON'S OWN, not stand-ins: sound/bmx/, computed by
    -- tools/sound/make_sounds.py. The bell is the small bright "ting" lever bell
    -- the owner chose, its partials and decays measured off a recording of one
    -- (two thumb throws, each a strike and the hammer's bounce); the horn is an
    -- electric disc horn. Nothing sampled, so nothing to license: the files are
    -- original work under the addon's licence (sound/bmx/LICENSE.txt). The base
    -- game has no bicycle bell; buttons/bell1.wav pitched up was a door chime.
    -- Four bells and two horns, so a ring twice in a row is not the same file.
    bell = { path = "bmx/bell%d.wav", variants = 4, vol = 0.75, pitch = { 98, 102 }, level = 72 },
    -- A motorbike's (the e-moto, the dirt bike, the moped): a horn, not a bell.
    horn = { path = "bmx/horn%d.wav", variants = 2, vol = 0.8, pitch = { 98, 102 }, level = 80 },

    -- A wheel going into water at speed (sv_water.lua). Standing in for: a splash.
    splash = { path = "ambient/water/water_splash%d.wav",
               variants = 3, vol = 0.9, level = 76 },

    -- THE BOARD (G23). Standing in for: a tail snapping the ground (the pop of an
    -- ollie), a shoe scuffing along the ground (a kick of the push).
    board_pop  = { path = "physics/wood/wood_plank_impact_hard%d.wav",
                   variants = 3, vol = 0.7, level = 70 },
    board_push = { path = "physics/concrete/concrete_impact_soft%d.wav",
                   variants = 3, vol = 0.35, level = 62 },

    -- Frame hitting the world. Standing in for: a crash.
    crash = { path = "physics/metal/metal_box_impact_hard%d.wav",
              variants = 3, vol = 1.0, level = 80 },
}

-- Does this vehicle have a freewheel to tick? Only a pedal drive with a ratchet hub:
-- a BMX, a road or mountain bike, the e-bike (its motor drives through the same
-- hub). NOT a fixed gear or a unicycle (the cranks are the wheel), a penny-farthing
-- (pedals on the hub), a coaster-brake city bike (the hub's freewheel is a roller
-- clutch, near silent: a Dutch bike coasts without a sound), a motorbike, or
-- anything pushed or skated.
function BMX.HasFreewheel(def)
    local d = def and def.drive
    return d ~= nil and (d.kind == "pedal" or d.kind == "assist")
end

-- How many times a freewheel clicks per turn of the wheel against the cranks: its
-- engagement points. A BMX cassette hub has about 36; a downhill hub is a loud,
-- quick 54; a pedal-assist hub motor a coarse 24.
local POINTS = { dh = 54, ebike = 24 }
function BMX.FreewheelPoints(def)
    return def and POINTS[def.id] or 36
end

-- How fast the freewheel is clicking, clicks a second: the wheel overrunning the
-- cranks, times the engagement points. Pedalling at the wheel's pace it is locked
-- and silent; soft-pedalling slower than the wheel, it still clicks, slower, which
-- is what a real one does. `speed` u/s, `radius` the wheel's, `ratio` wheel turns
-- per crank turn, `cadence` the crank's rad/s.
function BMX.FreewheelRate(def, speed, radius, ratio, cadence)
    if not BMX.HasFreewheel(def) then return 0 end
    local wheel = (speed or 0) / math.max(radius or 1, 1)        -- rad/s
    local over = wheel - math.max(cadence or 0, 0) * (ratio or 1)
    if over <= wheel * 0.04 then return 0 end                    -- engaged: driving
    return over / (2 * math.pi) * BMX.FreewheelPoints(def)
end

-- Does the vehicle have a chain the cranks drive? Not a unicycle or a penny-farthing
-- (the cranks are on the hub), not a motorbike (the engine's chain is under its note),
-- not anything pushed or skated.
local CHAIN = { pedal = true, fixed = true, coaster = true, assist = true }
function BMX.HasChain(def)
    local d = def and def.drive
    if not d then return false end
    if d.kind == "engine" and d.pedalStart then return true end      -- the moped's pedal chain
    return CHAIN[d.kind] == true and not def.drawer
end

-- Does it have a kickstand to be heard going down? Every bike drawn as a bike
-- does; a board, a scooter, skates, a unicycle and a penny-farthing do not.
function BMX.HasKickstand(def)
    return def ~= nil and not def.drawer and def.family ~= "board" and def.family ~= "scooter"
        and def.family ~= "skates" and not def.worn
end

-- Which rolling sound a vehicle makes: urethane wheels or tyres.
local URETHANE = { board = true, scooter = true, skates = true }
function BMX.RollSoundKey(def)
    return def and URETHANE[def.family] and "roll_wheel" or "roll"
end

-- What a vehicle lands with: `key` (land_soft / land_hard, the tyres) unless it
-- lands on a deck.
local DECK = { board = "land_wood", scooter = "land_metal" }
function BMX.LandSoundKey(def, key)
    return def and DECK[def.family] or key
end

-- Pick one numbered variant of a family, or the plain path if it has none.
function BMX.SoundFile(key)
    local s = BMX.Sounds[key]
    if not s then return nil end
    if not s.variants then return s.path end
    return string.format(s.path, math.random(1, s.variants))
end


--------------------------------------------------------------------------
-- bmx_sounds 0 (server): the admin switch that silences every bike sound.
--
-- REPLICATED, because the loops are client-side: a client has to be able to
-- read the server's decision to stop making noise. Only the server may create
-- a replicated convar, hence the guard. Everything that plays a bike sound asks
-- BMX.SoundsOn() first; with no convar at all (a client that has not received
-- it yet) it is on, since silence is the surprising default.
--------------------------------------------------------------------------
if SERVER then
    CreateConVar("bmx_sounds", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
        "BMX: 1 = bikes make sounds; 0 = every bike sound is muted for everyone.")
end

function BMX.SoundsOn()
    local cv = GetConVar("bmx_sounds")
    return not cv or cv:GetBool()
end

-- How loud the wind is, 0..1, at `speed` against `top` (the speed the
-- drivetrain tops out at, which is the natural scale for "fast"). Quadratic,
-- like the air.
function BMX.WindVolume(speed, top)
    local f = (speed or 0) / math.max(top or 1, 1)
    if f <= 0 then return 0 end
    return math.min(f * f, 1)
end
