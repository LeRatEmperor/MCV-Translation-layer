// The tracer for one round, drawn from the gun that fired: the muzzle attachment of the
// viewmodel in first person, of the drawn world model in third person (the left gun of a dual
// on magnitude 1). The server sends the hit position, so the origin is worked out here, on the
// client, where the drawn models live. MCV.HitscanEffects dispatches this from the firing
// callback, with shooter-only delivery for silenced trails.
//
// Two halves. The game's particle system is started for the smoke it trails, bound in first
// person to the weapon and the viewmodel's attachment so the engine draws it along with the
// viewmodel and it leaves the muzzle where the muzzle is on screen. The glowing streak is
// drawn by Render below, because the one the system carries never appears in GMod; Init says
// what was ruled out before it was drawn by hand.

// The streak's look, taken from the game's own systems: COLOR_* is the brightest pixel of the
// texture each family draws with (vietnam_ae_tracers_01, and _02 for the green side), and each
// entry below is that family's render_sprite_trail max length and Radius Random maximum.
local SPEED = 10000 // units a second, the speed those systems carry a round at
// the radius those systems give a particle reads about three times too wide as a drawn beam
local STREAK_SCALE = 1 / 10

local FAMILY = {
    assaultrifle = {150, 2},
    gyrojet      = {200, 3},
    machinegun   = {170, 4},
    pistol       = {125, 3},
    ptrd         = {200, 4},
    rifle        = {200, 3},
    shotgun      = {125, 2},
    shotgun_dots = {0, 2},
    silenced     = {0, 0},
    smg          = {125, 2},
    sniperrifle  = {200, 3},
}

local beammat = CreateMaterial("mcv_tracer_beam", "UnlitGeneric", {
    ["$basetexture"] = "vgui/white",
    ["$additive"] = "1",
    ["$vertexcolor"] = "1",
    ["$vertexalpha"] = "1",
    ["$translucent"] = "1",
})
local glowmat = Material("sprites/light_glow02_add")

function EFFECT:Init(data)
    local wpn = data:GetEntity()
    if !IsValid(wpn) then return end
    local owner = wpn:GetOwner()
    local tracer = wpn.TracerParticle
    if !tracer or tracer == "" then return end
    if tracer == "vietnam_tracer_silenced_primary"
            and (!IsValid(owner) or owner != LocalPlayer()) then return end
    local to = data:GetOrigin()
    // off the gun: a dual's left gun fires on an odd count, the same rule the muzzle flash uses
    local left = wpn.GetAkimbo and wpn:GetAkimbo() and wpn:Clip1() % 2 == 0

    local from, bind_ent, bind_att
    if IsValid(owner) and owner == LocalPlayer() and !owner:ShouldDrawLocalPlayer() then
        local vm = owner:GetViewModel()
        if IsValid(vm) then
            local att = 0
            if left then
                att = vm:LookupAttachment("muzzleleft")
                if att <= 0 then att = vm:LookupAttachment("muzzle2") end
            end
            if att <= 0 then att = vm:LookupAttachment("muzzle") end
            local a = att > 0 and vm:GetAttachment(att)
            if a then
                from = a.Pos
                bind_ent, bind_att = vm, att
            end
        end
    elseif wpn.GetWorldModelAttachment then
        local mdl, att = wpn:GetWorldModelAttachment("muzzle", left)
        if IsValid(mdl) and att > 0 then
            mdl:SetupBones()
            local a = mdl:GetAttachment(att)
            if a then
                from = a.Pos
                bind_ent, bind_att = mdl, att
            end
        end
    end
    if !from then
        from = IsValid(owner) and owner.GetShootPos and owner:GetShootPos() or wpn:GetPos()
    end

    // the game's system, on every round: its smoke child is what trails behind the shot
    self:Trail(tracer, from, to, bind_ent, bind_att)

    // Which rounds glow, off the gun as well: every TracerFrequency-th round in the magazine.
    // The callback sends this effect for every bullet, so the smoke is on all of them and only
    // the streak is intermittent. Counting the round in the magazine rather than keeping a
    // tally means both realms reach the same answer without anything being networked for it.
    local freq = math.max(wpn.TracerFrequency or 1, 1)
    if freq > 1 and wpn:Clip1() % freq != 0 then return end

    // ... and the glowing streak is drawn here, by Render below. The system's own
    // render_sprite_trail draws nothing in GMod: its operators are all in the client binary,
    // the renderer is the one 1300 other systems use, and the material's shader, sprite sheet
    // and blend keys match effects that do draw (impact sparks, muzzle flashes). The one thing
    // left that is peculiar to a tracer is that its motion comes from `Move Particles Between 2
    // Control Points`, and rather than keep guessing at the engine the streak is drawn as a
    // beam down the same path, the way TacRP draws its own tracers.
    local base = tracer:gsub("^vietnam_tracer_", ""):gsub("_primary$", ""):gsub("_secondary$", "")
    local green = base:find("_green", 1, true) != nil
    local fam = FAMILY[(base:gsub("_green", ""))]
    if !fam or fam[1] <= 0 then return end // silenced rounds have smoke but no glowing streak

    local dir = to - from
    local dist = dir:Length()
    if dist < 1 then return end

    self.StartPos = from
    self.Dir = dir / dist
    self.Travel = dist
    self.Tail = fam[1]
    self.Width = fam[2] * 2 * STREAK_SCALE
    self.Color = self:StreakColor(owner, wpn, green)
    self.StartTime = UnPredictedCurTime()
    self.LifeTime = dist / SPEED
    self.DieTime = self.StartTime + self.LifeTime
end

// The streak's colour. The shooter picks it (mcv_tracer_color, mcv/client/cl_tracercolor.lua),
// and since that convar is userinfo the choice is read off the shooter here rather than off the
// person watching: everyone sees a player's rounds in the colour that player asked for. The
// game's own colour is the default, so a server where nobody has touched it looks unchanged.
function EFFECT:StreakColor(owner, wpn, green)
    return MCV.TracerColor(owner, wpn.TracerParticle)
end

// A two-point trail: control point 0 the start, 1 the end, which is what a tracer particle
// expects. Where the muzzle is a real attachment on a drawn model the system is hung off it,
// the way the muzzle flash is (mcv_base/sh_effects.lua), so the trail leaves the muzzle where
// the muzzle is on screen and follows it; otherwise the two points are set outright.
//
// Keep this cosmetic: the firing callback already owns the bullet trace and damage.
function EFFECT:Trail(name, from, to, ent, att)
    if IsValid(ent) and att and att > 0 then
        local ps = CreateParticleSystem(ent, name, PATTACH_POINT_FOLLOW, att)
        if !IsValid(ps) then return end

        ps:SetControlPoint(1, to)
        ps:StartEmission()
        return
    end

    local ps = CreateParticleSystemNoEntity and CreateParticleSystemNoEntity(name, from)
    if !ps then return end

    ps:SetControlPoint(0, from)
    ps:SetControlPoint(1, to)
end

function EFFECT:Think()
    return self.DieTime != nil and self.DieTime > UnPredictedCurTime()
end

// The streak: a beam from the round to Tail units behind it, and a glow on its head, both
// additive and tinted with the colour the family's texture is drawn in.
function EFFECT:Render()
    if !self.Dir then return end

    local t = (UnPredictedCurTime() - self.StartTime) / self.LifeTime
    if t < 0 or t > 1 then return end

    local travelled = self.Travel * t
    local head = self.StartPos + self.Dir * travelled
    local tail = head - self.Dir * math.min(self.Tail, travelled)

    render.SetMaterial(beammat)
    render.DrawBeam(tail, head, self.Width, 0, 1, self.Color)

    render.SetMaterial(glowmat)
    render.DrawSprite(head, self.Width * 3, self.Width * 3, self.Color)
end
