local materials = {}
local glow = Material("sprites/light_glow02_add")

return function(w, pos, direction, remaining, firstPerson)
	local aiming = firstPerson and w:GetAiming()
	local key = w.HR.flash_style or w.HR.crosshair
	if not ({colt=true, revolver=true, ak47=true, smg=true, shotgun=true})[key] then key = "colt" end
	if key == "shotgun" then key = "revolver" end
	if aiming then key = key == "colt" and "ads_colt" or "ads" end
	materials[key] = materials[key] or Material("hellraiser/effects/flash_" .. key)
	local life = math.Clamp(remaining / 0.075, 0, 1)
	local size = (w.HR.flash or 1) * (aiming and 4.8 or 8.0) * (0.7 + life * 0.3)
	local color = Color(255, 255, 255, math.min(255, life * 380))
	local normal = (EyePos() - pos):GetNormalized()
	render.SetMaterial(materials[key])
	render.DrawQuadEasy(pos + direction * 0.25, normal, size, size, color, w.hr_flash_roll or 0)
	render.SetMaterial(glow)
	render.DrawSprite(pos, size * 0.32, size * 0.32, Color(255, 180, 85, color.a * 0.65))
end
