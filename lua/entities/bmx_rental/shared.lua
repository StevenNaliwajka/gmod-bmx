--[[--------------------------------------------------------------------------
    entities/bmx_rental/shared.lua

    THE BIKE RENTAL MACHINE: a vending machine that hands out any vehicle for
    free (BMX.Rental, sh_rental.lua). E on it opens its window; a click puts the
    player on what they picked, in front of the machine.

    Not in the spawn menu: a map places them where people spawn
    (petopia_bmx_fall does), and an admin can add one with `ent_create bmx_rental`.
----------------------------------------------------------------------------]]

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Bike Rental"
ENT.Author = "Burrito"
ENT.Category = "BMX"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.IsBMXRental = true
