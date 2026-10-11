local enabled = CreateClientConVar("hr_hud_stock_icons", "1", true, false, "Use Hellraiser-style stock weapon art in the HUD and wheel")
local icons = {}
for _, name in ipairs({
	"gmod_camera",
	"gmod_tool",
	"weapon_357",
	"weapon_ar2",
	"weapon_bugbait",
	"weapon_crossbow",
	"weapon_crowbar",
	"weapon_frag",
	"weapon_medkit",
	"weapon_physcannon",
	"weapon_physgun",
	"weapon_pistol",
	"weapon_rpg",
	"weapon_shotgun",
	"weapon_slam",
	"weapon_smg1",
	"weapon_stunstick",
}) do icons[name] = true end
local materials = {}
local I = {}
function I.Has(name) return icons[name] == true end

function I.Draw(name, x, y, width, height, state, alpha)
	if not enabled:GetBool() or not icons[name] then return false end
	local path = "hellraiser/ui/stock/" .. name .. (state == "selected" and "_g" or state == "hud" and "_hud" or "")
	materials[path] = materials[path] or Material(path)
	surface.SetMaterial(materials[path])
	surface.SetDrawColor(255, 255, 255, alpha or 255)
	local scale = math.min(width / 356, height / 199)
	surface.DrawTexturedRect(x - 178 * scale, y - 99.5 * scale, 356 * scale, 199 * scale)
	return true
end
return I
