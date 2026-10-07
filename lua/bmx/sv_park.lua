--[[--------------------------------------------------------------------------
    bmx/sv_park.lua

    THE SERVER'S HALF OF THE PARK PIECES: placing them, capping them, saving
    and loading a layout, and the preset parks.

    Commands (all but the list ones need BMX.Can "BMX - Build Parks"):
        bmx_park_save <name>     the pieces now standing, to
                                 data/bmx/parks/<map>/<name>.json
        bmx_park_load <name>     replace the park with that file
        bmx_park_preset <id>     build a preset where you are aiming (no id
                                 lists them): street_plaza, vert_ramp, dirt_line
        bmx_park_clear           remove every piece
        bmx_park_list            the saved parks on this map

    bmx_park_max IS A CAP ON ALL PIECES, not per player: the cost of a park is
    the pieces' collision, and that is the same whoever placed them. Every way
    in goes through it: the spawn menu (PlayerSpawnSENT), the toolgun and a
    load (BMX.Park.Place). A load that does not fit stops at the cap and says
    how many it left out, rather than refusing the whole park.

    A SAVE IS THE WORLD POSITIONS, not offsets: a permanent park is on one
    map, in one place, and comes back exactly there. A preset is the other
    case, a layout with no place of its own, so it is built round the point
    the caller aims at.
----------------------------------------------------------------------------]]

BMX = BMX or {}
local P = BMX.Park

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)
local cvMax = CreateConVar("bmx_park_max", "120", FLAGS,
    "BMX: the most park pieces (bmx_park_piece) that can stand at once, from every source.")

local PRIV = "BMX - Build Parks"

function P.Max() return cvMax:GetInt() end

-- Every standing piece. Remove() takes effect at the end of the frame, so a
-- piece P.Clear has just removed is skipped here by its flag: a load that
-- clears and then places must see an empty park.
function P.All()
    local out = {}
    for _, e in ipairs(ents.FindByClass("bmx_park_*")) do
        if P.IsPiece(e) and not e.BMXParkGone then out[#out + 1] = e end
    end
    return out
end
function P.Count() return #P.All() end

local function say(ply, msg)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) else MsgN(msg) end
end

--------------------------------------------------------------------------
-- Placing
--------------------------------------------------------------------------
-- A piece, frozen, where it is told. Returns the entity, or nil and why.
function P.Place(ply, shapeId, params, pos, ang)
    if not P.Shapes[shapeId] then return nil, "no such piece: " .. tostring(shapeId) end
    if P.Count() >= P.Max() then
        return nil, string.format("the park is full (bmx_park_max %d)", P.Max())
    end
    local e = ents.Create("bmx_park_piece")
    if not IsValid(e) then return nil, "could not create the piece" end
    e.ParkShape = shapeId
    e.ParkParams = P.EncodeParams(shapeId, params)
    e:SetPos(pos)
    e:SetAngles(ang or Angle(0, 0, 0))
    e:Spawn()
    e:Activate()
    P.Ground(e)
    -- And once more next tick, when the physics the spawn made is settled in.
    if timer and timer.Simple then timer.Simple(0, function() if IsValid(e) then P.Ground(e) end end) end
    if IsValid(ply) then
        e.BMXOwner = ply
        cleanup.Add(ply, "props", e)
    end
    return e
end

-- The spawn menu is a door too.
hook.Add("PlayerSpawnSENT", "BMX.ParkCap", function(ply, class)
    if not P.IsPieceClass(class) then return end
    if P.Count() >= P.Max() then
        if IsValid(ply) then
            ply:ChatPrint(string.format("[BMX] the park is full (bmx_park_max %d). Remove a piece first.", P.Max()))
        end
        return false
    end
end)

hook.Add("PlayerSpawnedSENT", "BMX.ParkOwner", function(ply, ent)
    if IsValid(ent) and P.IsPiece(ent) then
        ent.BMXOwner = ply
        P.Ground(ent)
    end
end)

--------------------------------------------------------------------------
-- Grounding. A piece stands ON the ground: upright, frozen, its floor on
-- the highest surface under its footprint (so on a bump it rests on the
-- bump rather than sinking into it). The spawn menu puts a SENT a hand's
-- width above where you aim, a physgun lets go of one in mid-air, and a
-- preset is laid at ONE height for the whole layout -- each of those left
-- ramps hovering, and a hovering kicker is a lip a wheel hits from below.
-- It is also what lets the navmesh (sv_nav.lua) run up a ramp: a piece on
-- the floor shares its edge with the floor's areas.
--------------------------------------------------------------------------
local cvGround = CreateConVar("bmx_park_ground", "1", FLAGS,
    "BMX: park pieces settle onto the ground when placed or dropped (0 = they stay where they are put).")

-- The z a piece's floor should be at: the highest ground under its corners,
-- edge midpoints and centre. `trace(x, y, fromZ)` -> z or nil (injectable
-- for the offline tests). Returns nil when there is no ground under it.
function P.GroundZ(b, pos, yawDeg, trace)
    local best
    for _, f in ipairs({ { 0, 0 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
                         { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        -- 2 u in from the edge: a trace on the edge itself can graze the
        -- next piece over, snapped flush against this one.
        local x, y = P.Rotate(f[1] * math.max(b.hl - 2, 0), f[2] * math.max(b.hw - 2, 0), yawDeg)
        local z = trace(pos.x + x, pos.y + y, pos.z + 48)
        if z and (not best or z > best) then best = z end
    end
    return best
end

function P.Ground(e, force)
    if not IsValid(e) or (not force and not cvGround:GetBool()) then return false end
    local b = P.Build(e:GetShape(), e:GetParams())
    if not b then return false end
    local yaw = e:GetAngles().y
    local z = P.GroundZ(b, e:GetPos(), yaw, function(x, y, fromZ)
        local tr = util.TraceLine({ start = Vector(x, y, fromZ), endpos = Vector(x, y, fromZ - 8192),
            mask = MASK_SOLID, filter = function(o)
                return o ~= e and not o:IsPlayer() and not o:IsVehicle() and not o:IsNPC()
                    and o:GetClass() ~= "prop_ragdoll"
            end })
        if tr.Hit and not tr.StartSolid then return tr.HitPos.z end
    end)
    if not z then return false end
    local pos = e:GetPos()
    local at, ang = Vector(pos.x, pos.y, z), Angle(0, yaw, 0)
    -- Frozen FIRST: a body moved into contact while awake is pushed back out.
    local phys = e:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    e:SetPos(at)
    e:SetAngles(ang)
    if IsValid(phys) then
        phys:SetPos(at)
        phys:SetAngles(ang)
        phys:EnableMotion(false)
        phys:Sleep()
    end
    if BMX.Nav and BMX.Nav.Touch then BMX.Nav.Touch(e:WorldSpaceAABB()) end
    return true
end

-- Let go of a piece and it settles. Next frame: the physgun is still
-- holding it inside this hook.
hook.Add("PhysgunDrop", "BMX.ParkGround", function(_, ent)
    if not (IsValid(ent) and P.IsPiece(ent)) then return end
    timer.Simple(0, function() P.Ground(ent) end)
end)

-- A piece gone: the ground it stood on is open again.
hook.Add("EntityRemoved", "BMX.ParkNav", function(ent)
    if P.IsPiece(ent) and BMX.Nav and BMX.Nav.Touch then BMX.Nav.Touch(ent:WorldSpaceAABB()) end
end)

--------------------------------------------------------------------------
-- Save and load
--------------------------------------------------------------------------
function P.Snapshot()
    local list = {}
    for _, e in ipairs(P.All()) do
        list[#list + 1] = { shape = e:GetShape(), params = e:GetParams(),
            pos = e:GetPos(), ang = e:GetAngles() }
    end
    -- a stable file: the same park saves the same bytes
    table.sort(list, function(a, b)
        if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
        if a.pos.y ~= b.pos.y then return a.pos.y < b.pos.y end
        return a.shape < b.shape
    end)
    return list
end

function P.Clear()
    local n = 0
    for _, e in ipairs(P.All()) do
        e.BMXParkGone = true
        e:Remove()
        n = n + 1
    end
    return n
end

local function ensureDir(map)
    file.CreateDir("bmx")
    file.CreateDir("bmx/parks")
    file.CreateDir("bmx/parks/" .. P.MapName(map))
end

function P.Save(name)
    local path = P.Path(game.GetMap(), name)
    if not path then return nil, "a park name is letters, digits, _ and -, up to 32" end
    ensureDir(game.GetMap())
    local list = P.Snapshot()
    file.Write(path, util.TableToJSON(P.Encode(list, game.GetMap()), true))
    return #list, path
end

-- Build a list of { shape, params, pos, ang }. Stops at the cap. Returns how
-- many were placed and how many were left out.
function P.Spawn(ply, list)
    local placed, skipped = 0, 0
    for _, p in ipairs(list) do
        -- Place enforces the cap, so a full park skips the rest one by one
        if P.Place(ply, p.shape, p.params, p.pos, p.ang) then
            placed = placed + 1
        else
            skipped = skipped + 1
        end
    end
    return placed, skipped
end

function P.Load(ply, name)
    local path = P.Path(game.GetMap(), name)
    if not path then return nil, "a park name is letters, digits, _ and -, up to 32" end
    local raw = file.Read(path, "DATA")
    if not raw then return nil, "no saved park '" .. tostring(name) .. "' on " .. game.GetMap() end
    local list, err = P.Decode(util.JSONToTable(raw))
    if not list then return nil, err end
    P.Clear()
    local placed, skipped = P.Spawn(ply, list)
    return placed, skipped
end

-- A preset's pieces in the world: round `origin`, turned by `yaw`.
function P.PresetPieces(id, origin, yaw)
    local layout = P.Layout(id)
    if not layout then return nil end
    local out = {}
    for _, it in ipairs(layout) do
        local x, y = P.Rotate(it.x, it.y, yaw or 0)
        out[#out + 1] = {
            shape = it.shape, params = it.params,
            pos = Vector(origin.x + x, origin.y + y, origin.z),
            ang = Angle(0, (it.yaw + (yaw or 0) + 180) % 360 - 180, 0),
        }
    end
    return out
end

function P.LoadPreset(ply, id, origin, yaw)
    local list = P.PresetPieces(id, origin, yaw)
    if not list then return nil, "no preset '" .. tostring(id) .. "'" end
    P.Clear()
    return P.Spawn(ply, list)
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------
local function allowed(ply)
    if BMX.Can(ply, PRIV) then return true end
    say(ply, "[BMX] you do not have the '" .. PRIV .. "' privilege")
    return false
end

-- Where a preset goes: where the caller is aiming, else the map's start.
local function originFor(ply)
    if IsValid(ply) then
        local tr = ply:GetEyeTrace()
        return tr.HitPos, math.floor(ply:EyeAngles().y / 90 + 0.5) * 90
    end
    local at = Vector(0, 0, 0)
    local s = ents.FindByClass("info_player_start")[1]
    if IsValid(s) then at = s:GetPos() end
    local tr = util.TraceLine({ start = at + Vector(0, 0, 64), endpos = at - Vector(0, 0, 4096),
        mask = MASK_SOLID })
    if tr.Hit then at = tr.HitPos end
    return at, 0
end

concommand.Add("bmx_park_save", function(ply, _, args)
    if not allowed(ply) then return end
    local n, path = P.Save(args[1])
    if not n then say(ply, "[BMX] " .. tostring(path)) return end
    say(ply, string.format("[BMX] saved %d pieces to data/%s", n, path))
end, nil, "BMX: save the park's pieces to data/bmx/parks/<map>/<name>.json (needs BMX - Build Parks)")

concommand.Add("bmx_park_load", function(ply, _, args)
    if not allowed(ply) then return end
    local placed, skipped = P.Load(ply, args[1])
    if not placed then say(ply, "[BMX] " .. tostring(skipped)) return end
    say(ply, string.format("[BMX] loaded %d pieces%s", placed,
        skipped > 0 and string.format(", %d left out (bmx_park_max %d)", skipped, P.Max()) or ""))
end, nil, "BMX: replace the park with a saved one (needs BMX - Build Parks)")

concommand.Add("bmx_park_preset", function(ply, _, args)
    if not allowed(ply) then return end
    local id = args[1] and args[1]:lower()
    if not id or not P.Presets[id] then
        for _, k in ipairs(P.PresetOrder) do
            say(ply, string.format("[BMX]   %-13s %s", k, P.Presets[k].help))
        end
        return
    end
    local at, yaw = originFor(ply)
    local placed, skipped = P.LoadPreset(ply, id, at, yaw)
    say(ply, string.format("[BMX] %s: %d pieces%s", P.Presets[id].label, placed,
        skipped > 0 and string.format(", %d left out (bmx_park_max %d)", skipped, P.Max()) or ""))
end, nil, "BMX: build a preset park where you aim: street_plaza, vert_ramp, dirt_line (needs BMX - Build Parks)")

concommand.Add("bmx_park_clear", function(ply)
    if not allowed(ply) then return end
    say(ply, string.format("[BMX] removed %d pieces", P.Clear()))
end, nil, "BMX: remove every park piece (needs BMX - Build Parks)")

concommand.Add("bmx_park_list", function(ply)
    local files = file.Find("bmx/parks/" .. P.MapName(game.GetMap()) .. "/*.json", "DATA")
    if #files == 0 then say(ply, "[BMX] no saved parks on " .. game.GetMap()) return end
    for _, f in ipairs(files) do say(ply, "[BMX]   " .. f:gsub("%.json$", "")) end
end, nil, "BMX: the saved parks on this map")
