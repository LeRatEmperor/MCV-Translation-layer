if SERVER then AddCSLuaFile() end
DHRBash = DHRBash or {}
local B = DHRBash
local enabled = CreateConVar("dhr_gun_bash", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
    "Allow close-range strikes with DHRB guns", 0, 1)
local key = CreateClientConVar("dhr_bash_key", tostring(KEY_G), true, false, "Gun bash key; 0 disables the key")
local duration, impact = 0.72, 0.28

function B.Supported(w)
    return IsValid(w) and not w.DualWield and w.HR and w.HR.kind == "gun" and w.GetBashStart and w.HR.bash ~= false
end

function B.Active(w)
    return B.Supported(w) and w:GetBashStart() > 0 and CurTime() < w:GetBashStart() + duration
end

function B.Cancel(w)
    w:SetBashStart(0)
    w.dhr_bash_hit = nil
end

function B.Begin(w)
    if not enabled:GetBool() or not B.Supported(w) then return false end
    local owner, now = w:GetOwner(), CurTime()
    if not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() or owner:InVehicle()
        or owner:GetActiveWeapon() ~= w or owner:IsFrozen() or HRCombat.Dodging(owner)
        or w:GetNW2Bool("hr_executing") or B.Active(w) then return false end
    if now < math.max(w:GetNextPrimaryFire(), w:GetNextSecondaryFire())
        or w:GetReloadDone() > 0 or w:GetReloadStage() > 0 or now < w:GetReloadUntil() then return false end
    if now < w:GetBusyUntil() or w:GetPumpAt() > 0 then return false end
    if DHR.RunHook("DHRCanBash", w) == false then return false end
    w:SetAiming(false)
    w:SetAdsPose(false)
    w:Action(w.HR.seq.idle)
    w:SetBashStart(now)
    w:SetBusyUntil(now + duration)
    w:SetNextPrimaryFire(now + duration)
    w:SetNextSecondaryFire(now + duration)
    local listeners
    if SERVER then
        w.dhr_bash_hit = now + impact
        listeners = RecipientFilter()
        listeners:AddPAS(w:GetPos())
        if not game.SinglePlayer() then listeners:RemovePlayer(owner) end
    end
    w:EmitSound((w.HR.bash or {}).swing_sound or "HR.Bat_Swing", nil, nil, nil, nil, nil, nil, listeners)
    return true
end

local surfaces = {
    [MAT_METAL] = "Metal", [MAT_VENT] = "Metal", [MAT_GRATE] = "Metal",
    [MAT_WOOD] = "WoodBoard", [MAT_TILE] = "Ceramic", [MAT_DIRT] = "Rock"
}

local function hit(w)
    local owner, config = w:GetOwner(), w.HR.bash or {}
    local origin, direction = owner:GetShootPos(), owner:GetAimVector()
    owner:LagCompensation(true)
    local trace = {start = origin, endpos = origin + direction * (config.range or 64), filter = owner, mask = MASK_SHOT_HULL}
    local tr = util.TraceLine(trace)
    if not tr.Hit then
        trace.mins, trace.maxs = Vector(-6, -6, -6), Vector(6, 6, 6)
        tr = util.TraceHull(trace)
        -- Reject hull contacts across the edge of a wall.
        if tr.Hit then
            local sight = util.TraceLine({start = origin, endpos = tr.HitPos, filter = owner, mask = MASK_SHOT_HULL})
            if sight.Hit and sight.Entity ~= tr.Entity then tr = sight end
        end
    end
    owner:LagCompensation(false)
    if not tr.Hit then return end
    hook.Run("HRMeleeNoise", owner, tr.HitPos)
    local target = tr.Entity
    local flesh = IsValid(target) and (target:IsPlayer() or target:IsNPC() or target:IsNextBot() or target:IsRagdoll())
    local injured = false
    if IsValid(target) then
        local amount = (config.damage or 10) * GetConVar("hr_damage_scale"):GetFloat()
        local damage = DamageInfo()
        damage:SetAttacker(owner)
        damage:SetInflictor(w)
        damage:SetDamage(amount)
        damage:SetDamageType(DMG_CLUB)
        damage:SetDamagePosition(tr.HitPos)
        damage:SetDamageForce(direction * 2400)
        local before = target:Health()
        target:DispatchTraceAttack(damage, tr, direction)
        injured = not IsValid(target) or target:Health() < before
        if IsValid(target) and target:IsRagdoll() then
            HRDismember.CorpseHit(w, tr, amount, damage:GetDamageForce(), false)
            injured = true
        end
        if injured and flesh then
            net.Start("hr_weapon_hit")
            net.WriteEntity(w)
            net.Send(owner)
        end
    end
    local soundName = flesh and (config.hit_sound or "HR.Enemy_Common_Hit_MeleeWeapon_Organic_Blunt")
        or "HR.Hit_BluntMetal_" .. (surfaces[tr.MatType] or "Concrete")
    local listeners = RecipientFilter()
    listeners:AddPAS(w:GetPos())
    if not game.SinglePlayer() then listeners:RemovePlayer(owner) end
    w:EmitSound(soundName, nil, nil, nil, nil, nil, nil, listeners)
    if not game.SinglePlayer() then
        net.Start("dhr_bash_impact")
        net.WriteEntity(w)
        net.WriteString(soundName)
        net.Send(owner)
    end
    if not flesh or injured then
        local effect = EffectData()
        effect:SetOrigin(tr.HitPos)
        effect:SetStart(origin)
        effect:SetNormal(tr.HitNormal)
        effect:SetEntity(target)
        effect:SetSurfaceProp(tr.SurfaceProps)
        effect:SetHitBox(tr.HitBox)
        effect:SetDamageType(DMG_CLUB)
        if flesh then effect:SetColor(IsValid(target) and HRDismember.BloodColor(target) or BLOOD_COLOR_RED) end
        util.Effect(flesh and "BloodImpact" or "Impact", effect, true, true)
    end
    DHR.RunHook("DHRBashHit", w, tr, injured)
end

function B.Think(w)
    if not B.Active(w) then w.dhr_bash_hit = nil return false end
    local owner = w:GetOwner()
    if not enabled:GetBool() or not IsValid(owner) or not owner:Alive() or owner:GetActiveWeapon() ~= w then
        B.Cancel(w)
        return false
    end
    if SERVER and w.dhr_bash_hit and CurTime() >= w.dhr_bash_hit then
        w.dhr_bash_hit = nil
        hit(w)
    end
    return true
end

local function menuOpen()
    return CLIENT and (gui.IsGameUIVisible() or vgui.CursorVisible() or IsValid(vgui.GetKeyboardFocus()) or HRWheel and HRWheel.open)
end

hook.Add("KeyPress", "dhr_gun_bash", function(player, button)
    if button == IN_ALT1 then B.Begin(player:GetActiveWeapon()) end
end)

if SERVER then
    util.AddNetworkString("dhr_bash_impact")
    util.AddNetworkString("dhr_gun_bash_setting")
    net.Receive("dhr_gun_bash_setting", function(_, player)
        if not game.SinglePlayer() and not player:IsAdmin() then return end
        enabled:SetBool(net.ReadBool())
    end)
    concommand.Add("dhr_bash", function(player)
        if IsValid(player) then B.Begin(player:GetActiveWeapon()) end
    end)
    return
end

net.Receive("dhr_bash_impact", function()
    local w, soundName = net.ReadEntity(), net.ReadString()
    if IsValid(w) and w:GetOwner() == LocalPlayer() then w:EmitSound(soundName) end
end)

function B.SetEnabled(on)
    net.Start("dhr_gun_bash_setting")
    net.WriteBool(on)
    net.SendToServer()
end

hook.Add("CreateMove", "dhr_gun_bash", function(cmd)
    local player = LocalPlayer()
    if not IsValid(player) or not enabled:GetBool() or menuOpen() or not B.Supported(player:GetActiveWeapon()) then return end
    local code = key:GetInt()
    local down = code >= MOUSE_FIRST and code <= MOUSE_LAST and input.IsMouseDown(code)
        or code > KEY_NONE and code < MOUSE_FIRST and input.IsKeyDown(code)
    if down then cmd:AddKey(IN_ALT1) end
end)

hook.Add("PlayerBindPress", "dhr_gun_bash", function(player, bind, pressed, code)
    if code == key:GetInt() and enabled:GetBool() and B.Supported(player:GetActiveWeapon()) and not menuOpen() then return true end
end)

local pistol = {
    {0, Vector(), Angle()},
    {0.14, Vector(3, -3, 2), Angle(-15, -12, -18)},
    {impact, Vector(-5, 6, 1), Angle(16, 28, 32)},
    {0.39, Vector(-4, 4, 0), Angle(12, 24, 25)},
    {duration, Vector(), Angle()}
}
local stock = {
    {0, Vector(), Angle()},
    {0.14, Vector(3, -4, 2), Angle(-8, -25, -12)},
    {impact, Vector(-4, 5, 2), Angle(8, 65, 22)},
    {0.39, Vector(-3, 3, 1), Angle(6, 58, 18)},
    {duration, Vector(), Angle()}
}

local function motion(w)
    if not B.Active(w) then return vector_origin, angle_zero end
    local time = CurTime() - w:GetBashStart()
    local small = w.HR.crosshair == "colt" or w.HR.crosshair == "revolver"
    local frames = small and pistol or stock
    for i = 2, #frames do
        local a, b = frames[i - 1], frames[i]
        if time <= b[1] then
            local t = math.Clamp((time - a[1]) / (b[1] - a[1]), 0, 1)
            t = t * t * (3 - 2 * t)
            return LerpVector(t, a[2], b[2]), LerpAngle(t, a[3], b[3])
        end
    end
    return vector_origin, angle_zero
end

function B.View(w, pos, ang)
    local offset, rotation = motion(w)
    local right, forward, up = ang:Right(), ang:Forward(), ang:Up()
    local turn = Angle(ang)
    turn:RotateAroundAxis(right, rotation.p)
    turn:RotateAroundAxis(up, rotation.y)
    turn:RotateAroundAxis(forward, rotation.r)
    -- Rotate at the grip so the swing stays in front of the player.
    local grip = forward * 20 + right * 6 - up * 5
    local rotated = turn:Forward() * 20 + turn:Right() * 6 - turn:Up() * 5
    pos = pos + grip - rotated + right * offset.x + forward * offset.y + up * offset.z
    return pos, turn
end

function B.Placement(player, w, placement, pivot)
    if not B.Active(w) then return placement end
    local offset, rotation = motion(w)
    local facing = player:EyeAngles()
    local frame = Matrix()
    frame:SetTranslation(pivot)
    frame:SetAngles(facing)
    local strike = Matrix()
    strike:SetTranslation(Vector(offset.y, -offset.x, offset.z))
    strike:SetAngles(Angle(-rotation.p, rotation.y, rotation.r))
    return frame * strike * frame:GetInverse() * placement
end

hook.Add("UpdateAnimation", "dhr_gun_bash", function(player)
    local w = player:GetActiveWeapon()
    if not B.Active(w) or w.DualWield or (DHR.HasFeature(w, "thirdperson") and w.HR.world) then return end
    if player.dhr_bash_gesture == w:GetBashStart() then return end
    player.dhr_bash_gesture = w:GetBashStart()
    player:AnimRestartGesture(GESTURE_SLOT_ATTACK_AND_RELOAD, ACT_HL2MP_GESTURE_RANGE_ATTACK_MELEE2, true)
end)
