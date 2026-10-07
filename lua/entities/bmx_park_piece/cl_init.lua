include("shared.lua")

-- The shape arrives with the first snapshot, which may be after Initialize:
-- build the client's collision as soon as it is known.
function ENT:Initialize() self:BuildPhysics() end
function ENT:Think()
    if not self._built then self:BuildPhysics() end
end

-- cl_park.lua owns the meshes: one per distinct piece, shared by all of them.
function ENT:Draw()
    if BMX.Park and BMX.Park.Draw then BMX.Park.Draw(self) end
end
