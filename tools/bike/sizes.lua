-- Each model kind's size as its vehicle is registered (lua/bmx/sh_bikes.lua,
-- sh_motorbikes.lua, sh_scooter.lua, sh_boards.lua, sh_skates.lua), for the offline
-- preview only: the game hands the builders the registry's own numbers.
-- tests/test_bikemodel.lua checks these against the registry.
return {
    road     = { wheelbase = 48, radius = 13.8, seat = { -12.9, 0, 22.2 } },
    fixie    = { wheelbase = 44, radius = 13.8, seat = { -11.85, 0, 20.3 } },
    city     = { wheelbase = 52, radius = 14,   seat = { -14, 0, 24 },
                 extra = { sag = 3.9, basket = { mins = { 23, -10, 21 }, maxs = { 43, 10, 37 } } } },
    dh       = { wheelbase = 46, radius = 13.5, seat = { -12.4, 0, 21.2 }, restLength = 16 },
    ebike    = { wheelbase = 44, radius = 11.5, seat = { -11.85, 0, 20.3 } },
    tandem   = { wheelbase = 70, radius = 13,   seat = { 9, 0, 22 }, extra = { stoker = { -18, 0, 22 } } },
    emoto    = { wheelbase = 48, radius = 12.5, seat = { -12.9, 0, 22.2 }, restLength = 10.5 },
    dirtbike = { wheelbase = 58, radius = 14,   seat = { -14.9, 0, 25.5 }, restLength = 12 },
    moped    = { wheelbase = 48, radius = 11,   seat = { -12.9, 0, 20.3 } },
    unicycle = { wheelbase = 0,  radius = 10,   seat = { 0, 0, 19 } },
    penny    = { wheelbase = 44, radius = 26,   rearRadius = 6, seat = { 8, 0, 33 } },
    -- the three with drawers of their own (cl_board.lua, cl_scooter.lua, cl_skates.lua);
    -- `preview` adds the copies the preview needs to show a group drawn turned round
    skateboard = { wheelbase = 16, radius = 2.2, extra = { track = 4.6, preview = true } },
    scooter  = { wheelbase = 28, radius = 5,    seat = { -3, 0, 1.9 },
                 extra = { deckTop = 1.7, deckFront = 12.2, deckBack = -9, deckWidth = 5.0, barHeight = 35,
                           barWidth = 22, headFoot = 1.6, headLean = 4.0, pegY = 3.6, preview = true } },
    skates   = { wheelbase = 9,  radius = 1.6,  extra = { wheelPitch = 3.0, preview = true } },
}
