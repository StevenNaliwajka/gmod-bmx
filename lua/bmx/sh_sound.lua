--[[--------------------------------------------------------------------------
    bmx/sh_sound.lua

    Every sound this addon plays, in one table, on both realms.

    WHY NOTHING IS SHIPPED IN THE ADDON. Two reasons, and the second is the one
    that matters. The addon has zero content dependencies on purpose (see
    docs/DESIGN.md section 8): clone it, ride it, no mounts, no downloads, no
    missing-content errors for half a server. And audio lifted out of another
    game is the fastest way to have a public Workshop item and its repository
    taken down. Base-game sounds have neither problem -- they are already on
    every client, they cost nothing to license, and they add not one byte to
    the .gma.

    THEY ARE PLACEHOLDERS, chosen by reading filenames on a headless server.
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
    -- Tyres rolling on the ground. A real BMX is very quiet, so this sits low
    -- and is mostly felt rather than heard. Standing in for: tyre roar.
    roll = {
        path   = "physics/metal/metal_grenade_roll_loop1.wav",
        vol    = 0.32,
        pitch  = { 45, 105 },      -- mapped across 0 -> topSpeed
        level  = 68,
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
    -- loop, because that IS what a pawl ratchet is.
    tick = {
        path   = "physics/metal/metal_chainlink_impact_soft1.wav",
        vol    = 0.22,
        pitch  = { 115, 145 },
        level  = 62,
    },

    -- Frame or pegs sliding on a rail (cl_grind.lua). Standing in for: a grind.
    grind = {
        path   = "physics/metal/metal_box_scrape_rough_loop1.wav",
        vol    = 0.55,
        pitch  = { 85, 125 },
        level  = 75,
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

    -- The rider's own effort as they unweight. Standing in for: the pop of a
    -- bunny hop, which is mostly body and tyre rather than bike.
    hop = { path = "physics/body/body_medium_impact_soft%d.wav",
            variants = 4, vol = 0.4, level = 65 },

    -- The puff of smoke when a bike changes colour (sh_color.lua).
    recolor = { path = "garrysmod/balloon_pop_cute.wav", vol = 0.45, level = 68 },

    -- Frame hitting the world. Standing in for: a crash.
    crash = { path = "physics/metal/metal_box_impact_hard%d.wav",
              variants = 3, vol = 1.0, level = 80 },
}

-- Pick one numbered variant of a family, or the plain path if it has none.
function BMX.SoundFile(key)
    local s = BMX.Sounds[key]
    if not s then return nil end
    if not s.variants then return s.path end
    return string.format(s.path, math.random(1, s.variants))
end

