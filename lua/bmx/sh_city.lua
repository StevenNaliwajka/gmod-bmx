--[[--------------------------------------------------------------------------
    bmx/sh_city.lua

    The city around the park: buildings on every side instead of a bare wall,
    rising into a skyline, with elevated subway viaducts crossing overhead and
    trains running over them.

    WHY IT IS BUILT IN LUA AND NOT IN HAMMER. The park maps are somebody else's
    BSPs (gm_skatepark is a Workshop map), and a map cannot be edited without
    decompiling, recompiling and redistributing it. Everything here is drawn and
    collided from the addon instead, from a per-map DEFINITION (see
    sh_city_maps.lua), so "make the world bigger" is editing a table.

    HOW A WHOLE CITY FITS AROUND A SEALED BOX MAP. gm_skatepark is one box: a
    brick wall to z=528 and toolsskybox above it. Sky faces are not drawn as
    geometry -- the sky shows through where nothing else wrote -- so geometry
    OUTSIDE the box is visible from inside it as long as somebody draws it.
    The engine will not (entities out in the void have no visleaf), so
    cl_city.lua draws the meshes itself, from a render hook.

    So the frontage stands on the wall line, its facade a few units inside the
    park so it covers the brick, and every building's body lies out in the
    void. Nothing out there can be reached -- the wall and the sky brushes are
    solid -- so the buildings need no collision at all. The parts that ARE
    inside the box (the viaducts and the piers that hold them up) are made solid
    by bmx_city_solid entities, server and client both.

    DETERMINISM. Layout is generated from a seed with a private generator (never
    math.random), so the server's colliders, every client's meshes and the
    offline tests all build the same city, every session.

    OUTPUT. BMX.City.Build(def) returns plain numbers, not Vectors, so it runs
    as fast in the test shim as in the game:
        layout.faces[mat]  = { {x1,y1,z1, x2,y2,z2, x3,y3,z3, x4,y4,z4,
                                u1,v1, u2,v2, shade, group}, ... }   (quads, TL TR BR BL)
                             group: which part of the city ("via:line1",
                             "front:north", "sky:3"...), so the client can
                             draw near parts first and skip ones out of view
        layout.solids      = { {name, {x0,y0,z0, x1,y1,z1}, ...}, ... }
        layout.lines       = subway lines the trains run on
        layout.signs       = text panels
        layout.buildings   = the boxes, for tests and bmx_city_info
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.City = BMX.City or {}
local City = BMX.City

City.Maps = City.Maps or {}

-- 1 texel = 0.25 units, the scale HL2 itself lays building_template at, which
-- makes one 512-pixel panel one 128-unit floor: a Source storey.
City.FLOOR = 128

--------------------------------------------------------------------------
-- Materials. Every surface the city can use, with the size in world units of
-- one repeat of its texture. `alpha` materials are alpha-tested (the truss
-- panels are mostly holes). cl_city.lua turns each into an UnlitGeneric copy:
-- the HL2 originals are LightmappedGeneric, which has no lightmap on a mesh.
--------------------------------------------------------------------------
local function bt(id, w, h) return { tex = "building_template/building_template" .. id, w = w or 128, h = h or 128 } end

City.Materials = {
    -- brick
    brick_plain = bt("001a"), brick_win = bt("001b"), brick_board = bt("001d"),
    brick_door = bt("001h"), brick_trim = bt("001k", 128, 32),
    -- white stone
    white_plain = bt("002a"), white_win = bt("002b"), white_win2 = bt("002c"),
    white_door = bt("002e"), white_win3 = bt("002n"), white_trim = bt("002k", 128, 32),
    white_niche = bt("002f"),
    -- grey stone
    grey_plain = bt("003a"), grey_win = bt("003d"), grey_win2 = bt("003e"),
    grey_arch = bt("003o"), grey_shop = bt("003j"), grey_trim = bt("003i", 128, 32),
    -- pediments
    ped_plain = bt("004a"), ped_win = bt("004b"), ped_win2 = bt("004d"),
    ped_shutter = bt("004c"), ped_trim = bt("004f", 128, 32),
    -- yellow render
    yel_plain = bt("005a"), yel_arch = bt("005b"), yel_win = bt("005l"),
    yel_arch2 = bt("005j"), yel_trim = bt("005g", 128, 32),
    olive_win = bt("005c"), olive_win2 = bt("005d"),
    -- modern
    glass_grey = bt("006a"), glass_dark = bt("006b"), conc_plain = bt("007a"),
    conc_ribbon = bt("007b"), conc_ribbon2 = bt("007c"), conc_ribbon3 = bt("007h"),
    conc_shop = bt("010b"), conc_shop2 = bt("010c"), glass_black = bt("009e"),
    -- red brick
    red_plain = bt("010h"), red_arch = bt("010i"), red_arch2 = bt("011b"),
    red_shutter = bt("011c", 128, 128),
    -- ochre
    ochre_plain = bt("012a"), ochre_win = bt("012b"), ochre_win2 = bt("012g"),
    ochre_win3 = bt("012h"), ochre_door = bt("012l"),
    -- tan classical
    tan_plain = bt("013a"), tan_win = bt("013b"), tan_win2 = bt("013c"),
    tan_door = bt("013g"), tan_arch = bt("013f"),
    -- dark render, big windows
    dark_plain = bt("021a"), dark_win = bt("021c"), dark_win2 = bt("021b"),
    dark_win3 = bt("021h"),
    cream_plain = bt("022a"), cream_win = bt("022c"), cream_win2 = bt("022b"),
    cream_ribbon = bt("022g"),
    -- stone classical
    stone_plain = bt("029a"), stone_win = bt("029b"), stone_arch = bt("029d"),
    stone_tall = bt("029f"), stone_door = bt("028d"), stone_trim = bt("029i", 128, 32),

    -- roofs and structure
    roof = { tex = "building_template/roof_template001a", w = 256, h = 256 },
    roof2 = { tex = "building_template/roof_template001b", w = 256, h = 256 },
    concrete = { tex = "concrete/concretewall022a", w = 128, h = 128 },
    concrete2 = { tex = "concrete/concretewall010a", w = 128, h = 128 },
    steel = { tex = "metal/metalwall048a", w = 128, h = 128 },
    girder = { tex = "metal/metaltruss015a", w = 256, h = 64, alpha = true },
    truss = { tex = "metal/metaltruss011a", w = 224, h = 224, alpha = true },
    grate = { tex = "metal/metalgrate016a", w = 128, h = 128, alpha = true },
    black = { tex = "vgui/white", w = 128, h = 128, color = { 0.02, 0.02, 0.025 } },
    signpanel = { tex = "vgui/white", w = 128, h = 128, color = { 0.07, 0.08, 0.1 } },
}

--------------------------------------------------------------------------
-- Building styles: what goes on the street floor, the floors above, and the
-- cornice. `win` lists window panels; a building picks one as its main panel
-- and may pick a second as an accent column.
--------------------------------------------------------------------------
City.Styles = {
    brick  = { ground = { "brick_door", "brick_board" }, win = { "brick_win" },
               plain = "brick_plain", trim = "brick_trim" },
    white  = { ground = { "white_door", "white_niche", "white_plain" }, win = { "white_win", "white_win2", "white_win3" },
               plain = "white_plain", trim = "white_trim" },
    grey   = { ground = { "grey_shop", "grey_arch" }, win = { "grey_win", "grey_win2" },
               plain = "grey_plain", trim = "grey_trim" },
    ped    = { ground = { "stone_door", "ped_shutter" }, win = { "ped_win", "ped_win2", "ped_shutter" },
               plain = "ped_plain", trim = "ped_trim" },
    yellow = { ground = { "ochre_door", "yel_arch2" }, win = { "yel_win", "yel_arch", "olive_win" },
               plain = "yel_plain", trim = "yel_trim" },
    ochre  = { ground = { "ochre_door", "ochre_win2" }, win = { "ochre_win", "ochre_win2", "ochre_win3" },
               plain = "ochre_plain", trim = "yel_trim" },
    tan    = { ground = { "tan_door", "tan_arch" }, win = { "tan_win", "tan_win2" },
               plain = "tan_plain", trim = "grey_trim" },
    red    = { ground = { "red_shutter", "red_arch2" }, win = { "red_arch" },
               plain = "red_plain", trim = "brick_trim" },
    stone  = { ground = { "stone_door", "stone_arch" }, win = { "stone_win", "stone_tall" },
               plain = "stone_plain", trim = "stone_trim" },
    dark   = { ground = { "conc_shop", "conc_shop2" }, win = { "dark_win", "dark_win2", "dark_win3" },
               plain = "dark_plain", trim = "grey_trim" },
    cream  = { ground = { "conc_shop2", "conc_shop" }, win = { "cream_win", "cream_win2", "cream_ribbon" },
               plain = "cream_plain", trim = "white_trim" },
    office = { ground = { "conc_shop", "conc_shop2" }, win = { "conc_ribbon", "conc_ribbon2", "conc_ribbon3" },
               plain = "conc_plain", trim = "grey_trim" },
    glass  = { ground = { "conc_shop2", "conc_shop" }, win = { "glass_grey", "glass_dark", "glass_black" },
               plain = "conc_plain", trim = "grey_trim" },
}

--------------------------------------------------------------------------
-- A seeded generator: Park-Miller minimal standard. Exact in doubles
-- (16807 * 2^31 < 2^53), so every realm and the test shim agree bit for bit.
--------------------------------------------------------------------------
local function Rng(seed)
    local s = math.floor(seed) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    local r = {}
    function r.float() s = (s * 16807) % 2147483647 return (s - 1) / 2147483646 end
    function r.int(a, b) return a + math.floor(r.float() * (b - a + 1)) end
    function r.pick(t) return t[r.int(1, #t)] end
    function r.chance(p) return r.float() < p end
    return r
end
City.Rng = Rng

--------------------------------------------------------------------------
-- The builder.
--------------------------------------------------------------------------
local B = {}
B.__index = B

local function newBuilder(def)
    local b = setmetatable({ def = def, faces = {}, solids = {}, lines = {}, signs = {},
                             buildings = {}, quads = 0 }, B)
    local v = def.view or def.park
    b.view = { v[1], v[2], v[3], v[4], v[5], v[6] }
    -- The sun, from the map's light_environment: shading is baked into vertex
    -- colour, so a face turned to the sun is lit and the far sides are not.
    local p, y = math.rad(def.sunPitch or 30), math.rad(def.sunYaw or 0)
    b.sun = { math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p) }
    return b
end

-- Is any point of the viewing volume in front of this plane? A face nobody
-- inside the park can ever see the front of is never emitted: the backs of
-- buildings, the floors, the far sides of piers.
function B:facing(px, py, pz, nx, ny, nz)
    local v = self.view
    local mx = nx > 0 and v[4] or v[1]
    local my = ny > 0 and v[5] or v[2]
    local mz = nz > 0 and v[6] or v[3]
    return (mx - px) * nx + (my - py) * ny + (mz - pz) * nz > 0.5
end

function B:shade(nx, ny, nz, tint)
    local s = self.sun
    local d = nx * s[1] + ny * s[2] + nz * s[3]
    local k
    if nz > 0.5 then k = 1.0
    elseif nz < -0.5 then k = 0.42
    else k = 0.68 + 0.3 * math.max(d, 0) - 0.06 * math.max(-d, 0) end
    return k * (tint or 1)
end

-- One quad from its top-left corner `o`, a unit right axis `u` and a unit down
-- axis `w`, `len` along u and `hgt` along w. Texture coordinates are in
-- repeats of the material's size, offset by (u0, v0) units, so panels line up
-- across seams.
function B:quad(mat, o, u, w, len, hgt, n, tint, u0, v0, cull)
    if len <= 0.01 or hgt <= 0.01 then return end
    if cull ~= false and not self:facing(o[1], o[2], o[3], n[1], n[2], n[3]) then return end
    local M = City.Materials[mat]
    if not M then error("BMX city: no material " .. tostring(mat), 2) end
    local list = self.faces[mat]
    if not list then list = {} self.faces[mat] = list end
    local x1, y1, z1 = o[1], o[2], o[3]
    local x2, y2, z2 = x1 + u[1] * len, y1 + u[2] * len, z1 + u[3] * len
    local x4, y4, z4 = x1 + w[1] * hgt, y1 + w[2] * hgt, z1 + w[3] * hgt
    local x3, y3, z3 = x2 + w[1] * hgt, y2 + w[2] * hgt, z2 + w[3] * hgt
    u0, v0 = u0 or 0, v0 or 0
    list[#list + 1] = { x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4,
        u0 / M.w, v0 / M.h, (u0 + len) / M.w, (v0 + hgt) / M.h,
        self:shade(n[1], n[2], n[3], tint), self.group or "misc" }
    self.quads = self.quads + 1
end

-- The four vertical faces of an axis-aligned box, as {origin(top-left), right,
-- normal, length}. Right is (-n) x up: the viewer's right looking at the face.
local function sides(x0, y0, x1, y1, z)
    return {
        { o = { x0, y0, z }, u = { 1, 0, 0 },  n = { 0, -1, 0 }, len = x1 - x0 },  -- -y face
        { o = { x1, y1, z }, u = { -1, 0, 0 }, n = { 0, 1, 0 },  len = x1 - x0 },  -- +y face
        { o = { x0, y1, z }, u = { 0, -1, 0 }, n = { -1, 0, 0 }, len = y1 - y0 },  -- -x face
        { o = { x1, y0, z }, u = { 0, 1, 0 },  n = { 1, 0, 0 },  len = y1 - y0 },  -- +x face
    }
end
City.Sides = sides

local DOWN = { 0, 0, -1 }

-- A plain box: every visible face in one material (or {side=, top=, bottom=}).
function B:box(x0, y0, z0, x1, y1, z1, mats, tint)
    if type(mats) == "string" then mats = { side = mats, top = mats, bottom = mats } end
    for _, s in ipairs(sides(x0, y0, x1, y1, z1)) do
        self:quad(mats.side, s.o, s.u, DOWN, s.len, z1 - z0, s.n, tint, 0, 0)
    end
    if mats.top then
        self:quad(mats.top, { x0, y1, z1 }, { 1, 0, 0 }, { 0, -1, 0 }, x1 - x0, y1 - y0, { 0, 0, 1 }, tint)
    end
    if mats.bottom then
        self:quad(mats.bottom, { x0, y0, z0 }, { 1, 0, 0 }, { 0, 1, 0 }, x1 - x0, y1 - y0, { 0, 0, -1 }, tint)
    end
end

function B:solid(name, x0, y0, z0, x1, y1, z1)
    local s = self.solids[name]
    if not s then s = { name = name, boxes = {} } self.solids[name] = s self.solids[#self.solids + 1] = s end
    s.boxes[#s.boxes + 1] = { x0, y0, z0, x1, y1, z1 }
end

--------------------------------------------------------------------------
-- A facade: one vertical face of a building, in floors of City.FLOOR.
--
--   street floor   the style's ground panels, a door every few bays
--   upper floors   one window panel, with an optional accent column
--   cornice        a trim band that sticks out, with a dark underside
--
-- `fromZ` skips everything below it: a side face hidden by the neighbour
-- beside it starts at the neighbour's roof, so its hidden part is never drawn.
--------------------------------------------------------------------------
function B:facade(s, z0, z1, style, pick, tint, fromZ, street)
    local F = City.FLOOR
    local n = s.n
    if not self:facing(s.o[1], s.o[2], s.o[3], n[1], n[2], n[3]) then return end
    local bays = math.floor(s.len / F)
    local margin = (s.len - bays * F) / 2

    local function at(along, z)
        return { s.o[1] + s.u[1] * along, s.o[2] + s.u[2] * along, z }
    end

    -- The edge strips that don't make a whole bay are plain wall.
    local floors = math.floor((z1 - z0) / F + 0.001)
    local top = z0 + floors * F
    local startZ = math.max(z0, fromZ or z0)
    if margin > 0.5 and top > startZ then
        self:quad(style.plain, at(0, top), s.u, DOWN, margin, top - startZ, n, tint, 0, 0)
        self:quad(style.plain, at(s.len - margin, top), s.u, DOWN, margin, top - startZ, n, tint, 0, 0)
    end
    if z1 - top > 0.5 then
        self:quad(style.plain, at(0, z1), s.u, DOWN, s.len, z1 - top, n, tint, 0, 0)
    end

    for f = 0, floors - 1 do
        local zb = z0 + f * F
        local zt = zb + F
        if zt > startZ + 0.5 then
            local h = zt - math.max(zb, startZ)
            -- Merge runs of the same panel into one quad: the panels tile
            -- sideways, so a run is one quad with the texture repeated.
            local runMat, runStart, runLen = nil, 0, 0
            local function flush()
                if runMat then
                    self:quad(runMat, at(margin + runStart, zt), s.u, DOWN, runLen, h, n, tint, 0, 0)
                end
            end
            for i = 0, bays - 1 do
                local m
                if f == 0 and street then m = pick.ground(i) else m = pick.upper(i, f) end
                if m == runMat then
                    runLen = runLen + F
                else
                    flush()
                    runMat, runStart, runLen = m, i * F, F
                end
            end
            flush()
        end
    end
end

-- The cornice: a 32-unit trim band proud of the face, along its whole length.
function B:cornice(s, z, style, tint, depth)
    depth = depth or 8
    local n = s.n
    local o = { s.o[1] + n[1] * depth - s.u[1] * depth, s.o[2] + n[2] * depth - s.u[2] * depth, z }
    local len = s.len + depth * 2
    self:quad(style.trim, o, s.u, DOWN, len, 32, n, tint, 0, 0)
    -- underside: the shadow line that makes it read as a ledge from below
    local under = { o[1], o[2], z - 32 }
    self:quad(style.plain, under, s.u, { -n[1], -n[2], 0 }, len, depth, { 0, 0, -1 }, tint * 0.7, 0, 0)
end

--------------------------------------------------------------------------
-- One building: a box with facades, a roof and a cornice, plus an optional
-- setback tower on top.
--------------------------------------------------------------------------
function B:building(bd, rng)
    local style = City.Styles[bd.style] or City.Styles.brick
    local tint = bd.tint or 1
    local main = bd.win or rng.pick(style.win)
    local accent = rng.chance(0.4) and rng.pick(style.win) or nil
    local accentEvery = rng.int(3, 5)
    local doorAt = rng.int(0, 2)
    local doorMat, shopMat = style.ground[1], style.ground[2] or style.ground[1]
    local pick = {
        ground = function(i) if (i % 4) == doorAt then return doorMat end return shopMat end,
        upper = function(i, f)
            if accent and (i % accentEvery) == 0 then return accent end
            return main
        end,
    }
    local x0, y0, z0, x1, y1, z1 = bd[1], bd[2], bd[3], bd[4], bd[5], bd[6]
    for _, s in ipairs(sides(x0, y0, x1, y1, z1)) do
        local fromZ = bd.hidden and bd.hidden[s.n[1] .. "," .. s.n[2]] or nil
        self:facade(s, z0, z1, style, pick, tint, fromZ, bd.street)
        if bd.cornice ~= false then self:cornice(s, z1, style, tint) end
    end
    self:quad(bd.roof or "roof", { x0, y1, z1 }, { 1, 0, 0 }, { 0, -1, 0 }, x1 - x0, y1 - y0, { 0, 0, 1 }, tint)
    self.buildings[#self.buildings + 1] = bd
end

--------------------------------------------------------------------------
-- The frontage: the row of buildings standing on the park's wall, side by
-- side, their facades just inside it.
--
-- A side is { axis = "x"|"y", at = wall coordinate, out = +1|-1 (away from the
-- park), from, to (along the wall) }.
--------------------------------------------------------------------------
local function toBox(side, a0, a1, near, far, z0, z1)
    -- near/far: distances OUTWARD from the wall line (near may be negative:
    -- inside the park by that much)
    local n0, n1 = side.at + side.out * near, side.at + side.out * far
    local lo, hi = math.min(n0, n1), math.max(n0, n1)
    if side.axis == "x" then
        -- the wall runs along x (a north/south wall at y = at)
        return { a0, lo, z0, a1, hi, z1 }
    else
        return { lo, a0, z0, hi, a1, z1 }
    end
end

-- Cut a length into lots of whole bays.
local function lots(rng, from, to, minW, maxW)
    local F = City.FLOOR
    local out, a = {}, from
    while to - a > 0.5 do
        local w = rng.int(minW / F, maxW / F) * F
        if to - (a + w) < minW then w = to - a end
        out[#out + 1] = { a, a + w }
        a = a + w
    end
    return out
end
City.Lots = lots

function B:row(side, rowDef, rng, mustCover)
    local F = City.FLOOR
    local ground = self.def.ground
    local list = lots(rng, side.from, side.to, rowDef.minWidth, rowDef.maxWidth)
    local built = {}
    for i, lot in ipairs(list) do
        local floors = rng.int(rowDef.minFloors, rowDef.maxFloors)
        local setback = (rowDef.offset or 0) + (rowDef.jitter and rng.int(0, rowDef.jitter / 16) * 16 or 0)
        local depth = rng.int(rowDef.minDepth / F, rowDef.maxDepth / F) * F
        local z1 = ground + floors * F
        -- a lot a viaduct runs into must be tall enough to swallow its portal
        for _, need in ipairs(mustCover or {}) do
            if need.side == side and lot[1] < need.a1 and lot[2] > need.a0 then
                z1 = math.max(z1, math.ceil((need.z - ground) / F + 2) * F + ground)
            end
        end
        local style = rowDef.styles[rng.int(1, #rowDef.styles)]
        local tint = 0.9 + rng.float() * 0.16
        local bd = toBox(side, lot[1], lot[2], -(rowDef.inset or 0) + setback, depth + setback, rowDef.base or ground, z1)
        bd.style, bd.tint, bd.street = style, tint, rowDef.street ~= false
        bd.side, bd.lot = side.name, lot
        built[#built + 1] = bd

        -- A setback tower: narrower, set further back, rising from the roof.
        if rowDef.towerChance and rng.chance(rowDef.towerChance) and (lot[2] - lot[1]) >= 3 * F then
            local tfloors = rng.int(rowDef.towerMin or 3, rowDef.towerMax or 8)
            local inA = F * rng.int(0, 1)
            local back = F * rng.int(1, 2)
            local tb = toBox(side, lot[1] + inA, lot[2] - inA, -(rowDef.inset or 0) + setback + back,
                depth + setback, z1, z1 + tfloors * F)
            tb.style, tb.tint, tb.street = rng.chance(0.5) and style or rowDef.styles[rng.int(1, #rowDef.styles)], tint, false
            tb.side, tb.lot = side.name, { lot[1] + inA, lot[2] - inA }
            bd.tower = tb
        end
    end

    -- A side face is hidden up to the neighbour's roof when the neighbour sits
    -- flush beside it. Record that, so the hidden part is never drawn.
    for i, bd in ipairs(built) do
        bd.hidden = {}
        local function hide(nb, key)
            if nb and math.abs((nb[side.axis == "x" and 2 or 1]) - (bd[side.axis == "x" and 2 or 1])) < 1 then
                bd.hidden[key] = nb[6]
            end
        end
        if side.axis == "x" then
            hide(built[i - 1], "-1,0") hide(built[i + 1], "1,0")
        else
            hide(built[i - 1], "0,-1") hide(built[i + 1], "0,1")
        end
    end
    for _, bd in ipairs(built) do
        self:building(bd, rng)
        if bd.tower then self:building(bd.tower, rng) end
    end
    return built
end

--------------------------------------------------------------------------
-- The skyline: free-standing towers further out, all around.
--------------------------------------------------------------------------
function B:skyline(sk, rng)
    local F = City.FLOOR
    local p = self.def.park
    local cx, cy = (p[1] + p[4]) / 2, (p[2] + p[5]) / 2
    local placed = {}
    local tries = 0
    while #placed < sk.count and tries < sk.count * 30 do
        tries = tries + 1
        local w = rng.int(sk.minWidth / F, sk.maxWidth / F) * F
        local d = rng.int(sk.minWidth / F, sk.maxWidth / F) * F
        local ang = rng.float() * math.pi * 2
        local r = sk.minDist + rng.float() * (sk.maxDist - sk.minDist)
        -- distance is from the park's EDGE, so the ring hugs the rectangle
        local hx, hy = (p[4] - p[1]) / 2, (p[5] - p[2]) / 2
        local x = cx + math.cos(ang) * (hx + r)
        local y = cy + math.sin(ang) * (hy + r)
        x = math.floor(x / F) * F
        y = math.floor(y / F) * F
        local bx = { x, y, self.def.ground, x + w, y + d, 0 }
        local ok = true
        for _, o in ipairs(placed) do
            if bx[1] < o[4] + F and bx[4] > o[1] - F and bx[2] < o[5] + F and bx[5] > o[2] - F then ok = false break end
        end
        -- never inside the inner rows
        local m = sk.clear
        if bx[1] < p[4] + m and bx[4] > p[1] - m and bx[2] < p[5] + m and bx[5] > p[2] - m then ok = false end
        if ok then
            local floors = rng.int(sk.minFloors, sk.maxFloors)
            bx[6] = self.def.ground + floors * F
            bx.style = sk.styles[rng.int(1, #sk.styles)]
            bx.tint = 0.86 + rng.float() * 0.14
            bx.street = false
            bx.cornice = rng.chance(0.6)
            bx.side = "skyline"
            -- eight sectors round the park, for the client's culling
            local sector = math.floor(((math.atan2(y - cy, x - cx) + math.pi) / (2 * math.pi)) * 8) % 8
            self.group = "sky:" .. sector
            placed[#placed + 1] = bx
            self:building(bx, rng)
            -- a crown on some: a smaller block and a mast
            if rng.chance(sk.crownChance or 0.4) then
                local i = F
                local cb = { bx[1] + i, bx[2] + i, bx[6], bx[4] - i, bx[5] - i, bx[6] + F * rng.int(2, 4) }
                if cb[4] > cb[1] and cb[5] > cb[2] then
                    cb.style, cb.tint, cb.street, cb.side = bx.style, bx.tint, false, "skyline"
                    self:building(cb, rng)
                    local mx, my = (cb[1] + cb[4]) / 2, (cb[2] + cb[5]) / 2
                    self:box(mx - 8, my - 8, cb[6], mx + 8, my + 8, cb[6] + rng.int(4, 9) * 64, "steel", 0.8)
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- An elevated subway viaduct: a steel through-truss, deck and track, crossing
-- the park from one facade to the other, with a portal where it enters each
-- building.
--
--   { axis = "y", at = 1400, from = -1792, to = 768, deck = 1000 }
--
-- The line runs along `axis` at `at` on the other axis; `deck` is the top of
-- the deck. Train cars run on it (see cl_city.lua), and the deck, girders and
-- truss walls are solid.
--------------------------------------------------------------------------
City.Viaduct = {
    width = 192,      -- outside of the truss walls
    slab = 40,        -- deck thickness
    girder = 64,      -- plate girders under the deck edges
    truss = 224,      -- truss wall height above the deck
    rail = 6,         -- rail head above the deck
    gauge = 56,       -- rail centres
}

-- local frame helpers: a = along the line, c = across it
local function lineBox(v, a0, a1, c0, c1, z0, z1)
    if v.axis == "y" then return v.at + c0, a0, z0, v.at + c1, a1, z1 end
    return a0, v.at + c0, z0, a1, v.at + c1, z1
end

function B:viaduct(v, name)
    local V = City.Viaduct
    local hw = V.width / 2
    local a0, a1 = v.from, v.to
    local deck = v.deck
    local bot = deck - V.slab
    local gb = bot - V.girder

    -- deck slab: concrete edges, steel plate underneath
    local x0, y0, z0, x1, y1, z1 = lineBox(v, a0, a1, -hw, hw, bot, deck)
    self:box(x0, y0, z0, x1, y1, z1, { side = "concrete", top = "steel", bottom = "steel" }, 0.95)
    -- the plate girders, one under each edge
    for _, c in ipairs({ -hw, hw - 12 }) do
        x0, y0, z0, x1, y1, z1 = lineBox(v, a0, a1, c, c + 12, gb, bot)
        self:box(x0, y0, z0, x1, y1, z1, { side = "girder", bottom = "steel" }, 0.85)
    end
    -- cross beams under the deck every 256
    for a = a0 + 128, a1 - 64, 256 do
        x0, y0, z0, x1, y1, z1 = lineBox(v, a - 8, a + 8, -hw + 12, hw - 12, gb + 16, bot)
        self:box(x0, y0, z0, x1, y1, z1, "steel", 0.7)
    end
    -- rails
    for _, c in ipairs({ -V.gauge / 2, V.gauge / 2 }) do
        x0, y0, z0, x1, y1, z1 = lineBox(v, a0, a1, c - 2, c + 2, deck, deck + V.rail)
        self:box(x0, y0, z0, x1, y1, z1, { side = "steel", top = "steel" }, 1.1)
    end
    -- truss walls: alpha-tested panels, both faces, so the train shows
    -- through the holes from below and from either side
    local tz = deck + V.truss
    for _, c in ipairs({ -hw, hw }) do
        local len = a1 - a0
        if v.axis == "y" then
            self:quad("truss", { v.at + c, a0, tz }, { 0, 1, 0 }, DOWN, len, V.truss, { 1, 0, 0 }, 0.9, 0, 0, false)
            self:quad("truss", { v.at + c, a1, tz }, { 0, -1, 0 }, DOWN, len, V.truss, { -1, 0, 0 }, 0.9, 0, 0, false)
        else
            self:quad("truss", { a1, v.at + c, tz }, { -1, 0, 0 }, DOWN, len, V.truss, { 0, 1, 0 }, 0.9, 0, 0, false)
            self:quad("truss", { a0, v.at + c, tz }, { 1, 0, 0 }, DOWN, len, V.truss, { 0, -1, 0 }, 0.9, 0, 0, false)
        end
        -- top chord
        local cc = c > 0 and c - 16 or c
        x0, y0, z0, x1, y1, z1 = lineBox(v, a0, a1, cc, cc + 16, tz, tz + 16)
        self:box(x0, y0, z0, x1, y1, z1, { side = "steel", top = "steel", bottom = "steel" }, 0.8)
    end
    -- top bracing across, one per panel
    for a = a0 + V.truss, a1 - 1, V.truss do
        x0, y0, z0, x1, y1, z1 = lineBox(v, a - 6, a + 6, -hw, hw, tz + 2, tz + 14)
        self:box(x0, y0, z0, x1, y1, z1, "steel", 0.75)
    end

    -- Portals: a dark opening with a concrete frame where the line enters
    -- each building. The facade stands `inset` inside the wall, so these stand
    -- a little further in again. The train, once past it, is behind the
    -- facade and simply gone.
    local inset = (self.def.frontage and self.def.frontage.inset or 4) + 2
    local ph0, ph1 = gb - 24, tz + 40
    for _, endA in ipairs({ { a0, 1 }, { a1, -1 } }) do
        local a, dir = endA[1], endA[2]
        local face = a + dir * inset
        local n
        if v.axis == "y" then n = { 0, dir, 0 } else n = { dir, 0, 0 } end
        -- opening
        local W = V.width + 48
        local o, u
        if v.axis == "y" then
            o = { v.at - W / 2 * dir, face, ph1 } u = { dir, 0, 0 }
        else
            o = { face, v.at + W / 2 * dir, ph1 } u = { 0, -dir, 0 }
        end
        self:quad("black", o, u, DOWN, W, ph1 - ph0, n, 1, 0, 0, false)
        -- frame: lintel and two jambs, proud of the opening
        local fr = 24
        local function frame(ca, cb, za, zb)
            local fa, fb = face, face + dir * fr
            local bx0, by0, bz0, bx1, by1, bz1 = lineBox(v, math.min(fa, fb), math.max(fa, fb), ca, cb, za, zb)
            self:box(bx0, by0, bz0, bx1, by1, bz1, { side = "concrete2", top = "concrete2", bottom = "concrete2" }, 0.9)
        end
        frame(-W / 2 - fr, W / 2 + fr, ph1, ph1 + fr)
        frame(-W / 2 - fr, -W / 2, ph0 - fr, ph1)
        frame(W / 2, W / 2 + fr, ph0 - fr, ph1)
        frame(-W / 2 - fr, W / 2 + fr, ph0 - fr, ph0)
    end

    -- Solid: deck + girders as one slab, and the truss walls.
    x0, y0, z0, x1, y1, z1 = lineBox(v, a0, a1, -hw, hw, gb, deck)
    self:solid(name, x0, y0, z0, x1, y1, z1)
    for _, c in ipairs({ -hw, hw - 8 }) do
        x0, y0, z0, x1, y1, z1 = lineBox(v, a0, a1, c, c + 8, deck, tz + 16)
        self:solid(name, x0, y0, z0, x1, y1, z1)
    end

    self.lines[#self.lines + 1] = {
        name = name, axis = v.axis, at = v.at, from = a0, to = a1, deck = deck,
        period = v.period or 45, offset = v.offset or 0, cars = v.cars or 3,
        speed = v.speed or 1100, runout = v.runout or 1600,
    }
end

-- A pier: a concrete column from the park floor to the underside of a
-- viaduct, with a cap. Solid, because it stands where riders ride.
function B:pier(p, name)
    local h = (p.size or 96) / 2
    local x, y = p.x, p.y
    local z0, z1 = self.def.ground, p.top
    self:box(x - h, y - h, z0, x + h, y + h, z1 - 32, { side = "concrete", top = "concrete" }, 1)
    self:box(x - h - 24, y - h - 24, z1 - 32, x + h + 24, y + h + 24, z1, "concrete2", 0.95)
    -- a kerb plinth at the foot
    self:box(x - h - 8, y - h - 8, z0, x + h + 8, y + h + 8, z0 + 12, "concrete2", 0.8)
    self:solid(name, x - h - 8, y - h - 8, z0, x + h + 8, y + h + 8, z0 + 12)
    self:solid(name, x - h, y - h, z0 + 12, x + h, y + h, z1 - 32)
    self:solid(name, x - h - 24, y - h - 24, z1 - 32, x + h + 24, y + h + 24, z1)
    -- a steel post from this pier's viaduct up to one crossing above, if any
    if p.postFrom and p.postTo then
        self:box(x - 16, y - 16, p.postFrom, x + 16, y + 16, p.postTo, "steel", 0.8)
        self:solid(name, x - 16, y - 16, p.postFrom, x + 16, y + 16, p.postTo)
    end
end

--------------------------------------------------------------------------
-- A rooftop billboard: a sign on steel legs, standing on whichever frontage
-- building is under it, set back from its front edge.
--
--   { side = "north", at = 1800, w = 1024, h = 320, back = 96, text = ... }
--
-- `at` is the position along the wall. The height comes from the building,
-- so a new seed never buries the sign or leaves it floating.
--------------------------------------------------------------------------
function B:billboard(bb)
    local side = self.sidesByName[bb.side]
    local row = self.rows[bb.side]
    if not side or not row then return end
    local ax = side.axis == "x" and 1 or 2
    local out = side.out
    -- how far out from the wall a box's front face is
    local function nearOf(bx)
        local lo, hi = bx[side.axis == "x" and 2 or 1], bx[side.axis == "x" and 5 or 4]
        return ((out > 0) and lo or hi) * out - side.at * out
    end
    local roof, setback
    for _, bd in ipairs(row) do
        if bd[ax] <= bb.at and bd[ax + 3] >= bb.at then
            -- on a setback tower, the sign goes up on the tower's roof
            local top = bd.tower or bd
            roof, setback = top[6], nearOf(top)
        end
    end
    if not roof then return end
    local front = side.at + out * (setback + (bb.back or 96))   -- the sign's face line
    local legH = bb.legs or 96
    local z0 = roof + legH
    local cz = z0 + bb.h / 2
    -- legs: three pairs of steel posts behind the panel, and a catwalk
    for _, f in ipairs({ -0.4, 0, 0.4 }) do
        local a = bb.at + f * bb.w
        for _, d in ipairs({ 8, 72 }) do
            local n0 = front + out * d
            local x0, y0, x1, y1
            if side.axis == "x" then x0, x1, y0, y1 = a - 8, a + 8, math.min(n0, n0 + out * 16), math.max(n0, n0 + out * 16)
            else y0, y1, x0, x1 = a - 8, a + 8, math.min(n0, n0 + out * 16), math.max(n0, n0 + out * 16) end
            self:box(x0, y0, roof, x1, y1, z0 + bb.h * 0.9, "steel", 0.75)
        end
    end
    local n0, n1 = front + out * 2, front + out * 90
    local lo, hi = math.min(n0, n1), math.max(n0, n1)
    if side.axis == "x" then
        self:box(bb.at - bb.w / 2, lo, z0 - 12, bb.at + bb.w / 2, hi, z0, { side = "steel", top = "grate", bottom = "steel" }, 0.8)
    else
        self:box(lo, bb.at - bb.w / 2, z0 - 12, hi, bb.at + bb.w / 2, z0, { side = "steel", top = "grate", bottom = "steel" }, 0.8)
    end
    local nrm = side.axis == "x" and { 0, -out, 0 } or { -out, 0, 0 }
    local pos = side.axis == "x" and { bb.at, front, cz } or { front, bb.at, cz }
    local sg = {}
    for k, v in pairs(bb) do sg[k] = v end
    sg.pos, sg.normal, sg.roof = pos, nrm, roof
    self.signs[#self.signs + 1] = sg
end

--------------------------------------------------------------------------
-- Build a map definition into a layout.
--------------------------------------------------------------------------
function City.Build(def)
    local b = newBuilder(def)
    local rng = Rng(def.seed or 1)
    local p = def.park

    -- The four walls, as sides. Corners belong to the north/south rows, which
    -- run past the ends by the frontage depth.
    local fr = def.frontage
    local over = fr.maxDepth + (fr.offset or 0)
    local S = {
        north = { name = "north", axis = "x", at = p[5], out = 1,  from = p[1] - over, to = p[4] + over },
        south = { name = "south", axis = "x", at = p[2], out = -1, from = p[1] - over, to = p[4] + over },
        west  = { name = "west",  axis = "y", at = p[1], out = -1, from = p[2], to = p[5] },
        east  = { name = "east",  axis = "y", at = p[4], out = 1,  from = p[2], to = p[5] },
    }
    b.sidesByName = S

    -- Viaduct ends need tall enough buildings to swallow their portals.
    local cover = {}
    for _, v in ipairs(def.viaducts or {}) do
        local V = City.Viaduct
        local top = v.deck + V.truss + 64
        local s0, s1
        if v.axis == "y" then s0, s1 = S.south, S.north else s0, s1 = S.west, S.east end
        for _, s in ipairs({ s0, s1 }) do
            cover[#cover + 1] = { side = s, a0 = v.at - V.width, a1 = v.at + V.width, z = top }
        end
    end

    b.rows = {}
    for _, key in ipairs({ "north", "south", "west", "east" }) do
        b.group = "front:" .. key
        b.rows[key] = b:row(S[key], fr, rng, cover)
    end
    -- the second row: taller, further back, gaps between
    if def.backRow then
        for _, key in ipairs({ "north", "south", "west", "east" }) do
            local s = S[key]
            local s2 = { name = key .. "2", axis = s.axis, at = s.at, out = s.out,
                from = s.from - (s.axis == "y" and over or 0), to = s.to + (s.axis == "y" and over or 0) }
            b.group = "back:" .. key
            b:row(s2, def.backRow, rng)
        end
    end
    if def.skyline then b:skyline(def.skyline, rng) end

    for i, v in ipairs(def.viaducts or {}) do
        b.group = "via:" .. (v.name or ("line" .. i))
        b:viaduct(v, v.name or ("line" .. i))
    end
    b.group = "via:piers"
    for i, pr in ipairs(def.piers or {}) do b:pier(pr, pr.name or ("pier" .. i)) end

    for _, sg in ipairs(def.signs or {}) do b.signs[#b.signs + 1] = sg end
    b.group = "front:roof"
    for _, bb in ipairs(def.billboards or {}) do b:billboard(bb) end

    return {
        faces = b.faces, solids = b.solids, lines = b.lines, signs = b.signs,
        buildings = b.buildings, quads = b.quads, rows = b.rows, def = def,
    }
end

-- The current map's definition, if the city has one for it.
function City.Def(map)
    return City.Maps[map or game.GetMap()]
end

-- Is the city switched on? Server convar bmx_city (replicated), default on.
function City.Enabled()
    local cv = GetConVar and GetConVar("bmx_city")
    if cv then return cv:GetBool() end
    return true
end

-- Built once per map per realm and cached.
function City.Layout()
    local map = game.GetMap()
    if City._layoutMap ~= map then
        local def = City.Def(map)
        City._layout = def and City.Build(def) or nil
        City._layoutMap = map
    end
    return City._layout
end

if SERVER then
    CreateConVar("bmx_city", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
        "BMX: build the city around the park on maps that have one (1/0). Takes effect on map change or bmx_city_rebuild.")
end
