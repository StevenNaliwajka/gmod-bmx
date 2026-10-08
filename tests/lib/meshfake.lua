--[[--------------------------------------------------------------------------
    tests/lib/meshfake.lua

    A fake IMesh API for a client realm, so the built models (cl_bikemesh.lua)
    are built and "drawn" offline, and every group drawn is RECORDED with the
    matrix it was drawn under (cl.groups: { name, m, paint, lod }). The matrix
    answers Col(i), GetTranslation() and Apply(p), which is all a test needs to
    say where a pedal or a grip ended up in the world.

    The same fake tests/test_bikemodel.lua and tests/test_geo_odd.lua carry
    their own copies of; this one is for tests that want it without the checks
    on the triangles.
----------------------------------------------------------------------------]]

local M = {}

local function fakeMatrix(E, rows)
    local m = { rows = rows }
    function m:Col(i) return E.Vector(rows[1][i], rows[2][i], rows[3][i]) end
    function m:GetTranslation() return self:Col(4) end
    function m:Apply(p)
        return E.Vector(rows[1][1] * p.x + rows[1][2] * p.y + rows[1][3] * p.z + rows[1][4],
                        rows[2][1] * p.x + rows[2][2] * p.y + rows[2][3] * p.z + rows[2][4],
                        rows[3][1] * p.x + rows[3][2] * p.y + rows[3][3] * p.z + rows[3][4])
    end
    return m
end

function M.enable(cl)
    local E, R = cl.env, cl
    if R.meshFake then return end
    R.meshFake = true
    local frame = 0
    R.groups = {}
    local orig = E.Matrix
    E.Matrix = function(t) if type(t) == "table" then return fakeMatrix(E, t) end return orig() end
    E.SysTime = os.clock
    E.FrameNumber = function() frame = frame + 1 return frame end
    E.GetRenderTargetEx = function(name) return { name = name } end
    E.CreateMaterial = function(name, shader, kv)
        local m = { name = name, shader = shader, kv = kv }
        function m:SetTexture(k, t) self[k] = t end
        function m:GetTexture(k) return self[k] end
        return m
    end
    E.Mesh = function()
        local m = { valid = true }
        function m:BuildFromTriangles() end
        function m:Draw() end
        function m:Destroy() self.valid = false end
        function m:IsValid() return self.valid end
        return m
    end
    local r = E.render
    for _, k in ipairs({ "PushRenderTarget", "PopRenderTarget", "Clear", "SetModelLighting",
            "SetLocalModelLights", "SuppressEngineLighting", "OverrideAlphaWriteEnable", "SetMaterial" }) do
        r[k] = function() end
    end
    E.cam.Start2D = function() end
    E.cam.End2D = function() end
    E.surface.DrawPoly = function() end
    E.draw.NoTexture = function() end
    E.draw.SimpleTextOutlined = function() end
    r.ComputeLighting = function() return E.Vector(0.3, 0.3, 0.3) end
    r.ComputeDynamicLighting = function() return E.Vector(0, 0, 0) end
    E.mesh = {}
    for _, k in ipairs({ "Normal", "TangentS", "TangentT", "UserData", "TexCoord", "AdvanceVertex",
            "Begin", "Position", "End" }) do
        E.mesh[k] = function() end
    end
    local BM = E.BMX.BikeMesh
    local drawGroup = BM.DrawGroup
    BM.DrawGroup = function(model, name, mtx, paint, lod)
        R.groups[#R.groups + 1] = { name = name, m = mtx, paint = paint, lod = lod }
        return drawGroup(model, name, mtx, paint, lod)
    end
end

-- Draw an entity once, with everything recorded from scratch.
function M.draw(cl, ent)
    cl.lines, cl.beams, cl.drawnModels, cl.boxes3d = 0, {}, 0, 0
    cl.drawnCS, cl.groups = {}, {}
    ent:Draw()
end

-- Draw until its model has been built (it is built a slice a frame).
function M.ready(cl, ent)
    for _ = 1, 8000 do
        M.draw(cl, ent)
        if #cl.groups > 0 then return true end
    end
    return false
end

-- The nth group of that name drawn last frame (its matrix), or nil.
function M.group(cl, name, nth)
    local i = 0
    for _, g in ipairs(cl.groups) do
        if g.name == name then
            i = i + 1
            if i == (nth or 1) then return g.m end
        end
    end
end

function M.count(cl, name)
    local n = 0
    for _, g in ipairs(cl.groups) do if g.name == name then n = n + 1 end end
    return n
end

return M
