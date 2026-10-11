
local sizes_to_make = {
    24,
    14,
    8
}

local function generatefonts()
    local font = "consolas"

    for _, i in pairs(sizes_to_make) do

        surface.CreateFont( "MCV_" .. tostring(i), {
            font = font,
            size = math.Round(ScreenScale(i)),
            weight = i < 16 and 650 or 600,
            antialias = true,
            additive = false,
            extended = true, -- Required for non-latin fonts
        } )

    end

    surface.CreateFont("MCV_HudSelectionTitle", {
        font = "Verdana",
        size = math.Round(ScreenScale(20 / 3)),
        weight = 700,
        antialias = true,
        extended = true,
    })

    surface.CreateFont("MCV_HudSelectionDesc", {
        font = "Verdana",
        size = math.Round(ScreenScale(14 / 3)),
        weight = 700,
        antialias = true,
        extended = true,
    })

    surface.CreateFont("MCV_HudSelectionText", {
        font = "Verdana",
        size = math.Round(ScreenScale(14 / 3)),
        weight = 500,
        antialias = true,
        extended = true,
    })
    MCV.SelectionFontRevision = (MCV.SelectionFontRevision or 0) + 1
end

generatefonts()

function MCV.Regen()
    generatefonts()
end

concommand.Add("MCV_font_reload", MCV.Regen)

hook.Add("OnScreenSizeChanged", "MCV.FontRegen", function(oldWidth, oldHeight)
    MCV.Regen()
end)
