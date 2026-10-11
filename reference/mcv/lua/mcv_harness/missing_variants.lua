MCVMissingVariants = {}
local T = MCVMissingVariants
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"
local specs = {
    mcv_m16a1_sog = {clip=30, reserve=60, body="001100", world="1010", category="Assault Rifles"},
    mcv_m16a1_xm3 = {clip=30, reserve=120, body="001010", world="0011", category="Light-Machine Guns"},
    mcv_kar98_zf41 = {clip=5, reserve=20, body="00200", world="00200", category="Bolt-Action Rifles"},
    mcv_stg44_zf41 = {clip=20, reserve=100, body="021", world="021", category="Assault Rifles"}
}

function T.Audit()
    local rows = {}
    for class, spec in pairs(specs) do
        local w = weapons.Get(class)
        assert(w and w.Spawnable and w.MilitaryConflictVietnam and w.NPCUsable, class)
        assert(w.Primary.ClipSize==spec.clip and w.Primary.DefaultClip==spec.reserve, class.." ammo")
        assert(w.BodyGroups==spec.body and w.WorldModelBodyGroups==spec.world, class.." bodygroups")
        assert(w.SubCategory==spec.category, class.." category")
        local listed = list.Get("Weapon")[class]
        assert(listed and listed.Category=="Military Conflict: Vietnam", class.." spawn menu")
        if CLIENT then
            assert(!Material(w.IconOverride):IsError(), class.." icon")
            if w.HasScope then assert(!w.ScopeMaterial:IsError(), class.." reticle") end
        end
        rows[#rows+1] = {class=class,clip=w.Primary.ClipSize,reserve=w.Primary.DefaultClip,category=w.SubCategory}
    end
    file.Write(root.."missing_variants_"..(CLIENT and "client" or "server")..".json",util.TableToJSON(rows,true))
end

function T.CheckHeld(ply, checkScope)
    local w, vm = ply:GetActiveWeapon(), ply:GetViewModel()
    assert(specs[w:GetClass()])
    for i=0,vm:GetNumBodyGroups()-1 do
        local expected=tonumber(string.sub(w.BodyGroups,i+1,i+1)) or 0
        assert(vm:GetBodygroup(i)==expected, w:GetClass().." viewmodel bodygroup "..i)
    end
    if checkScope and CLIENT then
        assert(w:GetSightAmountVisual()>0.9)
        assert(w.RenderingRTScope, "scope render target inactive")
        assert(string.EndsWith(vm:GetMaterials()[w.RTScopeMaterialIndex+1], "crosshair_zf41a"), "wrong glass surface")
    end
end
