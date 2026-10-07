include("shared.lua")

--[[--------------------------------------------------------------------------
    entities/bmx_filmer_cam/cl_init.lua

    Drawing: the camera model, turned to face the nearest rider so a rider can
    see they are being filmed. The aim is the same one the view uses
    (BMX.FilmerTrack in cl_filmer.lua), so the model and the picture agree.
----------------------------------------------------------------------------]]

function ENT:Draw()
    local subject = BMX.FilmerNearestRider and BMX.FilmerNearestRider(self:GetPos(), self.FollowRange)
    if subject then
        self.bmxTrack = self.bmxTrack or {}
        local want = BMX.FilmerAim(self:GetPos(), subject:GetPos() + Vector(0, 0, 30))
        self:SetRenderAngles(BMX.FilmerTrack(self.bmxTrack, want, FrameTime()))
    end
    self:DrawModel()
end
