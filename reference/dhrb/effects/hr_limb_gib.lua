local active = {}
local cap = {}
for i = 0, 15 do
	cap[#cap+1] = {0, 0}
	cap[#cap+1] = {math.cos(i*math.pi/8), math.sin(i*math.pi/8)}
	cap[#cap+1] = {math.cos((i+1)*math.pi/8), math.sin((i+1)*math.pi/8)}
end
function EFFECT:Init(data)
	local rag = data:GetEntity()
	if not IsValid(rag) then self.Die=0 return end
	self.Position, self.Normal = data:GetOrigin(), data:GetNormal()
	self.Flesh = HRDismember.Flesh(rag)
	self:SetPos(self.Position)
	local id = data:GetAttachment()
	self.Part = HRDismember.Parts[id]
	if not self.Part then self.Die=0 return end
	local selected = HRDismember.Bones(rag,id)
	self.Velocity = rag:GetNWVector('hr_wound_force_'..self.Part.key)
	self.Rotation, self.Spin = Angle(), VectorRand()*140
	self.Die = CurTime()+20
	self.Model = ClientsideModel(rag:GetModel(), RENDERGROUP_OPAQUE)
	if not IsValid(self.Model) then self.Die=0 return end
	self.Model:SetNoDraw(true); self.Model:DrawShadow(false); self.Model:SetSkin(rag:GetSkin())
	for _, group in ipairs(rag:GetBodyGroups()) do self.Model:SetBodygroup(group.id,rag:GetBodygroup(group.id)) end
	for i=0,#rag:GetMaterials()-1 do self.Model:SetSubMaterial(i,rag:GetSubMaterial(i)) end
	local origin = Matrix();origin:SetTranslation(self.Position)
	local inverse = origin:GetInverse()
	self.Bones = {}
	for i=0,rag:GetBoneCount()-1 do
		local matrix = rag:GetBoneMatrix(i)
		if matrix then
			local localMatrix = inverse*matrix
			if not selected[i] then localMatrix:SetTranslation(vector_origin); localMatrix:SetScale(Vector(.001,.001,.001)) end
			self.Bones[i] = localMatrix
		end
	end
	self.Model:AddCallback('BuildBonePositions',function(model)
		local placement = Matrix();placement:SetTranslation(self.Position);placement:SetAngles(self.Rotation)
		for i,matrix in pairs(self.Bones) do if model:GetBoneMatrix(i) then model:SetBoneMatrix(i,placement*matrix) end end
	end)
	self:SetRenderBounds(Vector(-45,-45,-45),Vector(45,45,45))
	active[#active+1] = self
	if #active>20 then local old=table.remove(active,1);if IsValid(old) then old.Die=0 end end
end
function EFFECT:Think()
	if CurTime()>=self.Die or not IsValid(self.Model) then if IsValid(self.Model) then self.Model:Remove() end return false end
	local dt=math.min(FrameTime(),.05)
	if not self.Resting then
		self.Velocity = self.Velocity+Vector(0,0,-500)*dt
		local tr=util.TraceHull({start=self.Position,endpos=self.Position+self.Velocity*dt,mins=Vector(-3,-3,-3),maxs=Vector(3,3,3),mask=MASK_SOLID_BRUSHONLY})
		self.Position=tr.HitPos
		if tr.Hit then
			self.Position=self.Position+tr.HitNormal*.1
			self.Velocity=(self.Velocity-2*self.Velocity:Dot(tr.HitNormal)*tr.HitNormal)*.28
			if self.Velocity:Length()<35 then self.Resting=true end
		end
		self.Rotation=self.Rotation+Angle(self.Spin.x,self.Spin.y,self.Spin.z)*dt
	end
	self:SetPos(self.Position)
	return true
end
function EFFECT:Render()
	if not IsValid(self.Model) then return end
	local normal=Vector(self.Normal);normal:Rotate(self.Rotation)
	local old=render.EnableClipping(true)
	render.PushCustomClipPlane(normal,normal:Dot(self.Position))
	render.SetBlend(math.Clamp((self.Die-CurTime())/3,0,1))
	self.Model:SetPos(self.Position);self.Model:InvalidateBoneCache();self.Model:SetupBones();self.Model:DrawModel()
	render.PopCustomClipPlane();render.EnableClipping(old)
	render.SetMaterial(self.Flesh)
	local basis = normal:Angle()
	local right, up = basis:Right(), basis:Up()
	local radius = self.Part.radius * self.Model:GetModelScale()
	mesh.Begin(MATERIAL_TRIANGLES, 16)
	for _, point in ipairs(cap) do
		mesh.Position(self.Position + (right*point[1] + up*point[2])*radius)
		mesh.Normal(-normal)
		mesh.TexCoord(0, .25 + point[1]*.19, .20 + point[2]*.15)
		mesh.Color(255, 255, 255, 255)
		mesh.AdvanceVertex()
	end
	mesh.End()
	render.SetBlend(1)
end

function EFFECT:OnRemove()
	if IsValid(self.Model) then self.Model:Remove() end
end
hook.Add('PreCleanupMap', 'hr_limb_gibs', function()
	for _, effect in ipairs(active) do
		if IsValid(effect) and IsValid(effect.Model) then effect.Model:Remove() end
	end
	active = {}
end)
