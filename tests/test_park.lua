--[[--------------------------------------------------------------------------
    The park pieces (sh_park.lua, sv_park.lua, cl_park.lua, bmx_park_piece,
    the bmx_park tool).

    What can go wrong with ramps nobody here can look at:
      - a piece's collision is a degenerate hull (flat, open, repeated points)
      - the picture and the collision disagree (the drawn mesh sticks out of,
        or sits inside, what you hit)
      - a rail the headless suite aims at is not something sv_grind would grind
      - two pieces snapped together leave a gap or overlap
      - a saved park does not come back as it was, or anyone may save one
      - a preset overlaps itself or goes past the cap
----------------------------------------------------------------------------]]

local F = require("lib.fixture")
local H = require("lib.hull")
local VA = require("lib.vecang")
local Vector = VA.Vector

local function server()
    local sv, world = F.server()
    return sv, world, sv.env.BMX.Park
end

-- Every (shape, size, variant) the spawn menu offers.
local function eachSpec(P, fn)
    for _, id in ipairs(P.Order) do
        local def = P.Shapes[id]
        for v = 1, (def.variants and #def.variants or 1) do
            for s = 1, #P.SIZES do fn(id, s, v, P.Build(id, { s, v })) end
        end
    end
end

local function name(id, s, v) return id .. " size " .. s .. " variant " .. v end

local function facesOf(b)
    if not b._hf then
        b._hf = {}
        for i, h in ipairs(b.hulls) do b._hf[i] = H.check(h).faces end
    end
    return b._hf
end

-- The highest solid at (x, y) over the piece, or 0 for the floor.
local function topAt(b, x, y)
    local top = 0
    for _, f in ipairs(facesOf(b)) do
        local lo, hi = H.column(f, x, y)
        if lo then top = math.max(top, hi) end
    end
    return top
end

--------------------------------------------------------------------------
-- The geometry
--------------------------------------------------------------------------
T.test("park: every piece, size and variant is built, and there are the shapes the goal lists", function()
    local _, _, P = server()
    local want = { "kicker", "launch", "quarterpipe", "spine", "bank", "funbox", "pyramid", "flatrail",
        "downrail", "kinkedrail", "ledge", "hubba", "bowlcorner", "dirtjump", "dropin" }
    for _, id in ipairs(want) do T.ok(P.Shapes[id], "shape " .. id) end
    T.eq(#P.Order, #want, "no unlisted shape")
    T.eq(#P.SIZES, 3, "S, M, L")
    T.eq(#P.Shapes.quarterpipe.variants, 3, "three quarter pipe heights")
    local n = 0
    eachSpec(P, function(id, s, v, b)
        n = n + 1
        T.ok(b and #b.hulls >= 1 and #b.faces >= 1, name(id, s, v) .. " has hulls and faces")
        T.ok(#b.hulls <= 80, name(id, s, v) .. ": " .. #b.hulls .. " hulls is too many for one piece")
    end)
    T.eq(n, 78, "spawn menu entries")
end)

T.test("park: every hull is a proper convex solid: closed, with volume, no bad points", function()
    local _, _, P = server()
    eachSpec(P, function(id, s, v, b)
        for i, h in ipairs(b.hulls) do
            local r = H.check(h)
            T.ok(r.ok, name(id, s, v) .. " hull " .. i .. ": " .. tostring(r.why))
            T.ok(#h <= 32, name(id, s, v) .. " hull " .. i .. " has " .. #h .. " points")
        end
    end)
end)

T.test("park: the drawn mesh is the collision: same bounds, every drawn vertex on a hull", function()
    local _, _, P = server()
    eachSpec(P, function(id, s, v, b)
        local lo = { math.huge, math.huge, math.huge }
        local hi = { -math.huge, -math.huge, -math.huge }
        local flo = { math.huge, math.huge, math.huge }
        local fhi = { -math.huge, -math.huge, -math.huge }
        for _, h in ipairs(b.hulls) do
            for _, p in ipairs(h) do
                lo[1], lo[2], lo[3] = math.min(lo[1], p.x), math.min(lo[2], p.y), math.min(lo[3], p.z)
                hi[1], hi[2], hi[3] = math.max(hi[1], p.x), math.max(hi[2], p.y), math.max(hi[3], p.z)
            end
        end
        for _, f in ipairs(b.faces) do
            T.ok(#f.pts >= 3 and #f.pts <= 4, name(id, s, v) .. ": a face of " .. #f.pts .. " points")
            T.ok(P.Colors[f.key], name(id, s, v) .. ": colour " .. tostring(f.key))
            for _, p in ipairs(f.pts) do
                T.finite(p, name(id, s, v) .. " face vertex")
                flo[1], flo[2], flo[3] = math.min(flo[1], p.x), math.min(flo[2], p.y), math.min(flo[3], p.z)
                fhi[1], fhi[2], fhi[3] = math.max(fhi[1], p.x), math.max(fhi[2], p.y), math.max(fhi[3], p.z)
                local on = false
                for _, hf in ipairs(facesOf(b)) do
                    if H.contains(hf, p, 0.05) then on = true break end
                end
                T.ok(on, string.format("%s: drawn vertex (%.2f %.2f %.2f) is not on any hull",
                    name(id, s, v), p.x, p.y, p.z))
            end
        end
        for k = 1, 3 do
            T.near(flo[k], lo[k], 1e-3, name(id, s, v) .. " mesh min " .. k)
            T.near(fhi[k], hi[k], 1e-3, name(id, s, v) .. " mesh max " .. k)
        end
        -- and they match what the entity is told
        T.near(b.mins.z, 0, 1e-6, name(id, s, v) .. " stands on the floor")
        T.near(b.mins.x, -b.maxs.x, 1e-3, name(id, s, v) .. " centred in x")
        T.near(b.mins.y, -b.maxs.y, 1e-3, name(id, s, v) .. " centred in y")
        T.ok(b.hl >= b.maxs.x - 1e-6 and b.hw >= b.maxs.y - 1e-6, name(id, s, v) .. " footprint covers it")
    end)
end)

T.test("park: one generator, no randomness: the server, the client and a second boot build the same", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local sv2 = F.server()
    local function dump(P)
        local out = {}
        eachSpec(P, function(id, s, v, b)
            local t = {}
            for _, h in ipairs(b.hulls) do
                for _, p in ipairs(h) do t[#t + 1] = string.format("%.6f,%.6f,%.6f", p.x, p.y, p.z) end
            end
            for _, f in ipairs(b.faces) do
                for _, p in ipairs(f.pts) do t[#t + 1] = string.format("%.6f,%.6f,%.6f", p.x, p.y, p.z) end
            end
            out[#out + 1] = name(id, s, v) .. ":" .. table.concat(t, ";")
        end)
        return table.concat(out, "\n")
    end
    local a = dump(sv.env.BMX.Park)
    T.eq(dump(cl.env.BMX.Park), a, "the client's build")
    T.eq(dump(sv2.env.BMX.Park), a, "another boot's build")
end)

T.test("park: parameters are clamped, never refused, and a size or variant changes the piece", function()
    local _, _, P = server()
    T.eq(P.EncodeParams("quarterpipe", { 9, 0 }), "3,1", "out of range")
    T.eq(P.EncodeParams("quarterpipe", "2, 3"), "2,3", "from a string")
    T.eq(P.EncodeParams("kicker", nil), "2,1", "default is medium")
    T.eq(P.EncodeParams("kicker", { 2, 3 }), "2,1", "a shape without variants has one")
    local lo, hi = P.Build("quarterpipe", { 2, 1 }), P.Build("quarterpipe", { 2, 3 })
    T.between(hi.maxs.z - lo.maxs.z, 40, 60, "a taller quarter pipe is taller")
    local s, l = P.Build("flatrail", { 1 }), P.Build("flatrail", { 3 })
    T.ok(l.maxs.x > s.maxs.x * 1.5, "a larger rail is longer")
    T.eq(P.Build("nope", { 1, 1 }), nil, "an unknown shape builds nothing")
end)

T.test("park: the quarter pipes' heights are 36, 56 and 84 and the lip is where the deck starts", function()
    local _, _, P = server()
    for v, h in ipairs({ 36, 56, 84 }) do
        local b = P.Build("quarterpipe", { 2, v })
        -- the top is the coping, 3 above the deck at the height
        T.near(b.maxs.z, h + 3, 0.01, "variant " .. v .. " top")
        T.near(topAt(b, b.maxs.x - 1, 0), h, 0.05, "variant " .. v .. " deck height")
        T.ok(topAt(b, b.mins.x + 2, 0) < 2, "it starts at the floor")
    end
end)

-- A wheel box sliding up a transition caught the top edge of the next strip's
-- side face wherever two strips were butted end to end (sh_park.lua, strips:
-- SEAM_BURY), and the coping hung 2 u out over the face (coping: onDeck). Both
-- cost a bike most of its speed up a tall park quarter pipe on a real server.
T.test("park: up a transition no strip's end is at the riding surface: every concave joint is buried", function()
    local _, _, P = server()
    local checked = 0
    for _, id in ipairs({ "quarterpipe", "spine", "dropin", "launch" }) do
        local def = P.Shapes[id]
        for v = 1, (def.variants and #def.variants or 1) do
            for sz = 1, #P.SIZES do
                local b = P.Build(id, { sz, v })
                for hi, h in ipairs(b.hulls) do
                    for _, f in ipairs(facesOf(b)[hi]) do
                        if math.abs(f.n[3]) < 1e-6 and math.abs(f.n[1]) > 0.999 then
                            local x = f.d / f.n[1]
                            local top = -math.huge
                            for _, k in ipairs(f.idx) do top = math.max(top, h[k].z) end
                            local s = topAt(b, x, 0)
                            local sl, sr = topAt(b, x - 1, 0), topAt(b, x + 1, 0)
                            -- a joint in the riding surface, the surface turning up there
                            if top > 1 and s - top < 0.05 and math.abs(sl - s) < 4 and math.abs(sr - s) < 4
                                and (sr - s) > (s - sl) + 0.01 then
                                T.ok(false, string.format("%s: a strip's end at x %.1f is the riding surface (top %.2f)",
                                    name(id, sz, v), x, top))
                            end
                            checked = checked + 1
                        end
                    end
                end
            end
        end
    end
    T.ok(checked > 50, "looked at the strips' end faces: " .. checked)
end)

T.test("park: a lip's coping sits on the deck, nothing over the face in front of it", function()
    local _, _, P = server()
    for _, id in ipairs({ "quarterpipe", "dropin" }) do
        for v, h in ipairs({ 36, 56, 84 }) do
            local b = P.Build(id, { 2, v })
            local cop
            for _, g in ipairs(b.grind) do if g.kind == "coping" then cop = g end end
            T.ok(cop ~= nil, id .. " " .. v .. " has coping")
            if cop then
                -- where the 70 degree curve meets the deck (sh_park.lua, arcLine)
                local R = h / (1 - math.cos(math.rad(70)))
                local lip = b.mins.x + R * math.sin(math.rad(70))
                local front = topAt(b, lip - 0.5, 0)
                T.ok(front < h, string.format("%s %d: half a unit in front of the lip it is still the face (%.1f), not the coping",
                    id, v, front))
                T.near(topAt(b, lip + 0.5, 0), h + 3, 0.05, id .. " " .. v .. ": the coping starts at the lip")
                T.near(cop.a.x, lip + 2, 0.05, id .. " " .. v .. ": its grind line is the bar's middle")
            end
        end
    end
end)

--------------------------------------------------------------------------
-- Grind tags. sv_grind.lua finds a rail by tracing down round a point and
-- reading what it sees (C.Grind: pipeMaxWidth, drop, topTol, edgeCheck). The
-- tags are what the headless suite aims at, so each one must be something that
-- reading would accept.
--------------------------------------------------------------------------
local function lerp(a, b, t) return a + (b - a) * t end

T.test("park: every rail is a pipe the grind finds: narrow, its top at the tag, the ground gone either side", function()
    local sv, _, P = server()
    local G = sv.env.BMX.Config.Grind
    local n = 0
    eachSpec(P, function(id, s, v, b)
        for _, g in ipairs(b.grind) do
            if g.kind == "rail" then
                n = n + 1
                local y0 = g.a.y
                T.near(g.b.y, y0, 1e-6, name(id, s, v) .. " rail runs straight along x")
                for _, t in ipairs({ 0.15, 0.5, 0.85 }) do
                    local x, z = lerp(g.a.x, g.b.x, t), lerp(g.a.z, g.b.z, t)
                    T.near(topAt(b, x, y0), z, 0.1, name(id, s, v) .. " rail top at t=" .. t)
                    -- the width of the top: how far from the line it stays "on"
                    local half = 0
                    for y = 0.25, 8, 0.25 do
                        if topAt(b, x, y0 + y) >= z - G.topTol then half = y else break end
                    end
                    T.ok(half * 2 <= G.pipeMaxWidth, name(id, s, v) .. ": rail top " .. half * 2 ..
                        " wide, over pipeMaxWidth " .. G.pipeMaxWidth)
                    for _, y in ipairs({ -G.ring, -3.5, 3.5, G.ring }) do
                        local below = z - topAt(b, x, y0 + y)
                        T.ok(below >= G.drop,
                            string.format("%s: at y %+.1f the ground is %.1f below the rail, wants %d",
                                name(id, s, v), y, below, G.drop))
                    end
                end
            end
        end
    end)
    T.ok(n >= 3 * 4, "flat, down and kinked rails all tagged: " .. n)
end)

-- The side `n` (a horizontal unit) of a line at its point t falls away.
local function drops(b, g, t, G, dist)
    local x, y, z = lerp(g.a.x, g.b.x, t), lerp(g.a.y, g.b.y, t), lerp(g.a.z, g.b.z, t)
    local dx, dy = g.b.x - g.a.x, g.b.y - g.a.y
    local l = math.sqrt(dx * dx + dy * dy)
    local px, py = -dy / l, dx / l
    local out = {}
    for _, s in ipairs({ -1, 1 }) do
        out[s] = topAt(b, x + px * s * dist, y + py * s * dist) <= z - G.drop
    end
    return out, x, y, z
end

T.test("park: every ledge and every length of coping is on its top and has a real drop to one side", function()
    local sv, _, P = server()
    local G = sv.env.BMX.Config.Grind
    local counts = {}
    eachSpec(P, function(id, s, v, b)
        for _, g in ipairs(b.grind) do
            if g.kind == "ledge" or g.kind == "coping" then
                counts[g.kind] = (counts[g.kind] or 0) + 1
                for _, t in ipairs({ 0.2, 0.5, 0.8 }) do
                    local d, x, y, z = drops(b, g, t, G, G.edgeCheck + 2)
                    T.near(topAt(b, x, y), z, 0.1, name(id, s, v) .. " " .. g.kind .. " top at t=" .. t)
                    T.ok(d[-1] or d[1], name(id, s, v) .. ": " .. g.kind ..
                        " has no drop of " .. G.drop .. " either side at t=" .. t)
                end
            elseif g.kind == "manual" then
                counts.manual = (counts.manual or 0) + 1
                local x, z = lerp(g.a.x, g.b.x, 0.5), g.a.z
                T.near(topAt(b, x, 0), z, 0.1, name(id, s, v) .. " manual pad top")
            end
        end
    end)
    T.ok((counts.ledge or 0) > 0 and (counts.coping or 0) > 0 and (counts.manual or 0) > 0,
        "ledges, coping and a manual pad are all tagged")
end)

T.test("park: a spine's ridge falls away on both sides", function()
    local sv, _, P = server()
    local G = sv.env.BMX.Config.Grind
    for v = 1, 3 do
        local b = P.Build("spine", { 2, v })
        T.eq(#b.grind, 1, "one ridge")
        local d = drops(b, b.grind[1], 0.5, G, G.edgeCheck + 2)
        T.ok(d[-1] and d[1], "spine variant " .. v .. " drops both sides")
    end
end)

T.test("park: the tags are where the world says they are, turned and moved with the piece", function()
    local _, _, P = server()
    local b = P.Build("flatrail", { 2 })
    local w = P.WorldGrind(b, Vector(100, 200, 10), 90)
    T.eq(#w, 1, "one line")
    -- the rail runs along x; turned 90 degrees it runs along y
    T.near(w[1].a.x, 100, 1e-6, "same x at both ends")
    T.near(math.abs(w[1].b.y - w[1].a.y), b.maxs.x * 2, 1e-3, "the length is along y now")
    T.near(w[1].a.z, 10 + b.grind[1].a.z, 1e-6, "raised with the piece")
end)

--------------------------------------------------------------------------
-- Snapping
--------------------------------------------------------------------------
-- How far two oriented footprint rectangles overlap along their least
-- overlapping axis (separating axis test). Zero: they touch. Negative: a gap.
local function overlap(a, ya, b, yb)
    local function axes(y)
        local c, s = math.cos(math.rad(y)), math.sin(math.rad(y))
        return { { c, s }, { -s, c } }
    end
    local A, B = axes(ya), axes(yb)
    local best = math.huge
    local dx, dy = b.pos.x - a.pos.x, b.pos.y - a.pos.y
    for _, ax in ipairs({ A[1], A[2], B[1], B[2] }) do
        local function r(box, axs)
            return box.hl * math.abs(axs[1][1] * ax[1] + axs[1][2] * ax[2])
                + box.hw * math.abs(axs[2][1] * ax[1] + axs[2][2] * ax[2])
        end
        local o = r(a, A) + r(b, B) - math.abs(dx * ax[1] + dy * ax[2])
        best = math.min(best, o)
    end
    return best
end

T.test("park: snapping puts two footprints edge to edge, touching, on every side and at every turn", function()
    local _, _, P = server()
    local tb, nb = P.Build("funbox", { 2 }), P.Build("quarterpipe", { 2, 2 })
    local tgt = { pos = Vector(100, -50, 7), yaw = 0, hl = tb.hl, hw = tb.hw }
    for _, yaw in ipairs({ 0, 90, 180, -90, 30 }) do
        tgt.yaw = yaw
        for _, local_ in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local ax, ay = P.Rotate(local_[1] * (tb.hl + 40), local_[2] * (tb.hw + 40), yaw)
            for _, rel in ipairs({ 0, 90, 180, 270 }) do
                local pos, ny = P.Snap(tgt, Vector(tgt.pos.x + ax, tgt.pos.y + ay, 0), nb, rel, false)
                local o = overlap(tgt, yaw, { pos = pos, hl = nb.hl, hw = nb.hw }, ny)
                T.near(o, 0, 1e-6, string.format("yaw %d side %d,%d rel %d: overlap", yaw, local_[1], local_[2], rel))
                T.near(pos.z, 7, 1e-9, "same floor")
                T.near((ny - yaw - rel + 180) % 360 - 180, 0, 1e-6, "turned by the tool's turn")
            end
        end
    end
end)

T.test("park: the side snapped to is the one aimed at, judged in the piece's own proportions", function()
    local _, _, P = server()
    local rb = P.Build("flatrail", { 2 })           -- long and thin footprint
    local nb = P.Build("kicker", { 2 })
    local tgt = { pos = Vector(0, 0, 0), yaw = 0, hl = rb.hl, hw = rb.hw }
    local _, _, side = P.Snap(tgt, Vector(rb.hl * 0.9, rb.hw * 0.2, 0), nb, 0)
    T.eq(side, "front", "near the end")
    _, _, side = P.Snap(tgt, Vector(rb.hl * 0.2, rb.hw * 0.9, 0), nb, 0)
    T.eq(side, "left", "near the side, though far from the middle in units")
    _, _, side = P.Snap(tgt, Vector(-rb.hl * 0.9, 0, 0), nb, 0)
    T.eq(side, "back", "the other end")
    local pos = P.Snap(tgt, Vector(rb.hl * 0.9, 0, 0), nb, 0)
    T.near(pos.x, rb.hl + nb.hl, 1e-9, "centres a half-length each apart")
    T.near(pos.y, 0, 1e-9, "centred on the side")
end)

T.test("park: sliding keeps the aim point's place along the side, in steps of 8, inside the side", function()
    local _, _, P = server()
    local tb, nb = P.Build("funbox", { 2 }), P.Build("kicker", { 2 })
    local tgt = { pos = Vector(0, 0, 0), yaw = 0, hl = tb.hl, hw = tb.hw }
    local pos = P.Snap(tgt, Vector(tb.hl, 29, 0), nb, 0, true)
    T.near(pos.y, 32, 1e-9, "29 rounds to 32")
    T.near(pos.x, tb.hl + nb.hl, 1e-9, "still against the side")
    local _, _, side = P.Snap(tgt, Vector(tb.hl, 9999, 0), nb, 0, true)
    T.eq(side, "left", "a far-left aim is the left side")
    pos = P.Snap(tgt, Vector(tb.hl, tb.hw * 0.99, 0), nb, 0, true)
    T.ok(math.abs(pos.y) <= tb.hw, "never past the end of the side")
end)

T.test("park: placing on the ground turns the piece to the player's quarter turn plus the tool's", function()
    local _, _, P = server()
    local pos, yaw, to = P.Placement({ HitPos = Vector(5, 6, 7), Entity = nil }, "kicker", { 2, 1 },
        { yaw = 100, rot = 90 })
    T.eq(yaw, -180, "100 snaps to 90, plus 90 is 180, wrapped")
    T.eq(pos.x, 5, "where it hit") T.eq(pos.z, 7, "on the floor it hit") T.eq(to, nil, "snapped to nothing")
end)

--------------------------------------------------------------------------
-- Entities, the spawn menu, the cap
--------------------------------------------------------------------------
T.test("park: the spawn menu has a class for every piece, in the BMX Park category, deriving from the entity", function()
    local sv, world = server()
    local cl = F.client(world)
    local P = sv.env.BMX.Park
    local n, names = 0, {}
    for class, c in pairs(P.Classes) do
        n = n + 1
        local t = sv.stored[class]
        T.ok(t, class .. " is registered on the server")
        T.ok(cl.stored[class], class .. " is registered on the client")
        T.eq(t.Category, "BMX Park", class .. " category")
        T.eq(t.Base, "bmx_park_piece", class .. " base")
        T.eq(t.Spawnable, true, class .. " spawnable")
        T.ok(t.PrintName and #t.PrintName > 3, class .. " has a name")
        T.ok(not names[t.PrintName], class .. " has a name of its own: " .. t.PrintName)
        names[t.PrintName] = true
        T.eq(t.ParkShape, c.shape, class .. " shape")
    end
    T.eq(n, 78, "classes")
    T.eq(sv.stored.bmx_park_piece.Spawnable, false, "the base is not itself listed")
end)

T.test("park: a spawned piece is frozen, has one body of the right hulls, and its datatable carries the piece", function()
    local sv, _, P = server()
    local e = sv.env.ents.Create("bmx_park_quarterpipe_v3_l")
    e:SetPos(sv.env.Vector(0, 0, 0))
    e:Spawn()
    T.eq(e:GetShape(), "quarterpipe", "shape")
    T.eq(e:GetParams(), "3,3", "params")
    T.ok(e._phys, "has a body")
    T.eq(#e._phys.boxes, #P.Build("quarterpipe", { 3, 3 }).hulls, "one convex per hull")
    T.eq(e._phys.motion, false, "frozen by default")
    T.eq(#e:GrindLines(), 1, "its coping is tagged")
end)

T.test("park: bmx_park_max is a setting row and a convar, and caps the toolgun, the spawn menu and a load", function()
    local sv, world, P = server()
    local row = sv.env.BMX.Settings.Get("bmx_park_max")
    T.ok(row and row.scope == "server" and row.kind == "int", "a server int row")
    T.ok(world.convars.bmx_park_max, "the convar exists")
    sv.env.GetConVar("bmx_park_max"):SetInt(3)
    for i = 1, 3 do
        T.ok(P.Place(nil, "kicker", { 2, 1 }, sv.env.Vector(i * 300, 0, 0)), "piece " .. i .. " fits")
    end
    local e, why = P.Place(nil, "kicker", { 2, 1 }, sv.env.Vector(0, 900, 0))
    T.eq(e, nil, "the fourth is refused")
    T.ok(why:find("bmx_park_max 3"), "and says why: " .. tostring(why))
    T.eq(P.Count(), 3, "three stand")
    local ply = sv:player("Builder")
    T.eq(sv.env.hook.Run("PlayerSpawnSENT", ply, "bmx_park_bank_m"), false, "the spawn menu is refused too")
    T.eq(sv.env.hook.Run("PlayerSpawnSENT", ply, "bmx_base"), nil, "and a bike is not asked")
    sv.env.GetConVar("bmx_park_max"):SetInt(10)
    T.eq(sv.env.hook.Run("PlayerSpawnSENT", ply, "bmx_park_bank_m"), nil, "room again")
end)

--------------------------------------------------------------------------
-- Saving, loading, permission
--------------------------------------------------------------------------
local function snapshot(P)
    local out = {}
    for _, p in ipairs(P.Snapshot()) do
        out[#out + 1] = string.format("%s|%s|%.4f,%.4f,%.4f|%.4f,%.4f,%.4f", p.shape, p.params,
            p.pos.x, p.pos.y, p.pos.z, p.ang.p, p.ang.y, p.ang.r)
    end
    return out
end

T.test("park: a saved park loads back exactly: shapes, parameters, positions, turns", function()
    local sv, _, P = server()
    local E = sv.env
    P.Place(nil, "quarterpipe", { 3, 2 }, E.Vector(100.5, -20.25, 3), E.Angle(0, 90, 0))
    P.Place(nil, "flatrail", { 1 }, E.Vector(-400, 80, 3), E.Angle(0, -135, 0))
    P.Place(nil, "dirtjump", { 2, 3 }, E.Vector(0, 900, 3), E.Angle(0, 0, 0))
    P.Place(nil, "bowlcorner", { 2, 1 }, E.Vector(700, 700, 3), E.Angle(0, 180, 0))
    local before = snapshot(P)
    T.eq(#before, 4, "four standing")

    local function nfiles() local n = 0 for _ in pairs(sv.files) do n = n + 1 end return n end
    local files0 = nfiles()
    sv:command("bmx_park_save", nil, "my park")          -- a space is not a name
    sv:command("bmx_park_save", nil, "../escape")        -- nor is a path
    sv:command("bmx_park_save", nil)                     -- nor nothing
    T.eq(nfiles(), files0, "a bad name writes nothing")
    sv:command("bmx_park_save", nil, "Plaza_1")
    local path = "bmx/parks/gm_flatgrass/plaza_1.json"
    T.ok(sv.files[path], "saved under data/bmx/parks/<map>/<name>.json (lower-cased)")
    T.ok(sv.world.convars.bmx_park_max, "still configured")

    T.eq(P.Clear(), 4, "cleared")
    T.eq(P.Count(), 0, "empty")
    sv:command("bmx_park_load", nil, "plaza_1")
    T.eq(P.Count(), 4, "loaded")
    local after = snapshot(P)
    for i = 1, 4 do T.eq(after[i], before[i], "piece " .. i) end

    -- again: a load replaces, it does not stack
    sv:command("bmx_park_load", nil, "plaza_1")
    T.eq(P.Count(), 4, "replaced")
    -- and the same park saves the same bytes
    local first = sv.files[path]
    sv:command("bmx_park_save", nil, "plaza_1")
    T.eq(sv.files[path], first, "a stable file")
    -- the one that is not there
    sv:command("bmx_park_load", nil, "nothing")
    T.eq(P.Count(), 4, "a missing park leaves the park alone")
end)

T.test("park: a damaged file loads what it can, clamped, and skips what it cannot", function()
    local sv, _, P = server()
    local path = "bmx/parks/gm_flatgrass/rough.json"
    sv.files[path] = sv.env.util.TableToJSON({ version = 1, pieces = {
        { shape = "kicker", params = { 9, 9 }, pos = { 1, 2, 3 }, ang = { 0, 45, 0 } },
        { shape = "no_such_piece", params = { 1, 1 }, pos = { 0, 0, 0 } },
        { shape = "bank", pos = { "x" } },
        "junk",
    } })
    sv:command("bmx_park_load", nil, "rough")
    T.eq(P.Count(), 1, "one good piece")
    T.eq(P.Snapshot()[1].params, "3,1", "clamped")
    sv.files[path] = "not json at all"
    sv:command("bmx_park_load", nil, "rough")
    T.eq(P.Count(), 1, "not a park: left alone")
end)

T.test("park: building parks is a privilege, admin by default, and everything else about parks is open", function()
    local sv, _, P = server()
    local B = sv.env.BMX
    local found
    for _, p in ipairs(B.Privileges) do if p.name == "BMX - Build Parks" then found = p end end
    T.ok(found, "BMX - Build Parks is registered")
    T.eq(found.min, "admin", "admin by default")
    T.ok(#found.desc > 5, "described")

    local plain, admin = sv:player("Plain"), sv:player("Boss")
    admin._admin = true
    P.Place(nil, "kicker", {}, sv.env.Vector(0, 0, 0))
    sv:command("bmx_park_save", plain, "nope")
    T.eq(sv.files["bmx/parks/gm_flatgrass/nope.json"], nil, "a player cannot save")
    sv:command("bmx_park_clear", plain)
    T.eq(P.Count(), 1, "or clear")
    sv:command("bmx_park_preset", plain, "street_plaza")
    T.eq(P.Count(), 1, "or build a preset")
    sv:command("bmx_park_save", admin, "yes")
    T.ok(sv.files["bmx/parks/gm_flatgrass/yes.json"], "an admin can")
    sv:command("bmx_park_load", plain, "yes")
    T.eq(P.Count(), 1, "a player cannot load")

    -- a CAMI that says yes to this one name lets a plain player build
    sv.env.CAMI = { RegisterPrivilege = function() end,
        PlayerHasAccess = function(ply, priv, cb) cb(priv == "BMX - Build Parks") end }
    sv:command("bmx_park_clear", plain)
    T.eq(P.Count(), 0, "CAMI's answer wins")
end)

--------------------------------------------------------------------------
-- The presets
--------------------------------------------------------------------------
T.test("park: three presets, built from real pieces, none overlapping and none past the default cap", function()
    local sv, _, P = server()
    local cap = sv.env.BMX.Settings.Get("bmx_park_max").default
    T.eq(#P.PresetOrder, 3, "three")
    for _, id in ipairs({ "street_plaza", "vert_ramp", "dirt_line" }) do
        T.ok(P.Presets[id] and P.Presets[id].label and P.Presets[id].help, id .. " is described")
        local layout = P.Layout(id)
        T.ok(#layout >= 6, id .. " is a park: " .. #layout .. " pieces")
        T.ok(#layout <= cap, id .. " fits the default cap: " .. #layout .. " of " .. cap)
        for i, a in ipairs(layout) do
            local ba = P.Build(a.shape, a.params)
            T.ok(ba, id .. " piece " .. i .. " exists")
            for j = i + 1, #layout do
                local b = layout[j]
                local bb = P.Build(b.shape, b.params)
                local o = overlap({ pos = Vector(a.x, a.y, 0), hl = ba.hl, hw = ba.hw }, a.yaw,
                    { pos = Vector(b.x, b.y, 0), hl = bb.hl, hw = bb.hw }, b.yaw)
                T.ok(o <= 1e-6, string.format("%s: %s and %s overlap by %.1f", id, a.shape, b.shape, o))
            end
        end
    end
    T.eq(P.Layout("nope"), nil, "no such preset")
end)

T.test("park: a preset is one command, builds where asked, replaces the park, and stops at the cap", function()
    local sv, _, P = server()
    local E = sv.env
    local layout = P.Layout("street_plaza")
    sv:command("bmx_park_preset", nil, "street_plaza")
    T.eq(P.Count(), #layout, "every piece of the layout")
    -- and it stands round the map's floor, on it
    local lo, hi = math.huge, -math.huge
    for _, p in ipairs(P.Snapshot()) do
        T.near(p.pos.z, sv.world.groundZ, 0.5, "on the floor")
        lo, hi = math.min(lo, p.pos.x), math.max(hi, p.pos.x)
    end
    T.ok(hi - lo > 500, "a spread of pieces")
    sv:command("bmx_park_preset", nil, "vert_ramp")
    T.eq(P.Count(), #P.Layout("vert_ramp"), "another preset replaces the first")
    sv:command("bmx_park_preset", nil, "dirt_line")
    T.eq(P.Count(), #P.Layout("dirt_line"), "and the third")
    -- the cap
    E.GetConVar("bmx_park_max"):SetInt(5)
    local placed, skipped = P.LoadPreset(nil, "street_plaza", E.Vector(0, 0, 0), 0)
    T.eq(placed, 5, "placed up to the cap")
    T.eq(skipped, #layout - 5, "and counted the rest")
    T.eq(P.Count(), 5, "never over it")
    -- a turned preset is the same park, turned
    E.GetConVar("bmx_park_max"):SetInt(120)
    P.LoadPreset(nil, "dirt_line", E.Vector(1000, 2000, 5), 90)
    local first = P.Snapshot()[1]
    local mx, my, n = 0, 0, 0
    for _, p in ipairs(P.Snapshot()) do mx, my, n = mx + p.pos.x, my + p.pos.y, n + 1 end
    T.near(mx / n, 1000, 300, "round the origin it was given: x")
    T.near(my / n, 2000, 300, "round the origin it was given: y")
    -- laid at the origin's height, then settled on the floor under it (bmx_park_ground)
    T.near(first.pos.z, sv.world.groundZ, 1e-6, "settled on the ground")
    sv:command("bmx_park_preset", nil)
    T.eq(P.Count(), #P.Layout("dirt_line"), "no id only lists them")
end)

--------------------------------------------------------------------------
-- The tool
--------------------------------------------------------------------------
T.test("park: the tool places a piece at the aim, snaps to the one it is aimed at, and reload removes it", function()
    local sv, _, P = server()
    local E = sv.env
    local TOOL = sv.tools.bmx_park
    T.ok(TOOL, "the tool loaded")
    T.eq(TOOL.Category, "Construction", "in the construction tab")

    local owner = setmetatable({ _msgs = {} }, { __index = function(_, k)
        if k == "IsValid" then return function() return true end end
        if k == "EyeAngles" then return function() return E.Angle(0, 8, 0) end end
        if k == "ChatPrint" then return function(self, m) self._msgs[#self._msgs + 1] = m end end
        return function() end
    end })
    local cv = { shape = "kicker", size = "2", variant = "1", rot = "0", snap = "1", slide = "0" }
    local tool = setmetatable({
        GetOwner = function() return owner end,
        GetClientInfo = function(_, k) return cv[k] end,
        GetClientNumber = function(_, k, d) return tonumber(cv[k]) or d end,
    }, { __index = TOOL })

    T.ok(tool:LeftClick({ HitPos = E.Vector(500, 100, 9), Entity = E.NULL }), "a click on the ground places")
    local a = P.All()[1]
    T.eq(P.Count(), 1, "one piece")
    T.near(a:GetPos().x, 500, 1e-6, "at the aim") T.near(a:GetPos().z, sv.world.groundZ, 1e-6, "settled on the floor")
    -- bmx_park_ground 0: where it is put, even off the floor
    E.GetConVar("bmx_park_ground"):SetInt(0)
    T.ok(tool:LeftClick({ HitPos = E.Vector(-900, 100, 9), Entity = E.NULL }), "a second piece")
    local hover
    for _, e in ipairs(P.All()) do if e ~= a then hover = e end end
    T.near(hover:GetPos().z, 9, 1e-6, "left where it was put")
    hover:Remove()
    E.GetConVar("bmx_park_ground"):SetInt(1)
    T.near(a:GetAngles().y, 0, 1e-6, "turned to the nearest quarter of the player's 8 degrees")
    T.eq(a._phys.motion, false, "frozen")

    cv.shape = "bank"
    T.ok(tool:LeftClick({ HitPos = a:GetPos() + E.Vector(60, 0, 5), Entity = a }), "a click on a piece snaps")
    local ba, bb = P.Build("kicker", { 2, 1 }), P.Build("bank", { 2, 1 })
    local b
    for _, e in ipairs(P.All()) do if e ~= a then b = e end end
    T.near(b:GetPos().x - a:GetPos().x, ba.hl + bb.hl, 1e-6, "edge to edge, on its front")
    T.near(b:GetPos().y, a:GetPos().y, 1e-6, "centred")

    cv.shape = "no_such"
    T.eq(tool:LeftClick({ HitPos = E.Vector(0, 0, 0), Entity = E.NULL }), false, "an unknown piece places nothing")
    cv.shape = "kicker"

    E.GetConVar("bmx_park_max"):SetInt(2)
    T.eq(tool:LeftClick({ HitPos = E.Vector(0, 900, 0), Entity = E.NULL }), false, "refused at the cap")
    T.ok(owner._msgs[#owner._msgs]:find("bmx_park_max 2"), "and the player is told")

    T.ok(tool:Reload({ Entity = b }), "reload removes a piece")
    T.ok(b._removed, "gone")
    T.eq(tool:Reload({ Entity = E.NULL }), false, "and nothing else")
end)

T.test("park: the headless suite has a case on a park quarter pipe and one on a park rail", function()
    local sv = F.server()
    local S = sv.env.BMX.Test
    for _, name in ipairs({ "park_quarterpipe_ride_up", "park_flat_rail_grind" }) do
        T.ok(S.cases[name], name .. " is registered")
        T.eq(S.cases[name].bike, "stock", name .. " rides the stock bike")
    end
end)

T.test("park: the client draws every piece from the same build: triangles, finite, in the pieces' bounds", function()
    local sv, world = F.server()
    local cl = F.client(world)
    local P = cl.env.BMX.Park
    T.ok(P.Triangles and P.Draw and P.MeshFor, "cl_park defines the drawing")
    local b = P.Build("quarterpipe", { 2, 2 })
    -- Triangles needs the engine's vector methods (Cross, Dot); the shim has them
    local tris = P.Triangles(b)
    local want = 0
    for _, f in ipairs(b.faces) do want = want + (#f.pts - 2) end
    T.eq(#tris, want * 3, "a fan of triangles per face")
    for _, v in ipairs(tris) do
        T.finite(v[1], "vertex")
        T.ok(v[2] >= 0 and v[2] <= 255 and v[3] >= 0 and v[3] <= 255 and v[4] >= 0 and v[4] <= 255, "colour in range")
    end
end)
