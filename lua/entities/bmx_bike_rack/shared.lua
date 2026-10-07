--[[--------------------------------------------------------------------------
    entities/bmx_bike_rack/shared.lua

    THE BIKE RACK (G13): a prop that welds to a car and carries up to two bikes.
    The rules (what a carrier is, the slots, loading and releasing) are
    lua/bmx/sv_rack.lua; this is the entity that carries them, a plate with a model
    nobody sees: the rack is drawn in code (cl_init.lua), as the bikes are.

    Spawned from the spawn menu under BMX > Bikes, next to the car it should go on
    (it finds the nearest one and welds to it), or put where you like and used (E)
    beside a car. E with a bike beside it loads the bike; E with none releases the last
    one loaded. E on a racked bike lets it down.
----------------------------------------------------------------------------]]

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Bike Rack"
ENT.Author = "naliwajka"
ENT.Category = "BMX"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.IsBMXRack = true

-- A flat plate: the physics body the rack is welded by. Never drawn.
ENT.RackModel = "models/hunter/plates/plate1x1.mdl"

function ENT:SetupDataTables()
    -- How many bikes are on it (0..2), and whether it is welded to a car: for the drawing.
    self:NetworkVar("Int",  0, "Loaded")
    self:NetworkVar("Bool", 0, "Carried")
end

-- The same row the bikes have in the spawn menu, under BMX > Bikes.
list.Set("SpawnableEntities", "bmx_bike_rack", {
    PrintName   = "Bike Rack",
    ClassName   = "bmx_bike_rack",
    Category    = "BMX",
    Subcategory = "Bikes",
    Author      = "naliwajka",
    Information = "Welds to a car and carries up to two bikes. E with a bike beside it loads it; E on a racked bike lets it down.",
})
