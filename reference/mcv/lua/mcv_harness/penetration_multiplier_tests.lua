if not SERVER then return end
local ply = player.GetHumans()[1]
local w = ply:GetActiveWeapon()
assert(w:GetClass() == "mcv_m16a1", "equip the M16A1")
local all = GetConVar(MCV.CategoryConVarName(MCV.CATEGORY_ALL, "penetration"))
local category = GetConVar(MCV.CategoryConVarName(w.SubCategory, "penetration"))
local other = GetConVar(MCV.CategoryConVarName("Pistols", "penetration"))
local previous = {all:GetFloat(),category:GetFloat(),other:GetFloat()}
local rows = {}
local function expect(a,c,o,mult)
    all:SetFloat(a) category:SetFloat(c) other:SetFloat(o)
    for mat, name in pairs({[MAT_WOOD]="Wood",[MAT_METAL]="Metal",[MAT_GLASS]="Glass",[MAT_CONCRETE]="Concrete",[MAT_PLASTIC]="Other"}) do
        local depth = w:GetPenetrationStats(mat)
        assert(math.abs(depth-w[name.."PenetrationDepth"]*mult)<.001, name .. " slider product")
    end
    rows[#rows+1] = {all=a,category=c,unrelated=o,effective=mult}
end
local ok, err = xpcall(function()
    expect(1,1,1,1)
    expect(2,1,1,2)
    expect(1,.5,1,.5)
    expect(2,3,9,6)
    expect(0,3,1,0)
    expect(2,0,1,0)
end,debug.traceback)
all:SetFloat(previous[1]) category:SetFloat(previous[2]) other:SetFloat(previous[3])
file.Write("mcv_harness/p27016/results/penetration_multipliers.json",util.TableToJSON({ok=ok,results=rows,error=err},true))
assert(ok,err)
print("[penetration multipliers] six cases, five materials each passed")
