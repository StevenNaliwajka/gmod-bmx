--[[--------------------------------------------------------------------------
    bmx/sh_bikes.lua

    The bike registry. Adding a bike is one table in here plus its model files.

    SCOPE, stated plainly: entries currently describe a bike's APPEARANCE and
    its mount points. They do NOT yet carry per-bike physics, because the
    simulation reads BMX.Config as a global and making it per-bike means
    threading a config table through every function in sv_wheel / sv_balance /
    sv_air / sv_physics. That refactor is Phase 5 in docs/DESIGN.md and is
    written down there rather than half-implemented here: a `physics = {}` field
    that silently does nothing is worse than no field at all.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Bikes = BMX.Bikes or {}

local pending = {}

--------------------------------------------------------------------------
-- Register a bike.
--
--   id            unique, lowercase. Becomes entity class "bmx_<id>".
--   def.printName spawnmenu label
--   def.model     frame model. See the placeholder note below.
--   def.seatModel model the invisible pod uses; only its seat attachment and
--                 sit animation matter, since it is never drawn.
--   def.wheelModel optional. Absent, the client draws procedural wheels, which
--                 is both an honest placeholder and a useful debug view: you
--                 can SEE where the raycast wheel thinks it is.
--   def.forkModel optional, drawn steered with the front wheel.
--   def.frameOffset / def.frameAngles  model alignment against the axle line
--   def.scale     model scale, for stand-in props that are not bike-sized
--------------------------------------------------------------------------
function BMX.RegisterBike(id, def)
    id = string.lower(id)

    def.id        = id
    def.printName = def.printName or id
    def.model     = def.model or "models/hunter/plates/plate1x2.mdl"
    def.seatModel = def.seatModel or "models/nova/airboat_seat.mdl"
    def.frameOffset = def.frameOffset or Vector(0, 0, 0)
    def.frameAngles = def.frameAngles or Angle(0, 0, 0)
    def.scale     = def.scale or 1

    BMX.Bikes[id] = def

    -- "stock" IS bmx_base rather than a derivative, so the base class stays
    -- spawnable on its own and a broken registry still leaves something to ride.
    if id ~= "stock" then
        pending[#pending + 1] = id
    end

    list.Set("SpawnableEntities", BMX.ClassFor(id), {
        PrintName = def.printName,
        ClassName = BMX.ClassFor(id),
        Category  = "BMX",
        Author    = def.author or "naliwajka",
        Information = def.description or "",
    })
end

function BMX.ClassFor(id)
    id = string.lower(id or "")
    if not BMX.Bikes[id] then return nil end
    return id == "stock" and "bmx_base" or ("bmx_" .. id)
end

function BMX.BikeIDs()
    local out = {}
    for id in pairs(BMX.Bikes) do out[#out + 1] = id end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------
-- Derive the extra entity classes.
--
-- Deferred to the next tick because lua/entities is loaded by the engine and
-- lua/autorun by the gamemode, and the order between them is not something to
-- rely on: scripted_ents.Get("bmx_base") has to already exist. One timer at
-- load is cheaper than a fragile ordering assumption.
--------------------------------------------------------------------------
local function derive()
    local base = scripted_ents.GetStored("bmx_base")
    if not base then
        ErrorNoHalt("[BMX] bmx_base is not registered -- extra bikes skipped\n")
        return
    end

    for _, id in ipairs(pending) do
        -- A MINIMAL table, not a copy of the base. Setting Base is what makes
        -- inheritance happen; copying the base's methods on top of that gives
        -- every derived bike its own frozen snapshot of them, so a later fix to
        -- bmx_base silently does not reach the derived classes.
        scripted_ents.Register({
            Type      = "anim",
            Base      = "bmx_base",
            BikeID    = id,
            PrintName = BMX.Bikes[id].printName,
            Category  = "BMX",
            Spawnable = true,
        }, "bmx_" .. id)
    end

    pending = {}
end

timer.Simple(0, derive)

--------------------------------------------------------------------------
-- THE BIKES
--------------------------------------------------------------------------

-- The stock bike. Its model is a PLACEHOLDER: a Hunter plate, chosen because it
-- ships with base Garry's Mod, so this addon has zero content dependencies and
-- can be cloned and ridden immediately. The client draws procedural wheels
-- around it so the geometry the simulation is actually using is visible.
--
-- Swapping in a real model is a one-line change here plus frameOffset /
-- frameAngles to line it up with the axle line. See docs/DESIGN.md, "Content".
BMX.RegisterBike("stock", {
    printName   = "BMX (placeholder model)",
    description = "Street BMX. Placeholder geometry until a real model lands.",
    model       = "models/hunter/plates/plate1x2.mdl",
    frameOffset = Vector(0, 0, 6),
    frameAngles = Angle(0, 90, 0),
    scale       = 0.55,
})
