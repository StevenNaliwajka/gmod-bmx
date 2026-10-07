--[[--------------------------------------------------------------------------
    The city around the park (sh_city.lua, sh_city_maps.lua, cl_city.lua,
    sv_city.lua, bmx_city_solid).

    What can go wrong with a city nobody here can look at:
      - something solid lands on a ramp, or in a lane riders use
      - a viaduct is low enough to hit off the halfpipe
      - a train runs out of its portal into open air, or through a wall
      - the server's colliders and the client's picture disagree
      - it builds a different city every session
    The ramp footprints below are each ramp's WorldSpaceAABB, read off the
    running test server on gm_skatepark, 2026-10-07. (Not computed from the
    BSP: a model's vertices are stored turned 90 degrees from entity space,
    and the first layout, checked against those, put a pier on the halfpipe.)
----------------------------------------------------------------------------]]

local F = require("lib.fixture")

-- name, x0, y0, x1, y1, z0, z1
local RAMPS = {
    { "spiner2", -221, -1785, 155, -1208, 63, 179 },
    { "flatramp", -161, 481, 193, 767, 63, 177 },
    { "quarterpipe3", 187, 475, 807, 774, 63, 237 },
    { "halfpipe7", 324, -1037, 1515, -468, 64, 421 },
    { "flatramp", 559, -1791, 913, -1505, 63, 177 },
    { "funbox2", 572, -259, 1118, 222, 64, 150 },
    { "quarterpipe3", 811, 475, 1431, 774, 64, 237 },
    { "spiner2", 1386, -1703, 1963, -1327, 63, 179 },
    { "funbox2", 1855, -290, 2401, 191, 64, 150 },
    { "flatramp", 2151, -1009, 2437, -655, 63, 177 },
    { "funbox2", 2398, -1776, 2944, -1295, 64, 150 },
    { "spiner2", 2437, -1082, 2812, -505, 63, 179 },
    { "spiner2", 2805, -1082, 3180, -505, 63, 179 },
    { "rail2", 2914, -342, 3230, -330, 63, 139 },
    { "flatramp", 2929, -257, 3215, 97, 63, 177 },
    { "flatramp", 2929, 95, 3215, 449, 63, 177 },
    { "quarterpipe3", 3291, -1687, 3590, -1067, 64, 237 },
}
local SPAWNS = { { 1008, -421 }, { 2562, 0 }, { 195, -764 }, { 1707, -673 }, { 3212, -814 } }
local SKY_CEILING = 1720

local function city()
    local sv = F.server()
    local City = sv.env.BMX.City
    return City, City.Build(City.Maps.gm_skatepark), sv
end

local function overlap(a, b, margin)
    margin = margin or 0
    return a[1] < b[4] + margin and a[4] > b[1] - margin
       and a[2] < b[5] + margin and a[5] > b[2] - margin
       and a[3] < b[6] + margin and a[6] > b[3] - margin
end

local function rampBox(r) return { r[2], r[3], r[6], r[4], r[5], r[7] } end

T.test("the city builds the same every time: one seed, no math.random", function()
    local City, a = city()
    local b = City.Build(City.Maps.gm_skatepark)
    T.eq(a.quads, b.quads, "quad count")
    T.eq(#a.buildings, #b.buildings, "building count")
    for mat, list in pairs(a.faces) do
        T.eq(#list, #b.faces[mat], mat .. " quads")
        for j = 1, 17 do T.eq(list[1][j], b.faces[mat][1][j], mat .. " first quad field " .. j) end
    end
end)

T.test("every material a style or a face uses is defined", function()
    local City, L = city()
    for name, st in pairs(City.Styles) do
        for _, k in ipairs(st.ground) do T.ok(City.Materials[k], name .. ".ground " .. k) end
        for _, k in ipairs(st.win) do T.ok(City.Materials[k], name .. ".win " .. k) end
        T.ok(City.Materials[st.plain], name .. ".plain")
        T.ok(City.Materials[st.trim], name .. ".trim")
    end
    for mat in pairs(L.faces) do T.ok(City.Materials[mat], "face material " .. mat) end
    for _, s in ipairs(City.Maps.gm_skatepark.frontage.styles) do T.ok(City.Styles[s], "style " .. s) end
end)

T.test("a city, not a token: buildings on all four sides, a skyline, three lines", function()
    local _, L = city()
    local per = {}
    for _, b in ipairs(L.buildings) do per[b.side] = (per[b.side] or 0) + 1 end
    for _, s in ipairs({ "north", "south", "east", "west" }) do
        T.ok((per[s] or 0) >= 4, s .. " frontage has " .. tostring(per[s]) .. " buildings")
    end
    T.ok((per.skyline or 0) >= 30, "skyline towers: " .. tostring(per.skyline))
    T.eq(#L.lines, 3, "subway lines")
    -- and cheap: well inside what a frame can draw for nothing
    T.between(L.quads, 2000, 20000, "quads")
end)

T.test("the frontage covers every metre of all four walls", function()
    local City, L = city()
    local p = City.Maps.gm_skatepark.park
    local walls = {
        north = { axis = 1, from = p[1], to = p[4] }, south = { axis = 1, from = p[1], to = p[4] },
        west = { axis = 2, from = p[2], to = p[5] }, east = { axis = 2, from = p[2], to = p[5] },
    }
    for name, w in pairs(walls) do
        local spans = {}
        for _, b in ipairs(L.rows[name]) do spans[#spans + 1] = { b[w.axis], b[w.axis + 3] } end
        table.sort(spans, function(a, b) return a[1] < b[1] end)
        local at = w.from
        for _, s in ipairs(spans) do
            if s[1] <= at + 0.5 then at = math.max(at, s[2]) end
        end
        T.ok(at >= w.to - 0.5, name .. " wall covered to " .. at .. " of " .. w.to)
        -- and from the floor up, at least to the top of the brick (528)
        for _, b in ipairs(L.rows[name]) do
            T.ok(b[3] <= 64 and b[6] >= 528, name .. " building spans the wall's height")
        end
    end
end)

T.test("no building stands in the park: only the facade's inset crosses the wall", function()
    local City, L = city()
    local def = City.Maps.gm_skatepark
    local p = def.park
    local inner = { p[1] + def.frontage.inset + 0.01, p[2] + def.frontage.inset + 0.01, -1e9,
                    p[4] - def.frontage.inset - 0.01, p[5] - def.frontage.inset - 0.01, 1e9 }
    for _, b in ipairs(L.buildings) do
        T.ok(not overlap(b, inner), string.format("building %s %d,%d-%d,%d reaches into the park",
            tostring(b.side), b[1], b[2], b[4], b[5]))
    end
end)

T.test("every solid is inside the park box, clear of every ramp and spawn", function()
    local _, L = city()
    T.ok(#L.solids >= 5, "solids: " .. #L.solids)
    for _, s in ipairs(L.solids) do
        for _, b in ipairs(s.boxes) do
            T.ok(b[1] >= -256 and b[4] <= 3584 and b[2] >= -1792 and b[5] <= 768 and b[3] >= 64 and b[6] <= SKY_CEILING,
                s.name .. " box inside the play box")
            for _, r in ipairs(RAMPS) do
                -- 40 units of air around every ramp: room to ride past it
                T.ok(not overlap(b, rampBox(r), 40), s.name .. " clear of " .. r[1] .. " at " .. r[2] .. "," .. r[3])
            end
            for _, sp in ipairs(SPAWNS) do
                T.ok(not overlap(b, { sp[1] - 32, sp[2] - 32, 64, sp[1] + 32, sp[2] + 32, 136 }, 64),
                    s.name .. " clear of the spawn at " .. sp[1] .. "," .. sp[2])
            end
        end
    end
end)

T.test("only the piers come down to the floor; the viaducts fly 500 over the tallest coping", function()
    local _, L = city()
    local top = 0
    for _, r in ipairs(RAMPS) do top = math.max(top, r[7]) end
    for _, s in ipairs(L.solids) do
        for _, b in ipairs(s.boxes) do
            if not s.name:find("^pier") then
                T.ok(b[3] >= top + 400, s.name .. " underside " .. b[3] .. " vs coping " .. top)
            end
        end
    end
end)

T.test("the viaducts cross without touching, and stay under the sky ceiling", function()
    local _, L = city()
    local lines = {}
    for _, s in ipairs(L.solids) do if s.name:find("^line") then lines[#lines + 1] = s end end
    T.eq(#lines, 3, "three viaduct solids")
    for i = 1, #lines do
        for j = i + 1, #lines do
            for _, a in ipairs(lines[i].boxes) do
                for _, b in ipairs(lines[j].boxes) do
                    T.ok(not overlap(a, b), lines[i].name .. " vs " .. lines[j].name)
                end
            end
        end
        for _, b in ipairs(lines[i].boxes) do T.ok(b[6] < SKY_CEILING, lines[i].name .. " under the ceiling") end
    end
end)

T.test("each pier's cap meets its viaduct's underside, and its post the line above", function()
    local City, L = city()
    local def = City.Maps.gm_skatepark
    local V = City.Viaduct
    for _, pr in ipairs(def.piers) do
        local low, high
        for _, v in ipairs(def.viaducts) do
            local onLine = (v.axis == "y" and math.abs(v.at - pr.x) < 1) or (v.axis == "x" and math.abs(v.at - pr.y) < 1)
            if onLine and v.deck < 1200 then low = v elseif onLine then high = v end
        end
        T.ok(low and high, pr.name .. " stands under a crossing")
        T.eq(pr.top, low.deck - V.slab - V.girder, pr.name .. " cap at the low line's girders")
        T.eq(pr.postFrom, low.deck + V.truss + 16, pr.name .. " post starts on the low truss")
        T.eq(pr.postTo, high.deck - V.slab - V.girder, pr.name .. " post meets the high line's girders")
    end
end)

T.test("every portal is swallowed by a building tall enough to hold it", function()
    local City, L = city()
    local V = City.Viaduct
    for _, l in ipairs(L.lines) do
        local ends = l.axis == "y" and { "south", "north" } or { "west", "east" }
        local need = l.deck + V.truss + 64
        for _, side in ipairs(ends) do
            local covered = false
            for _, b in ipairs(L.rows[side]) do
                local a0, a1 = (l.axis == "y") and b[1] or b[2], (l.axis == "y") and b[4] or b[5]
                if a0 <= l.at - V.width and a1 >= l.at + V.width and b[6] >= need then covered = true end
                -- a portal straddling two buildings: both must be tall enough
                if a0 < l.at + V.width and a1 > l.at - V.width then
                    T.ok(b[6] >= need, l.name .. " " .. side .. " building " .. b[6] .. " under the portal top " .. need)
                    covered = covered or (b[6] >= need)
                end
            end
            T.ok(covered, l.name .. " has a building at its " .. side .. " end")
        end
    end
end)

T.test("trains: come out of one portal, go in the other, alternate, never collide", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local City = cl.env.BMX.City
    local L = City.Build(City.Maps.gm_skatepark)
    for _, l in ipairs(L.lines) do
        local len = l.to - l.from
        local seen, dirs, first, last = false, {}, nil, nil
        for t = 0, l.period * 4, 0.05 do
            local st = City.TrainAt(l, t)
            if st then
                seen = true
                dirs[st.cycle] = st.dir
                first = first and math.min(first, st.head) or st.head
                last = last and math.max(last, st.head - st.train) or (st.head - st.train)
                -- cars in order, a gap apart, all on the line
                for i = 1, l.cars - 1 do
                    local ax, ay = City.CarPos(l, st, i)
                    local bx, by = City.CarPos(l, st, i + 1)
                    local d = math.abs((ax - bx) + (ay - by))
                    T.near(d, City.TrainCar.length + City.TrainCar.gap, 0.01, l.name .. " car spacing")
                end
            end
        end
        T.ok(seen, l.name .. " ran in four periods")
        T.ok(first < -City.TrainCar.length, l.name .. " starts hidden behind its first portal")
        T.ok(last > len, l.name .. " ends hidden behind its far portal")
        local d0, d1 = dirs[0], dirs[1]
        T.ok(d0 and d1 and d0 ~= d1, l.name .. " alternates direction")
        -- the run is shorter than the period: never two trains on one line
        local st = City.TrainAt(l, l.offset + 0.01)
        T.ok(st and st.run < l.period, l.name .. " run " .. (st and st.run or -1) .. "s in a " .. l.period .. "s period")
    end
end)

T.test("a car fits inside the truss it runs through", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local City = cl.env.BMX.City
    local V = City.Viaduct
    -- train_outro_car01: 136 wide, 205 tall from its floor (measured from the model)
    T.ok(136 < V.width - 2 * 16, "car width inside the chords")
    T.ok(V.rail + 205 < V.truss, "car roof under the top bracing")
end)

T.test("no city on a map that has none: no solids, nothing to draw", function()
    local sv, world = F.server()
    T.eq(sv.env.BMX.City.Layout(), nil, "no layout on gm_flatgrass")
    T.eq(#sv.env.ents.FindByClass("bmx_city_solid"), 0, "no solids")
    local cl = F.client(world)
    T.eq(cl.env.BMX.City.meshes, nil, "no meshes")
end)

T.test("on gm_skatepark the server spawns one collider per solid, boxes intact", function()
    local sv = F.server()
    local env = sv.env
    env.game.GetMap = function() return "gm_skatepark" end
    local n = env.BMX.City.SpawnSolids()
    local L = env.BMX.City.Layout()
    T.eq(n, #L.solids, "spawned")
    local found = env.ents.FindByClass("bmx_city_solid")
    T.eq(#found, #L.solids, "entities")
    for _, e in ipairs(found) do
        local s = L.solids[e:GetSolidName()]
        T.ok(s, "named " .. e:GetSolidName())
        local phys = e:GetPhysicsObject()
        T.ok(phys and phys ~= nil and e._phys, e:GetSolidName() .. " has a body")
        T.eq(#e._phys.boxes, #s.boxes, e:GetSolidName() .. " box count")
        -- entity-space boxes back in world space are the layout's boxes
        local o = e:GetPos()
        local b, w = e._phys.boxes[1], s.boxes[1]
        T.near(b[1].x + o.x, w[1], 0.01, "x0") T.near(b[2].z + o.z, w[6], 0.01, "z1")
    end
    -- again: a rebuild replaces, it does not stack
    env.BMX.City.SpawnSolids()
    T.eq(#env.ents.FindByClass("bmx_city_solid"), #L.solids, "rebuild replaces")
    -- and bmx_city 0 clears them
    env.GetConVar("bmx_city"):SetInt(0)
    T.eq(env.BMX.City.SpawnSolids(), 0, "off")
    T.eq(#env.ents.FindByClass("bmx_city_solid"), 0, "none when off")
end)

T.test("the client builds its meshes: four vertices a quad, every one finite", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local env = cl.env
    env.game.GetMap = function() return "gm_skatepark" end
    local verts, quadsIn, cur = 0, 0, nil
    local bad = 0
    env.Mesh = function(mat) return { mat = mat, Draw = function() end, Destroy = function() end } end
    env.MATERIAL_QUADS = 4
    env.CreateMaterial = function(name, shader, params) return { name = name, shader = shader, params = params } end
    env.mesh = {
        Begin = function(m, kind, n) cur = m quadsIn = quadsIn + n end,
        Position = function(v) if v.x ~= v.x or math.abs(v.x) > 1e6 or math.abs(v.z) > 1e6 then bad = bad + 1 end end,
        TexCoord = function(_, u, v) if u ~= u or v ~= v then bad = bad + 1 end end,
        Color = function(r, g, b, a) if r < 0 or r > 255 or a ~= 255 then bad = bad + 1 end end,
        AdvanceVertex = function() verts = verts + 1 end,
        End = function() end,
    }
    env.SysTime = function() return 0 end
    T.ok(env.BMX.City.ClientBuild(), "built")
    local L = env.BMX.City.Layout()
    T.eq(quadsIn, L.quads, "every quad went into a mesh")
    T.eq(verts, L.quads * 4, "four vertices each")
    T.eq(bad, 0, "no NaN, no runaway coordinates, colours in range")
    for _, m in ipairs(env.BMX.City.meshes) do
        T.ok(m.quads <= 4000, "mesh under the per-mesh cap")
        T.eq(m.mat.shader, "UnlitGeneric", "unlit: a mesh has no lightmap")
    end
    -- the truss is alpha-tested, the facades are not
    T.eq(env.BMX.City.Material("truss").params["$alphatest"], "1", "truss alpha-tested")
    T.eq(env.BMX.City.Material("brick_win").params["$alphatest"], nil, "facade opaque")
end)

-- A client with the city built against stub meshes, and the draw calls
-- recorded. Signs and trains are switched off: this is about the meshes.
local function drawnClient()
    local sv, world = F.server()
    local cl = F.client(world)
    local env = cl.env
    env.game.GetMap = function() return "gm_skatepark" end
    local draws = {}
    env.Mesh = function(mat) local m = { mat = mat } function m:Draw() draws[#draws + 1] = self end function m:Destroy() end return m end
    env.MATERIAL_QUADS = 4
    env.CreateMaterial = function(name, shader, params) return { name = name, shader = shader, params = params } end
    env.mesh = { Begin = function() end, Position = function() end, TexCoord = function() end,
                 Color = function() end, AdvanceVertex = function() end, End = function() end }
    env.SysTime = function() return 0 end
    env.render.SetMaterial = function() end
    env.render.GetViewSetup = function() return { fov = 100, aspect = 16 / 9 } end
    env.GetConVar("bmx_city_trains"):SetInt(0)
    env.GetConVar("bmx_city_signs"):SetInt(0)
    T.ok(env.BMX.City.ClientBuild(), "built")
    return env, draws
end

T.test("drawn on frames where GMod says bDrawingSkybox: it is true on every frame of this map", function()
    local env, draws = drawnClient()
    local eye, ang = env.Vector(1700, -500, 120), env.Angle(-20, 90, 0)
    env.EyePos = function() return eye end
    env.EyeAngles = function() return ang end
    -- what a live gm_skatepark client passed, 63 frames of 63
    env.hook.Run("PostDrawOpaqueRenderables", false, true, false)
    T.ok(#draws > 10, "meshes drawn on an ordinary frame: " .. #draws)
    local n = #draws
    env.hook.Run("PostDrawOpaqueRenderables", true, false, false)
    T.eq(#draws, n, "the depth pass draws nothing")
    env.hook.Run("PostDrawOpaqueRenderables", false, true, true)
    T.eq(#draws, n, "the 3D skybox's own pass draws nothing")
end)

T.test("culling: what is in view is drawn, what is behind is not, and the corners count", function()
    local env = drawnClient()
    local City = env.BMX.City
    local V = env.Vector
    local fwd = V(1, 0, 0)
    local half = math.rad(60)
    local c, s = math.cos(half), math.sin(half)
    T.ok(City.InView(V(1000, 0, 0), 10, V(0, 0, 0), fwd, c, s), "straight ahead")
    T.ok(not City.InView(V(-1000, 0, 0), 10, V(0, 0, 0), fwd, c, s), "behind")
    T.ok(City.InView(V(-50, 0, 0), 100, V(0, 0, 0), fwd, c, s), "around the camera")
    T.ok(City.InView(V(1000, 1700, 0), 10, V(0, 0, 0), fwd, c, s), "inside the edge (59.5 deg)")
    T.ok(not City.InView(V(1000, 1800, 0), 10, V(0, 0, 0), fwd, c, s), "outside the edge (61 deg)")
    T.ok(City.InView(V(1000, 1800, 0), 200, V(0, 0, 0), fwd, c, s), "a big thing straddling the edge")
end)

T.test("looking at one wall skips most of the city, and nothing on screen is skipped", function()
    local env, draws = drawnClient()
    local City = env.BMX.City
    env.EyePos = function() return env.Vector(1700, -500, 120) end
    env.EyeAngles = function() return env.Angle(0, 90, 0) end        -- facing north
    env.hook.Run("PostDrawOpaqueRenderables", false, true, false)
    T.ok(City.Stats.culled > 0, "something culled")
    T.ok(City.Stats.drawn > 0, "something drawn")
    -- the north frontage is in front of the camera: every mesh of it drawn
    local drawn = {}
    for _, m in ipairs(draws) do drawn[m] = true end
    for _, m in ipairs(City.meshes) do
        if m.group == "front:north" then T.ok(drawn[m.mesh], "north frontage mesh " .. m.key .. " drawn") end
        if m.group == "front:south" and m.center.y < -2500 then
            T.ok(not drawn[m.mesh], "south frontage behind the camera culled")
        end
    end
end)

T.test("nearest first: viaducts, then the frontage, the back row, the skyline", function()
    local env = drawnClient()
    local rank = { via = 1, front = 2, back = 3, sky = 4 }
    local last = 0
    for _, m in ipairs(env.BMX.City.meshes) do
        local r = rank[m.group:match("^(%w+)")] or 5
        T.ok(r >= last, "mesh order " .. m.group)
        last = r
    end
    local _, L = city()
    for mat, list in pairs(L.faces) do
        for _, q in ipairs(list) do T.ok(q[18] and q[18] ~= "misc", mat .. " quad has a group") break end
    end
end)

T.test("the rooftop billboards stand on their building's roof, out of reach", function()
    local City, L = city()
    local n = 0
    for _, s in ipairs(L.signs) do
        if s.roof then
            n = n + 1
            T.ok(s.pos[3] - s.h / 2 > s.roof, s.text .. " above its roof")
            T.ok(s.pos[3] - s.h / 2 > 528, s.text .. " above the wall")
            -- within one building's width, so no neighbour hides part of it
            local side = L.rows[s.side]
            local ax = (s.side == "north" or s.side == "south") and 1 or 2
            local on
            for _, bd in ipairs(side) do
                local top = bd.tower or bd
                if top[ax] <= s.at - s.w / 2 and top[ax + 3] >= s.at + s.w / 2 then on = top end
            end
            T.ok(on and math.abs(on[6] - s.roof) < 0.01, s.text .. " fits on one roof")
            -- outside the play box: nobody rides into it
            local p = City.Maps.gm_skatepark.park
            T.ok(s.pos[1] < p[1] or s.pos[1] > p[4] or s.pos[2] < p[2] or s.pos[2] > p[5], s.text .. " outside the box")
        end
    end
    T.eq(n, #City.Maps.gm_skatepark.billboards, "every billboard found a roof")
end)

T.test("an ad's sunburst rays stop at the board's edge", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local clip = cl.env.BMX.City.ClipRect
    -- a ray from inside the board reaching far past its right edge
    local out = clip({ { x = 0, y = 0 }, { x = 1000, y = -50 }, { x = 1000, y = 50 } }, -100, -60, 100, 60)
    T.ok(#out >= 3, "still a polygon")
    for _, p in ipairs(out) do
        T.between(p.x, -100.001, 100.001, "x inside") T.between(p.y, -60.001, 60.001, "y inside")
    end
    -- and one entirely outside is gone
    T.ok(#clip({ { x = 200, y = 0 }, { x = 300, y = 10 }, { x = 300, y = -10 } }, -100, -60, 100, 60) < 3, "outside dropped")
end)
