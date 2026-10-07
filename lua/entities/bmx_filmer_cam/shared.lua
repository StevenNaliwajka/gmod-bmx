--[[--------------------------------------------------------------------------
    entities/bmx_filmer_cam/shared.lua

    A FIXED "FILMER" CAMERA (G21) for a server to put at a park's best ramp.
    It is a prop on a tripod that turns to follow the nearest rider, the way a
    friend with a camcorder at the bottom of the bank does. `bmx_filmer_view`
    looks through the nearest one (cl_filmer.lua), and the replay's "fixed"
    camera (G28) uses it too, so a park with a camera on its best line gets
    that angle on every clip.

    It is only a SCREEN for the view: it has no state to network, no think on
    the server and no physics once placed. The turning and the zoom are
    worked out on each client from where the nearest rider is, so it costs the
    server nothing.

    Admin-only to spawn (Q menu > BMX > BMX Filmer Camera), for the same reason
    the leaderboard sign is: it stands in the map for everyone.
----------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "BMX Filmer Camera"
ENT.Author    = "Burrito"
ENT.Category  = "BMX"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.IsBMXFilmer = true

ENT.Model = "models/dav0r/camera.mdl"

-- A rider farther than this is not followed; the camera holds its last aim.
ENT.FollowRange = 3500
