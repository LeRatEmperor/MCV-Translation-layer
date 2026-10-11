// Development harness: lets a script outside the game drive a local game session.
//
// Only active when garrysmod/data/mcv_harness/enable.txt exists (work/harness.py creates it).
// The driver drops command files into data/mcv_harness/queue/; the server works through them
// one line at a time and writes results into data/mcv_harness/results/ and screenshots into
// data/mcv_harness/shots/. Keys are pressed through the local player's console (+attack2 and
// so on), so the weapons see real input. Everything is written to disk, which both realms of
// a local listen server share, so no reply channel is needed.
//
// Commands (one per line, # comments):
//   give <class>            give the weapon and select it        strip          remove all weapons
//   select <class>          switch to a carried weapon           pos x y z      teleport
//   ang p y r               set the view angles                  noclip / god   toggle
//   key +attack2            press (or release with -) a key      tap +attack [seconds]
//   wait <seconds>          pause                                hud 0|1        cl_drawhud
//   shot <name> [marker]    screenshot, marker draws the development readout (a centre cross
//                           and the weapon's animation state; `developer 1` shows the same)
//   report <name>           dump weapon / viewmodel state to results/<name>.json
//   spawn <class> [dist]    entity <dist> units in front of the player (npc_citizen 300)
//   cmd <console command>   server console                       ccmd <command>  client console
//   lua <code> / clua <code> run Lua on the server / client
//   ptrace start <name>     record the active weapon's state after every predicted Think on
//                           both realms (see PtraceRecord); ptrace stop writes
//                           results/<name>.ptrace.client.json and .server.json, which
//                           work/ptrace_diff.py compares by command, entity and hook
//   quit                    close the game
//
// An instance launched with -port N (anything but 27015) works out of mcv_harness/pN/ so that
// several can run at once (work/harness.py --port N).

if !file.Exists("mcv_harness/enable.txt", "DATA") then return end

MCV = MCV or {}
MCV.Harness = MCV.Harness or {}
local H = MCV.Harness

local port = GetConVar("hostport") and GetConVar("hostport"):GetInt() or 27015
local ROOT = port == 27015 and "mcv_harness/" or ("mcv_harness/p" .. port .. "/")
local QUEUE = ROOT .. "queue/"
local RESULTS = ROOT .. "results/"
local SHOTS = ROOT .. "shots/"

for _, d in ipairs({ROOT, QUEUE, RESULTS, SHOTS}) do
    if !file.IsDir(d, "DATA") then file.CreateDir(d) end
end

if SERVER then
    util.AddNetworkString("mcv_harness")
end

local function log(...)
    local s = "[harness] " .. table.concat({...}, " ")
    print(s)
    if SERVER then
        file.Append(ROOT .. "log.txt", os.date("%H:%M:%S ") .. s .. "\n")
    end
end

// ---------------------------------------------------------------------------------------
// State the client reports about the active weapon
// ---------------------------------------------------------------------------------------

local function vecs(v) return {math.Round(v.x, 3), math.Round(v.y, 3), math.Round(v.z, 3)} end
local function angs(a) return {math.Round(a.p, 3), math.Round(a.y, 3), math.Round(a.r, 3)} end

function H.WeaponState(ply)
    local wep = ply:GetActiveWeapon()
    local t = {realm = CLIENT and "client" or "server", time = CurTime(), map = game.GetMap(),
               pos = vecs(ply:GetPos()), eye = vecs(ply:EyePos()), ang = angs(ply:EyeAngles()),
               health = ply:Health(), onground = ply:IsOnGround()}
    if !IsValid(wep) then t.weapon = nil return t end
    t.weapon = wep:GetClass()
    t.printname = wep.PrintName
    t.base = wep.Base
    t.clip = wep:Clip1()
    t.reserve = ply:GetAmmoCount(wep:GetPrimaryAmmoType())
    t.clip2 = wep:Clip2()
    t.reserve2 = ply:GetAmmoCount(wep:GetSecondaryAmmoType())
    t.ammo = ply:GetAmmo()
    if wep.MilitaryConflictVietnam then
        t.ironsight = wep:GetIronsight()
        t.sighted = wep:GetSighted()
        t.sight_amount = wep.GetSightAmount and math.Round(wep:GetSightAmount(), 3)
        t.sight_visual = CLIENT and wep.GetSightAmountVisual and math.Round(wep:GetSightAmountVisual(), 3) or nil
        t.speed = wep.GetSpeed and math.Round(wep:GetSpeed(), 1)
        t.firemode = wep.GetFiremodeName and wep:GetFiremodeName()
        t.action_state = wep.GetActionState and wep:GetActionState()
        t.akimbo = wep.GetAkimbo and wep:GetAkimbo()
        t.launcher = wep.GetGrenadeLauncher and wep:GetGrenadeLauncher()
        t.bayonet = wep.GetBayonet and wep:GetBayonet()
        t.bipod = wep.GetBipod and wep:GetBipod()
        t.holster_time = wep:GetHolsterTime()
        t.next_idle = math.Round(wep:GetNextIdle() - CurTime(), 3)
        t.anim_lock = math.Round(wep:GetAnimLockTime() - CurTime(), 3)
        t.hold_type = wep.GetHoldType and wep:GetHoldType()
        t.ironsight_pos = wep.IronsightPos and vecs(wep.IronsightPos)
        t.ironsight_ang = wep.IronsightAng and angs(wep.IronsightAng)
    end
    local vm = ply:GetViewModel()
    if IsValid(vm) then
        local seq = vm:GetSequence()
        t.vm = {model = vm:GetModel(), sequence = vm:GetSequenceName(seq), activity = vm:GetSequenceActivityName(seq),
                cycle = math.Round(vm:GetCycle(), 3), rate = vm:GetPlaybackRate(), pos = vecs(vm:GetPos()), ang = angs(vm:GetAngles()),
                pose = {}, bodygroups = {}}
        for i = 0, vm:GetNumPoseParameters() - 1 do
            local name = vm:GetPoseParameterName(i)
            t.vm.pose[name] = math.Round(vm:GetPoseParameter(name), 3)
        end
        for i = 0, vm:GetNumBodyGroups() - 1 do
            t.vm.bodygroups[vm:GetBodygroupName(i)] = vm:GetBodygroup(i)
        end
        if CLIENT then
            // where the muzzle and the camera attachment land on screen, for sight checks
            t.vm.screen = {}
            for _, att in ipairs({"muzzle", "eject", "cam"}) do
                local id = vm:LookupAttachment(att)
                if id > 0 then
                    local a = vm:GetAttachment(id)
                    if a then
                        local s = a.Pos:ToScreen()
                        t.vm.screen[att] = {math.Round(s.x), math.Round(s.y), s.visible}
                    end
                end
            end
            // where the bore axis (muzzle attachment forward, remapped to the eye's axes) meets
            // the screen far away: on the centre when the sight picture is aligned
            local mid = vm:LookupAttachment("muzzle")
            local ma = mid > 0 and vm:GetAttachment(mid)
            if ma then
                local eyeang = ply:EyeAngles()
                local fwd, best = eyeang:Forward(), 0
                for _, a in ipairs({ma.Ang:Forward(), ma.Ang:Right(), ma.Ang:Up()}) do
                    local d = a:Dot(eyeang:Forward())
                    if math.abs(d) > math.abs(best) then fwd, best = (d < 0 and -a or a), d end
                end
                local s = (ply:EyePos() + fwd * 4096):ToScreen()
                t.vm.axis = {math.Round(s.x), math.Round(s.y), s.visible}
            end
            t.screen = {ScrW(), ScrH()}
            t.fov = ply:GetFOV()
        end
    end
    return t
end

// ---------------------------------------------------------------------------------------
// Prediction trace: the active weapon's state after every Think, on both realms
// ---------------------------------------------------------------------------------------
//
// Match by CUserCmd:CommandNumber, weapon entity and hook. CurTime can be adjusted as the
// client's tick base is corrected; engine.TickCount is the processing tick, not command ID.
// These are diagnostic samples, NOT the engine's acknowledged prediction snapshots. Think
// runs before movement on the client and after it on the server; movement samples cannot be
// compared here. Replaying an unacknowledged command is normal and is not an error count.
// Use cl_showerror 2 for the engine's actual field errors.

// plain Lua fields the bases keep that are not networked; recorded to show where they drift
H.PtracePlain = {"ThrowReleaseAt", "LitUntil", "BayonetChargeReady", "NextRepairTick", "WasRunning",
                 "SlashCount", "WindupKey", "ViewModel", "FuseBurning", "PoseRecoilAvailable"}
H.PtraceKeys = {IN_ATTACK, IN_ATTACK2, IN_RELOAD, IN_USE, IN_SPEED, IN_WALK, IN_DUCK, IN_JUMP,
                IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT}

H.Ptrace = nil // {name, records}

local function enc(v)
    if isnumber(v) then return math.Round(v, 4) end
    if isvector(v) then return vecs(v) end
    if isangle(v) then return angs(v) end
    if isentity(v) then return IsValid(v) and v:EntIndex() or -1 end
    if isbool(v) or isstring(v) then return v end
    return v == nil and "nil" or tostring(v)
end

function H.PtraceRecord(wep, phase)
    local owner = wep:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    if GetPredictionPlayer() != owner then return end

    local cmd = owner:GetCurrentCommand()
    if !cmd or cmd:CommandNumber() == 0 then return end
    local r = {tick = engine.TickCount(), ct = math.Round(CurTime(), 4), first = IsFirstTimePredicted(),
               frame = FrameNumber(), wep = wep:GetClass(), ent = wep:EntIndex(),
               cmd = cmd:CommandNumber(), cmdtick = cmd:TickCount(), buttons = cmd:GetButtons(),
               phase = phase}
    if CLIENT then r.upct = math.Round(UnPredictedCurTime(), 4) end

    r.clip1, r.clip2, r.ammo1, r.ammo2 = wep:Clip1(), wep:Clip2(), wep:Ammo1(), wep:Ammo2()
    r.npf = math.Round(wep:GetNextPrimaryFire(), 4)
    r.nsf = math.Round(wep:GetNextSecondaryFire(), 4)
    r.weapon_model_index = wep:GetInternalVariable("m_iViewModelIndex")
    r.holdtype = wep:GetHoldType()
    r.timers = istable(wep.ActiveTimers) and #wep.ActiveTimers or 0

    if wep.GetNetworkVars then
        for k, v in pairs(wep:GetNetworkVars() or {}) do
            r["nv_" .. k] = enc(v)
        end
    end
    for _, k in ipairs(H.PtracePlain) do
        if wep[k] != nil then r["f_" .. k] = enc(wep[k]) end
    end

    local vm = owner:GetViewModel()
    if IsValid(vm) then
        local seq = vm:GetSequence()
        r.vm_seq = vm:GetSequenceName(seq)
        r.vm_rate = math.Round(vm:GetPlaybackRate(), 3)
        r.vm_cycle = math.Round(vm:GetCycle(), 3)
        r.vm_model = vm:GetModel()
        r.vm_model_index = vm:GetInternalVariable("m_nModelIndex")
    end

    r.pos = vecs(owner:GetPos())
    r.vel = vecs(owner:GetVelocity())
    r.eye = angs(owner:EyeAngles())
    r.punch = angs(owner:GetViewPunchAngles())
    r.ground = owner:IsOnGround()
    r.crouch = owner:Crouching()
    if wep.GetWeaponMovement then
        r.movement_speed, r.movement_ground, r.movement_crouch = wep:GetWeaponMovement()
        r.movement_speed = string.format("%.12g", r.movement_speed)
        r.movement_sample = wep.GetMoveSpeed and string.format("%.12g", wep:GetMoveSpeed())
    end
    local keys = 0
    for i, k in ipairs(H.PtraceKeys) do
        if owner:KeyDown(k) then keys = keys + bit.lshift(1, i - 1) end
    end
    r.keys = keys

    return r
end

// The record is taken by a wrapper put on the weapon instance itself, straight after its own
// Think, so it sees exactly what the tick left behind; the class table is not touched.
local function ptraceWrap(wep)
    if wep.HarnessPtraceWrapped then return end
    wep.HarnessPtraceWrapped = true
    for _, phase in ipairs({"Think", "PrimaryAttack", "SecondaryAttack", "Reload", "CaptureMovement"}) do
        local orig = wep[phase]
        if !isfunction(orig) then continue end
        wep[phase] = function(self, ...)
            local ret = orig(self, ...)
            local pt = H.Ptrace
            if pt and self == pt.wep then
                local rec = H.PtraceRecord(self, phase)
                if rec then table.insert(pt.records, rec) end
            end
            return ret
        end
    end
end

// every frame (client) or tick (server): follow the active weapon
local function ptraceFollow(ply)
    local pt = H.Ptrace
    if !pt or !IsValid(ply) then return end
    local wep = ply:GetActiveWeapon()
    if !IsValid(wep) or !wep.MilitaryConflictVietnam then pt.wep = nil return end
    if pt.wep != wep then
        ptraceWrap(wep)
        pt.wep = wep
        table.insert(pt.records, {event = "weapon", wep = wep:GetClass(), tick = engine.TickCount(), ct = math.Round(CurTime(), 4)})
    end
end

function H.PtraceStart(name)
    H.Ptrace = {name = name, records = {}, started = CurTime(), tick = engine.TickCount()}
    log("ptrace start", name)
end

function H.PtraceStop()
    local pt = H.Ptrace
    if !pt then return end
    H.Ptrace = nil
    local out = {schema = 2, name = pt.name, realm = CLIENT and "client" or "server", tickinterval = engine.TickInterval(),
                 started = pt.started, starttick = pt.tick, stopped = CurTime(), stoptick = engine.TickCount(),
                 records = pt.records}
    local side = CLIENT and "client" or "server"
    file.Write(RESULTS .. pt.name .. ".ptrace." .. side .. ".json", util.TableToJSON(out))
    log("ptrace stop", pt.name, #pt.records .. " records")
    if CLIENT then
        file.Write(RESULTS .. pt.name .. ".ptrace.done.txt", "1")
    end
end

if CLIENT then
    hook.Add("Think", "MCV_HarnessPtrace", function() ptraceFollow(LocalPlayer()) end)
else
    hook.Add("PlayerPostThink", "MCV_HarnessPtrace", function(ply)
        if H.Ptrace and ply == player.GetAll()[1] then ptraceFollow(ply) end
    end)
end

// ---------------------------------------------------------------------------------------
// Client: screenshots, reports, marker
// ---------------------------------------------------------------------------------------

if CLIENT then
    hook.Add("InitPostEntity", "MCV_HarnessClientReady", function()
        file.Write(ROOT .. "client_ready.txt", os.date("%H:%M:%S ") .. game.GetMap())
    end)
    H.PendingShot = nil
    H.Marker = false

    // H.Marker forces the development readout on for a marked screenshot; it is drawn by
    // mcv/client/cl_devhud.lua, which also brings it up on its own with `developer 1`

    hook.Add("PostRender", "MCV_HarnessCapture", function()
        if !H.PendingShot then return end
        // wait one frame so the marker state is drawn
        if H.PendingShot.frames > 0 then
            H.PendingShot.frames = H.PendingShot.frames - 1
            return
        end
        local name = H.PendingShot.name
        H.PendingShot = nil
        local data = render.Capture({format = "png", x = 0, y = 0, w = ScrW(), h = ScrH(), alpha = false})
        if data then
            file.Write(SHOTS .. name .. ".png", data)
            log("shot", name, #data .. " bytes")
        else
            log("shot", name, "capture failed")
        end
        file.Write(SHOTS .. name .. ".done.txt", "1")
    end)

    net.Receive("mcv_harness", function()
        local kind = net.ReadString()
        local arg = net.ReadString()
        if kind == "shot" then
            H.Marker = net.ReadBool()
            H.PendingShot = {name = arg, frames = 2}
        elseif kind == "report" then
            file.Write(RESULTS .. arg .. ".client.json", util.TableToJSON(H.WeaponState(LocalPlayer()), true))
            file.Write(RESULTS .. arg .. ".client.done.txt", "1")
        elseif kind == "clua" then
            local fn = CompileString("local ply = ... " .. arg, "harness_clua", false)
            if isfunction(fn) then
                local ok, err = pcall(fn, LocalPlayer())
                if !ok then log("clua error", tostring(err)) end
            else
                log("clua compile error", tostring(fn))
            end
        elseif kind == "tap" then
            local input = util.JSONToTable(arg)
            LocalPlayer():ConCommand(input.key)
            timer.Simple(input.hold, function()
                LocalPlayer():ConCommand("-" .. string.sub(input.key, 2))
                file.Write(RESULTS .. input.done, "1")
            end)
        elseif kind == "marker" then
            H.Marker = arg == "1"
        elseif kind == "ptrace" then
            if arg == "" then
                H.PtraceStop()
            else
                H.PtraceStart(arg)
            end
        end
    end)
    return
end

// ---------------------------------------------------------------------------------------
// Server: queue processing
// ---------------------------------------------------------------------------------------

H.Job = nil // {name, lines, i, waituntil, waitfile, results}

local function send(ply, kind, arg, flag)
    net.Start("mcv_harness")
    net.WriteString(kind)
    net.WriteString(arg or "")
    net.WriteBool(flag or false)
    net.Send(ply)
end

local function firstPlayer()
    return player.GetAll()[1]
end

local function finishJob(job)
    file.Write(RESULTS .. job.name .. ".json", util.TableToJSON(job.results, true))
    file.Write(RESULTS .. job.name .. ".done.txt", "1")
    log("job", job.name, "done")
end

local function step(job, ply, line)
    local cmd, rest = string.match(line, "^(%S+)%s*(.-)%s*$")
    if !cmd then return end
    local args = string.Explode(" ", rest)
    table.insert(job.results.log, line)

    if cmd == "give" then
        local w = ply:Give(rest)
        if IsValid(w) then
            timer.Simple(0.05, function() if IsValid(ply) then ply:SelectWeapon(rest) end end)
        else
            table.insert(job.results.errors, "give failed: " .. rest)
        end
        job.waituntil = CurTime() + 0.3
    elseif cmd == "select" then
        ply:SelectWeapon(rest)
        job.waituntil = CurTime() + 0.2
    elseif cmd == "strip" then
        ply:StripWeapons()
    elseif cmd == "pos" then
        ply:SetPos(Vector(tonumber(args[1]) or 0, tonumber(args[2]) or 0, tonumber(args[3]) or 0))
        ply:SetLocalVelocity(vector_origin)
    elseif cmd == "ang" then
        ply:SetEyeAngles(Angle(tonumber(args[1]) or 0, tonumber(args[2]) or 0, tonumber(args[3]) or 0))
    elseif cmd == "noclip" then
        ply:SetMoveType(ply:GetMoveType() == MOVETYPE_NOCLIP and MOVETYPE_WALK or MOVETYPE_NOCLIP)
    elseif cmd == "god" then
        ply:GodEnable()
    elseif cmd == "key" then
        ply:ConCommand(rest)
    elseif cmd == "tap" then
        local key = args[1]
        local hold = tonumber(args[2]) or 0.1
        // Time both edges on the client: lagged server packets can otherwise deliver
        // +attack and -attack in one frame, without producing an attacking command.
        local done = job.name .. "_tap" .. job.i .. ".done.txt"
        file.Delete(RESULTS .. done)
        send(ply, "tap", util.TableToJSON({key = key, hold = hold, done = done}))
        job.waitfile = RESULTS .. done
    elseif cmd == "wait" then
        job.waituntil = CurTime() + (tonumber(rest) or 1)
    elseif cmd == "hud" then
        ply:ConCommand("cl_drawhud " .. rest)
    elseif cmd == "shot" then
        local name = args[1]
        file.Delete(SHOTS .. name .. ".done.txt")
        file.Delete(SHOTS .. name .. ".png")
        send(ply, "shot", name, args[2] == "marker")
        job.waitfile = SHOTS .. name .. ".done.txt"
        table.insert(job.results.shots, name)
    elseif cmd == "report" then
        local name = args[1]
        file.Delete(RESULTS .. name .. ".client.done.txt")
        file.Write(RESULTS .. name .. ".server.json", util.TableToJSON(H.WeaponState(ply), true))
        send(ply, "report", name)
        job.waitfile = RESULTS .. name .. ".client.done.txt"
        table.insert(job.results.reports, name)
    elseif cmd == "spawn" then
        local class = args[1]
        local dist = tonumber(args[2]) or 300
        local ent = ents.Create(class)
        if IsValid(ent) then
            local ang = ply:EyeAngles()
            ent:SetPos(ply:GetPos() + Angle(0, ang.y, 0):Forward() * dist)
            ent:SetAngles(Angle(0, ang.y + 180, 0))
            ent:Spawn()
            ent:Activate()
            table.insert(job.results.spawned, ent:EntIndex())
        else
            table.insert(job.results.errors, "spawn failed: " .. class)
        end
    elseif cmd == "cmd" then
        game.ConsoleCommand(rest .. "\n")
    elseif cmd == "ccmd" then
        ply:ConCommand(rest)
    elseif cmd == "lua" then
        local fn = CompileString("local ply, job = ... " .. rest, "harness_lua", false)
        if isfunction(fn) then
            local ok, err = pcall(fn, ply, job)
            if !ok then table.insert(job.results.errors, "lua: " .. tostring(err)) end
        else
            table.insert(job.results.errors, "lua compile: " .. tostring(fn))
        end
    elseif cmd == "clua" then
        send(ply, "clua", rest)
    elseif cmd == "ptrace" then
        if args[1] == "start" then
            local name = args[2] or job.name
            file.Delete(RESULTS .. name .. ".ptrace.done.txt")
            H.PtraceStart(name)
            send(ply, "ptrace", name)
            table.insert(job.results.ptraces, name)
        elseif args[1] == "stop" then
            local name = H.Ptrace and H.Ptrace.name
            H.PtraceStop()
            send(ply, "ptrace", "")
            if name then job.waitfile = RESULTS .. name .. ".ptrace.done.txt" end
        else
            table.insert(job.results.errors, "ptrace: start <name> or stop")
        end
    elseif cmd == "marker" then
        send(ply, "marker", rest)
    elseif cmd == "quit" then
        finishJob(job)
        H.Job = nil
        game.ConsoleCommand("quit\n")
        return "stop"
    else
        table.insert(job.results.errors, "unknown command: " .. line)
    end
end

local function tick()
    local ply = firstPlayer()
    if !IsValid(ply) then return end

    if !H.Job then
        local files = file.Find(QUEUE .. "*.txt", "DATA")
        if #files == 0 then return end
        table.sort(files)
        local fname = files[1]
        local text = file.Read(QUEUE .. fname, "DATA") or ""
        file.Delete(QUEUE .. fname)
        local lines = {}
        for raw in string.gmatch(text, "[^\r\n]+") do
            local l = string.Trim(raw)
            if l != "" and string.sub(l, 1, 1) != "#" then table.insert(lines, l) end
        end
        H.Job = {name = string.StripExtension(fname), lines = lines, i = 0, results = {log = {}, errors = {}, shots = {}, reports = {}, spawned = {}, ptraces = {}}}
        log("job", H.Job.name, #lines .. " commands")
    end

    local job = H.Job
    if job.waituntil and CurTime() < job.waituntil then return end
    job.waituntil = nil
    if job.waitfile then
        if !file.Exists(job.waitfile, "DATA") then
            job.waitstart = job.waitstart or CurTime()
            if CurTime() - job.waitstart > 10 then
                table.insert(job.results.errors, "timed out waiting for " .. job.waitfile)
                job.waitfile = nil
                job.waitstart = nil
            else
                return
            end
        else
            job.waitfile = nil
            job.waitstart = nil
        end
    end

    job.i = job.i + 1
    if job.i > #job.lines then
        finishJob(job)
        H.Job = nil
        return
    end
    if step(job, ply, job.lines[job.i]) == "stop" then return end
end

timer.Create("MCV_Harness", 0.1, 0, function()
    local ok, err = pcall(tick)
    if !ok then log("tick error", tostring(err)) end
end)

hook.Add("PlayerInitialSpawn", "MCV_Harness", function(ply)
    file.Write(ROOT .. "ready.txt", os.date("%H:%M:%S ") .. game.GetMap())
    log("ready", game.GetMap())
end)

log("enabled")
