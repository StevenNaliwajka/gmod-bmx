--[[--------------------------------------------------------------------------
    bmx/sh_settings.lua

    EVERY SETTING A PLAYER OR AN ADMIN CAN CHANGE, in one list.

    That list is what the Options > BMX menu (cl_options.lua) is built from,
    what bmx_reset_client and bmx_reset_server reset, what server.json saves
    and loads (sv_settings.lua), and what bmx_dump_config prints. Nothing else
    keeps its own copy of "what are the settings", so a new one is added in
    exactly one place and shows up in all four.

    THE CONVARS THEMSELVES ARE NOT CREATED HERE. They stay where they always
    were (cl_view.lua makes bmx_cam_dist, sv_rules.lua makes bmx_scoring, and so
    on), under the same names, because a name is an API: people have it in a
    server.cfg, a bind, a workshop description. This file only DESCRIBES them.
    tests/test_settings.lua boots both realms and fails if a bmx_ convar exists
    that is not described here, or if a description disagrees with the convar
    about its default, so the two cannot drift apart.

    A ROW:

        name      the convar's name, unchanged
        kind      "bool" | "int" | "float" | "choice" | "string"
        default   what the convar is created with
        min, max  the range for int and float (both required)
        choices   the allowed values for a choice
        maxLen    the longest a string may be
        decimals  how many places a float slider shows (menu only)
        scope     "client" (each player's own, saved by the engine) or
                  "server" (everyone's; changed through a net message that is
                  checked against CAMI, see sv_settings.lua)
        category  a category id (see Categories below)
        label     the short name on the control
        help      what it does, in a player's words. The tooltip, and the line
                  under the control.

    EXTENDING IT. A later goal (passengers, water, ragmod, air assist, motor
    vehicles, vehicle enable/disable) adds its rows with BMX.Settings.Add from
    its own file, and a category of its own with BMX.Settings.AddCategory if it
    wants one. Nothing in the menu, the reset commands or the persistence needs
    touching. The file must be loaded before cl_options / sv_settings read the
    list at the first InitPostEntity; any file in the loader's lists is.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Settings = BMX.Settings or {}
local S = BMX.Settings

S.List = S.List or {}          -- rows, in the order they are added
S.ByName = S.ByName or {}
S.Categories = S.Categories or { client = {}, server = {} }

-- The operations of the bmx_setting net message (client -> server), shared so
-- both ends agree. Part of the wire format: add to the end only.
S.OP_SET, S.OP_RESET, S.OP_RESET_ALL = 0, 1, 2

--------------------------------------------------------------------------
-- Categories. THE EXTENSION POINT for the menu's grouping: each is a heading
-- on its panel, in the order they were added.
--------------------------------------------------------------------------
function S.AddCategory(scope, id, label)
    local list = S.Categories[scope]
    assert(list, "BMX.Settings.AddCategory: scope must be client or server")
    for _, c in ipairs(list) do
        if c.id == id then c.label = label return c end
    end
    local c = { id = id, label = label }
    list[#list + 1] = c
    return c
end

S.AddCategory("client", "camera",   "Camera")
S.AddCategory("client", "hud",      "Display")
S.AddCategory("client", "rider",    "Rider")
S.AddCategory("client", "world",    "Scenery")
S.AddCategory("client", "advanced", "Advanced")

S.AddCategory("server", "rules",    "Rules and scoring")
S.AddCategory("server", "world",    "The park")
S.AddCategory("server", "feel",     "How the bike rides")
S.AddCategory("server", "bots",     "Bot riders")

--------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------
local KINDS = { bool = true, int = true, float = true, choice = true, string = true }

function S.Add(row)
    assert(isstring(row.name) and row.name ~= "", "a setting needs a name")
    assert(KINDS[row.kind], row.name .. ": unknown kind " .. tostring(row.kind))
    assert(row.scope == "client" or row.scope == "server", row.name .. ": scope")
    assert(isstring(row.help) and row.help ~= "", row.name .. ": a setting needs help text")
    assert(isstring(row.label), row.name .. ": a setting needs a label")
    if row.kind == "int" or row.kind == "float" then
        assert(isnumber(row.min) and isnumber(row.max) and row.min < row.max,
            row.name .. ": a number needs min < max")
    elseif row.kind == "choice" then
        assert(istable(row.choices) and #row.choices > 0, row.name .. ": a choice needs choices")
    elseif row.kind == "string" then
        assert(isnumber(row.maxLen) and row.maxLen > 0, row.name .. ": a string needs maxLen")
    end
    if S.ByName[row.name] then
        -- Replacing in place keeps the order stable across a Lua reload.
        for i, r in ipairs(S.List) do if r.name == row.name then S.List[i] = row end end
    else
        S.List[#S.List + 1] = row
    end
    S.ByName[row.name] = row
    return row
end

function S.Get(name) return S.ByName[name] end

-- The rows of one scope, optionally of one category, in order.
function S.Rows(scope, category)
    local out = {}
    for _, r in ipairs(S.List) do
        if r.scope == scope and (not category or r.category == category) then
            out[#out + 1] = r
        end
    end
    return out
end

--------------------------------------------------------------------------
-- Values. What a menu, a net message or a JSON file hands us is a string or a
-- number or a bool; Coerce turns any of them into the row's own type, inside
-- its range, or says why not. Out-of-range numbers are CLAMPED rather than
-- refused: a slider dragged past its end, or a hand-edited file saying 9999,
-- should land on the nearest sensible value, not on nothing.
--------------------------------------------------------------------------
function S.Coerce(row, v)
    local kind = row.kind
    if kind == "bool" then
        if v == true or v == 1 or v == "1" or v == "true" then return true end
        if v == false or v == 0 or v == "0" or v == "false" then return false end
        return nil, "not a yes or no"
    elseif kind == "int" or kind == "float" then
        local n = tonumber(v)
        if not n or n ~= n or n == math.huge or n == -math.huge then
            return nil, "not a number"
        end
        if kind == "int" then n = math.floor(n + 0.5) end
        return math.max(row.min, math.min(row.max, n))
    elseif kind == "choice" then
        local s = string.lower(tostring(v))
        for _, c in ipairs(row.choices) do
            if c == s then return c end
        end
        return nil, "one of " .. table.concat(row.choices, ", ")
    else
        if v == nil or istable(v) then return nil, "not text" end
        local s = tostring(v)
        s = string.gsub(s, "[%c\"\\]", "")       -- no control characters, quotes or slashes
        return string.sub(s, 1, row.maxLen)
    end
end

-- The string a convar is set to for a coerced value.
function S.ToConVar(row, v)
    if row.kind == "bool" then return v and "1" or "0" end
    if row.kind == "int" then return tostring(math.floor(v)) end
    if row.kind == "float" then
        local s = string.format("%.6f", v)
        s = string.gsub(s, "0+$", "")
        s = string.gsub(s, "%.$", "")
        return s
    end
    return tostring(v)
end

-- What a convar currently says, as the row's own type (nil if it is not there
-- yet, which is a realm that does not own it).
function S.Current(row)
    local cv = GetConVar(row.name)
    if not cv then return nil end
    local v = S.Coerce(row, cv:GetString())
    if v == nil then return row.default end
    return v
end

function S.IsDefault(row)
    local v = S.Current(row)
    return v == nil or v == row.default
end

--------------------------------------------------------------------------
-- THE SETTINGS
--------------------------------------------------------------------------
local function client(row) row.scope = "client" return S.Add(row) end
local function server(row) row.scope = "server" return S.Add(row) end

-- ---- Rider (client) ------------------------------------------------------
client{ name = "bmx_cam_first", kind = "bool", default = false, category = "camera",
    label = "First-person view",
    help = "Ride looking out from the handlebars instead of from behind the bike." }
client{ name = "bmx_cam_dist", kind = "float", default = 115, min = 40, max = 300, decimals = 0,
    category = "camera", label = "Camera distance",
    help = "How far behind the bike the camera sits when you are standing still. It pulls back a little as you speed up." }
client{ name = "bmx_cam_height", kind = "float", default = 26, min = -10, max = 120, decimals = 0,
    category = "camera", label = "Camera height",
    help = "How high the camera sits above the bike. Higher looks down on the ramp; lower feels faster." }
client{ name = "bmx_cam_roll", kind = "float", default = 0.34, min = 0, max = 1, decimals = 2,
    category = "camera", label = "Camera lean",
    help = "How much the view tilts when the bike leans into a turn. 0 keeps the horizon level, 1 tilts with the bike." }
client{ name = "bmx_cam_smooth", kind = "bool", default = true, category = "camera",
    label = "Smooth camera",
    help = "The camera eases after the bike through turns and ramps. Turn it off to bolt the camera to the bike." }
client{ name = "bmx_cinematic", kind = "bool", default = false, category = "camera",
    label = "Cinematic camera",
    help = "Cut between film-style shots of your ride. You can also toggle it with L while riding. It is not remembered between sessions." }

client{ name = "bmx_hud", kind = "bool", default = true, category = "hud",
    label = "Show the rider HUD",
    help = "The speedometer, trick names, score and combo while you ride." }
client{ name = "bmx_units", kind = "choice", default = "kmh", choices = { "kmh", "mph", "ups" },
    category = "hud", label = "Speed units",
    help = "What the speedometer counts in: kmh (kilometres an hour), mph (miles an hour) or ups (the game's own units a second)." }

client{ name = "bmx_stick_deadzone", kind = "float", default = 0.1, min = 0, max = 0.9, decimals = 2,
    category = "rider", label = "Gamepad stick deadzone",
    help = "How far a gamepad stick can drift from the middle before it counts as steering. Raise it if your bike turns by itself." }
client{ name = "bmx_flip_doubletap", kind = "bool", default = false, category = "rider",
    label = "Double-tap W / S to flip",
    help = "In the air, a quick double-tap of W or S starts a front or back flip, like other bike addons. Off, you hold W or S to rotate." }
client{ name = "bmx_rider_anim", kind = "bool", default = true, category = "rider",
    label = "Animate riders",
    help = "Riders pedal, lean and crouch with the bike. Off leaves everyone sitting in the plain seated pose." }
client{ name = "bmx_rider_ik", kind = "bool", default = true, category = "rider",
    label = "Hands on the bars",
    help = "Put riders' hands on the grips and feet on the pedals. Off uses a simpler swing, which looks worse but costs less." }
client{ name = "bmx_color_default", kind = "string", default = "red", maxLen = 24, category = "rider",
    label = "Colour of new bikes",
    help = "The paint on bikes you spawn: a colour name (red, blue, pink ...) or a number from the palette." }

client{ name = "bmx_city_draw", kind = "bool", default = true, category = "world",
    label = "Draw the city",
    help = "Show the buildings and skyline around the park. Turn it off if the map runs slowly for you." }
client{ name = "bmx_city_trains", kind = "bool", default = true, category = "world",
    label = "Run the subway trains",
    help = "The trains that pass through the city's viaducts." }
client{ name = "bmx_city_signs", kind = "bool", default = true, category = "world",
    label = "Draw the city's signs",
    help = "Neon and shop signs on the buildings." }

client{ name = "bmx_lod_scale", kind = "float", default = 1, min = 0, max = 4, decimals = 1,
    category = "advanced", label = "Bike detail distance",
    help = "How far away bikes keep full detail. 1 is normal, 2 is twice as far, 0 always draws every part." }
client{ name = "bmx_debug", kind = "bool", default = false, category = "advanced",
    label = "Tuning overlay",
    help = "Draw the bike's inner workings (wheel forces, lean, grip) over your view. Only useful if you are tuning the bike." }

-- ---- Server (admin) ------------------------------------------------------
server{ name = "bmx_scoring", kind = "bool", default = true, category = "rules",
    label = "Score tricks",
    help = "Tricks earn points and callouts. Off turns scoring and combos off completely." }
server{ name = "bmx_combos", kind = "bool", default = true, category = "rules",
    label = "Combos",
    help = "Tricks chained together build a combo that pays a bonus when the rider lands it." }
server{ name = "bmx_max_per_player", kind = "int", default = 0, min = 0, max = 50, category = "rules",
    label = "Bikes per player",
    help = "How many bikes one player may have out at once. 0 means no limit from BMX (the sandbox's own entity limit still applies)." }
server{ name = "bmx_crash_ragdoll", kind = "bool", default = true, category = "rules",
    label = "Crashes throw the rider",
    help = "A rider who crashes is thrown off as a ragdoll for a moment. Off just shoves them off the bike." }

server{ name = "bmx_city", kind = "bool", default = true, category = "world",
    label = "Build the city",
    help = "Build the city around the park on maps that have one. Takes effect on the next map change." }

server{ name = "bmx_bot_name", kind = "string", default = "Peter Griffin", maxLen = 32, category = "bots",
    label = "Bot name",
    help = "What a bot rider spawned with bmx_bot_spawn is called." }
server{ name = "bmx_bot_model", kind = "string", default = "", maxLen = 128, category = "bots",
    label = "Bot player model",
    help = "The player model bot riders wear. Empty uses the default. The server must have the model installed." }

-- The feel sliders. Their defaults are READ from the config's own table
-- (C.ConVars), so this list can never disagree with the number the bike was
-- tuned at. Only the range and the words are written here.
local FEEL = {
    bmx_lean_kp   = { 50, 600,  0, "Lean response",
        "How hard the rider fights to hold the lean they chose. Higher is snappier steering, lower is lazier." },
    bmx_lean_kd   = { 10, 200,  0, "Lean damping",
        "How quickly the lean settles down. Too low and the bike wobbles through a turn; too high and it feels stiff." },
    bmx_max_lean  = { 20, 60,   0, "Maximum lean (degrees)",
        "The furthest a rider can lean the bike over before it is out of control." },
    bmx_grip      = { 0.5, 3,   2, "Tyre grip",
        "How well the tyres hold the ground. Lower slides in corners, higher sticks." },
    bmx_spring    = { 3000, 20000, 0, "Suspension stiffness",
        "How stiff the suspension is. Softer rides smoother over bumps, stiffer is crisper on landings." },
    bmx_damper    = { 100, 1500, 0, "Suspension damping",
        "How fast the suspension stops bouncing after a landing." },
    bmx_crank     = { 100000, 600000, 0, "Pedalling power",
        "How hard each pedal stroke pushes. Higher gets to top speed faster." },
    bmx_pitch     = { 400000, 2500000, 0, "Wheelie and stoppie strength",
        "How strongly the rider can pitch the bike up or down to lift a wheel." },
    bmx_hop       = { 100, 450, 0, "Bunny hop height",
        "How hard the bike jumps when you release the hop key. Higher hops go higher." },
    bmx_air_pitch = { 4, 30,    1, "Air flip speed",
        "How fast you can rotate forward and back in the air for flips." },
    bmx_air_roll  = { 4, 30,    1, "Air roll speed",
        "How fast you can spin and barrel roll in the air." },
    bmx_autolevel = { 0, 5,     1, "Air auto-level",
        "How strongly the bike straightens itself in the air if you are not steering it. 0 leaves it to you." },
}
for _, cv in ipairs(BMX.Config.ConVars) do
    local f = FEEL[cv[1]]
    if f then
        -- Rounded, because math.deg(math.rad(42)) is 42.00000000000001 and a
        -- default that is not equal to the "42" the convar holds would show the
        -- setting as changed forever.
        local default = math.floor(cv[2] * 1e6 + 0.5) / 1e6
        server{ name = cv[1], kind = "float", default = default, min = f[1], max = f[2],
            decimals = f[3], category = "feel", label = f[4], help = f[5] }
    end
end

-- A readable dump for bmx_dump_config: every setting, its value, and a marker
-- on the ones that are not at their default.
function S.DumpLines()
    local out = { "-- BMX settings (* = changed from the default)" }
    for _, r in ipairs(S.List) do
        local v = S.Current(r)
        if v ~= nil then
            out[#out + 1] = string.format("%s %-22s %-8s %s", S.IsDefault(r) and " " or "*",
                r.name, r.scope, tostring(v))
        end
    end
    return out
end
