--[[--------------------------------------------------------------------------
    entities/bmx_base/shared.lua

    The bike entity. Every bike in the addon is this class or a derivative of
    it registered from sh_bikes.lua, so "add a bike" stays "add a table".

    It is a plain scripted entity with its own physics hull, NOT a
    prop_vehicle_jeep. Source's vehicle system is a four-wheel VPhysics
    controller with no notion of lean or balance, and it actively fights applied
    torque. The seat is a separate prop_vehicle_prisoner_pod parented to this
    entity, which is what gets us enter/exit, a driver reference and usercmds
    without inheriting the jeep controller.
----------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_entity"

ENT.PrintName = "BMX"
ENT.Author    = "naliwajka"
ENT.Category  = "BMX"
ENT.Spawnable = true
ENT.AdminOnly = false

-- Opaque only. RENDERGROUP_BOTH would run Draw twice per frame (once per pass)
-- and the procedural wheel lines would z-fight with themselves.
ENT.RenderGroup = RENDERGROUP_OPAQUE

-- Which entry in BMX.Bikes this class uses. Derived classes overwrite it.
ENT.BikeID = "stock"

-- How anything outside the addon recognises a bike, including the client, which
-- finds the one it is riding by walking up from the parented seat. Checking a
-- flag rather than a class name keeps derived bikes and third-party ones working.
ENT.IsBMX = true

--------------------------------------------------------------------------
-- THIS BIKE'S CONFIG, which is the seam the whole per-bike physics design
-- hangs on.
--
-- A bike registered with a `physics` table gets the base config with those
-- values merged over it; a bike without one gets BMX.Config itself, by
-- reference, so the common case costs a table lookup and no copying at all.
--
-- Resolved here rather than threaded from a global because EVERY function in
-- the simulation that needs the config already receives the entity. That makes
-- the config travel with the bike it belongs to, which is the property the
-- alternative -- pointing BMX.Config at the active bike for the duration of a
-- substep -- specifically does not have. See the note in sh_config.lua.
--
-- Shared, not server-only: the client draws wheels and a HUD off the same
-- numbers, and a wheel radius that differed between the realms would show up
-- as wheels that do not touch the ground.
--
-- Cached against BMX.ConfigRevision, so a convar moving the base reaches this
-- bike on the next call without rebuilding anything the other 19 times a
-- second the tuner is not touching it.
--------------------------------------------------------------------------
function ENT:Cfg()
    local rev = BMX.ConfigRevision
    if self._cfg and self._cfgRev == rev then return self._cfg end
    self._cfg, self._cfgRev = BMX.ConfigFor(self:Bike()), rev
    return self._cfg
end

function ENT:SetupDataTables()
    -- Identity / state the client needs to draw and to build a HUD.
    self:NetworkVar("Entity", 0, "Driver")
    self:NetworkVar("Entity", 1, "Pod")

    self:NetworkVar("Bool",  0, "Grounded")
    self:NetworkVar("Bool",  1, "Sprinting")

    -- Skidding is networked because the CLIENT cannot derive it. Whether a
    -- tyre is sliding is a property of the friction circle -- grip*N against
    -- the force the tyre is being asked for -- and the client has neither the
    -- load nor the slip. One bool beats sending two floats it would only use
    -- to recompute a bool.
    self:NetworkVar("Bool",  2, "Skidding")

    -- The kickstand: down only when a rider put it down (got off at a slow
    -- stop) or the bike was spawned parked. Networked so it is drawn only
    -- when it is really there. See C.Stand.deploySpeed.
    self:NetworkVar("Bool",  3, "StandDown")

    -- Steer is networked because the fork and bars have to point somewhere the
    -- client cannot derive: it is an OUTPUT of the balance controller, not a
    -- function of the rider's key. Radians.
    self:NetworkVar("Float", 0, "Steer")
    self:NetworkVar("Float", 1, "SpeedUPS")
    self:NetworkVar("Float", 2, "Stamina")
    self:NetworkVar("Float", 3, "HopCharge")
    self:NetworkVar("Float", 4, "Cadence")

    self:NetworkVar("Int",   0, "Score")
    -- The paint: an index into BMX.Palette (sh_color.lua).
    self:NetworkVar("Int",   1, "ColorIndex")
    -- The grind under way, for the sparks and the scrape (cl_sound.lua):
    -- 0 none, 1 crank grind, 2 pegs on the left, 3 pegs on the right.
    self:NetworkVar("Int",   2, "Grind")
    -- Frame spin, bar spin and the rider's pose, one byte each (sv_tricks.lua,
    -- BMX.PackTrickBits): where a tailwhip and a barspin are in their turn, as
    -- 0..255 of a revolution, and which style pose is held (a pose id from
    -- sh_tricks.lua, 0 = none). Drawn by cl_init.lua, posed by cl_rider.lua.
    -- Slot 7, not the next free one, to leave the low slots to whoever adds
    -- the next state the client needs.
    self:NetworkVar("Int",   7, "TrickBits")
    -- The gear a bike with `gears` is in, 1-based; 0 is "not set", which reads
    -- as the registration's start (sh_gears.lua). Networked because the client
    -- draws the cranks and the HUD from it as well as the server driving the
    -- wheel from it.
    self:NetworkVar("Int",   3, "Gear")

    if SERVER then
        self:SetColorIndex(self:Bike().colorIndex or 1)
        self:SetStandDown(true)             -- spawned parked
        self:SetSteer(0)
        self:SetSpeedUPS(0)
        self:SetStamina(self:Cfg().Drive.staminaMax)
    end
end

-- Wheel spin is NOT networked: see ENT:WheelSpin in cl_init.lua, which works
-- it out per wheel from what the client already has.

--------------------------------------------------------------------------
-- The bike definition this entity is running. Falls back to the stock table so
-- a class registered against a deleted bike id still spawns rather than
-- erroring inside Initialize, where the failure is much harder to read.
--------------------------------------------------------------------------
function ENT:Bike()
    return BMX.Bikes[self.BikeID] or BMX.Bikes.stock
end
