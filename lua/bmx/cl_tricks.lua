--[[--------------------------------------------------------------------------
    bmx/cl_tricks.lua

    THE TRICK LIST: every trick and the keys that do it, in game.

        bmx_tricks         toggle the list
        +bmx_tricks        show it while held (bind a key: bind F4 +bmx_tricks)
        bmx_flip_doubletap 1   double-tap W or S in the air for a flip (off)

    WHY AN OVERLAY. The competitor puts its tricks in a README table, and a
    player who is mid-session will not go and read one. With the modifier keys
    (Alt for poses, LMB / R for whips and bars) there are enough chords that a
    rider needs them on screen, and the registry already knows every one of
    them: the list is BMX.TrickOrder, read back, so a trick somebody registers
    (sh_tricks.lua) shows up here with no change to this file.

    BMX.TrickOverlayLines is the content as data, so the suite can read it
    without a screen.
----------------------------------------------------------------------------]]

BMX = BMX or {}

-- Userinfo (the fourth argument), so sv_input.lua reads each rider's own
-- with GetInfoNum rather than one setting for the whole server.
CreateClientConVar("bmx_flip_doubletap", "0", true, true,
    "BMX: 1 = a double-tap of W or S in the air is a flip (stops itself near a full turn); 0 = hold to rotate.")

-- What LMB does (G02): "brake" (the front brake; with Ctrl, brake and lean
-- forward) or "lean" (lean forward; with Ctrl, lean and brake). Userinfo, like
-- the one above: sv_input.lua reads each rider's own.
CreateClientConVar("bmx_lmb_mode", "brake", true, true,
    "BMX: what left mouse does on the ground: brake = the front brake (with Ctrl, also lean forward); lean = lean forward (with Ctrl, also brake).")

local shown = false     -- toggled by bmx_tricks
local held  = false     -- +bmx_tricks

concommand.Add("bmx_tricks", function() shown = not shown end)
concommand.Add("+bmx_tricks", function() held = true end)
concommand.Add("-bmx_tricks", function() held = false end)

function BMX.TricksOverlayVisible() return shown or held end

-- The riding controls that are not tricks, for the top of the list.
local RIDING = {
    { "Pedal / rear brake", "W / S" },
    { "Lean (steers)", "A / D" },
    { "Wheelie / manual", "RMB (weight back)" },
    { "Front brake", "LMB" },
    { "Lean forward / nose manual", "LMB + CTRL (hold CTRL, let go of LMB); bmx_lmb_mode lean: LMB" },
    { "Bunny hop", "hold SPACE, release" },
    { "Sprint / tuck", "SHIFT / CTRL (tuck spins faster in the air)" },
}

local SECTIONS = {
    { "Rotations",       { "spin" } },
    { "Frame and bars",  { "part" } },
    { "Style poses",     { "pose" } },
    { "Ground",          { "ground" } },
    { "Grinds",          { "grind" } },
    { "Other",           { "custom" } },
}

-- Rows of { text, input } with { header = "..." } between sections.
function BMX.TrickOverlayLines()
    local out = { { header = "Riding" } }
    for _, r in ipairs(RIDING) do out[#out + 1] = { text = r[1], input = r[2] } end
    for _, sec in ipairs(SECTIONS) do
        local rows = {}
        for _, id in ipairs(BMX.TrickOrder) do
            local t = BMX.Tricks[id]
            for _, kind in ipairs(sec[2]) do
                if t.kind == kind then rows[#rows + 1] = { text = t.name, input = t.input, id = id } end
            end
        end
        if #rows > 0 then
            out[#out + 1] = { header = sec[1] }
            for _, r in ipairs(rows) do out[#out + 1] = r end
        end
    end
    return out
end

hook.Add("HUDPaint", "BMX.TrickList", function()
    if not (shown or held) then return end
    local lines = BMX.TrickOverlayLines()
    local lh, w = 18, 620
    local h = 40 + #lines * lh
    local x, y = (ScrW() - w) * 0.5, math.max(20, (ScrH() - h) * 0.5)

    draw.RoundedBox(8, x, y, w, h, Color(16, 18, 22, 225))
    draw.SimpleText("BMX tricks  (ALT in the air: poses)", "BMX.Big", x + 16, y + 8,
        Color(232, 236, 242), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    local cy = y + 44
    for _, l in ipairs(lines) do
        if l.header then
            draw.SimpleText(l.header, "BMX.Small", x + 16, cy,
                Color(240, 185, 90), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        else
            draw.SimpleText(l.text, "BMX.Small", x + 32, cy,
                Color(232, 236, 242), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            draw.SimpleText(l.input, "BMX.Small", x + 200, cy,
                Color(150, 158, 170), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
        end
        cy = cy + lh
    end
end)
