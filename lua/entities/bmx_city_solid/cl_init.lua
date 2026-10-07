include("shared.lua")

-- The name arrives with the first snapshot, which may be after Initialize:
-- build the client's collision as soon as it is known.
function ENT:Initialize() self:BuildPhysics() end
function ENT:Think()
    if not self._built then self:BuildPhysics() end
end

function ENT:Draw() end
