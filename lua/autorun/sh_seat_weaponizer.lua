local ENTITY = FindMetaTable("Entity")
local eGetAngles = ENTITY.GetAngles

local function GetOffsetEyePos(vehicle, parent, parentT, eyePos)
    if !parent or parent == NULL or !(parentT.IsSimfphyscar or parent.IsGlideVehicle) then
        return
    end

    -- WORKAROUND: Simfphys and Glide vehicles can define a custom view origin via CalcVehicleView or CalcView respectively.
    if parentT.IsSimfphyscar then
        local customView = parentT.customview

        -- HACK: customview is not present on SERVER by default.
        if !parentT.customview then
            local vehicleList = list.GetForEdit("simfphys_vehicles")[parent:GetSpawn_List()]

            if vehicleList and vehicleList.Members.FirstPersonViewPos then
                parent.customview = vehicleList.Members.FirstPersonViewPos
            else
                parent.customview = Vector(0, -9, 5)
            end

            customView = parent.customview
        end

        local isDriver = vehicle == parent:GetDriverSeat()
        local sEyePos = Vector(0, 0, 0)
        sEyePos:Set(eyePos)

        local vAngles = eGetAngles(vehicle)

        if isDriver then
            sEyePos:Add(vAngles:Forward() * customView.x)
            sEyePos:Add(vAngles:Right() * customView.y)
            sEyePos:Add(vAngles:Up() * customView.z)
        else
            sEyePos:Add(vAngles:Up() * 5)
        end

        return sEyePos
    elseif parentT.IsGlideVehicle then
        local localEyePos = parent:WorldToLocal(eyePos)
        local localPos = parent:GetFirstPersonOffset(vehicle:GetNWInt("GlideSeatIndex", 0), localEyePos)

        return parent:LocalToWorld(localPos)
    end
end

local PLAYER = FindMetaTable("Player")
local pGetAllowWeaponsInVehicle = PLAYER.GetAllowWeaponsInVehicle
local eEyePos = ENTITY.EyePos
local vGetThirdPersonMode = FindMetaTable("Vehicle").GetThirdPersonMode
local eGetTable = ENTITY.GetTable

local function GetEyePos(owner, vehicle, parent, parentT)
    local eyePos = eEyePos(owner)

    if vGetThirdPersonMode(vehicle) then
        return eyePos
    end

    parentT = parentT or eGetTable(parent)

    return GetOffsetEyePos(vehicle, parent, parentT, eyePos) or eyePos
end

local developer = GetConVar("developer")

hook.Add("EntityFireBullets", "SeatWeaponizer.AdjustSource", function(entity, data)
    local isPlayer = entity:IsPlayer() and entity:InVehicle()
    local isWeapon = entity:IsWeapon()

    -- If we're a weapon, we must have an owner.
    local owner = isWeapon and entity:GetOwner() or entity

    if !isPlayer and !(isWeapon and owner:IsPlayer() and owner:InVehicle()) then
        return
    end

    local vehicle = owner:GetVehicle()
    local vParent = vehicle:GetParent()
    local eyePos = GetEyePos(owner, vehicle, vParent)
    local forward = owner:GetAimVector():Angle():Forward()

    -- This traces backwards into the vehicle, hitting the closest point outside the vehicle pointing to the player's EyePos (shootpos).
    local trace = util.TraceLine({
        start = eyePos + forward * 1024,
        endpos = eyePos,
        filter = {vehicle, vParent},
        whitelist = true,
        ignoreworld = true
    })

    -- WORKAROUND: Some weapon bases really don't like being so close to a solid object, so we move the bullet Src forward a bit.
    data.Src = trace.HitPos + forward * 8

    -- ISSUE: https://github.com/Facepunch/garrysmod-requests/issues/1897 + https://github.com/Facepunch/garrysmod-requests/issues/969
    if IsValid(vParent) and vParent != NULL then
        data.IgnoreEntity = vParent
    else
        data.IgnoreEntity = vehicle
    end

    if developer:GetInt() >= 1 then
        if SERVER then
            debugoverlay.Cross(data.Src, 10, 5, Color(156, 241, 255, 200), true)
        else
            debugoverlay.Cross(data.Src, 10, 5, Color(255, 221, 102, 255), true)
        end
    end

    return true
end)

-- WORKAROUND: Filter out vehicle for extra safety.
-- Not needed anymore because of us adding forward * 8 to our bullet source.
-- hook.Add("SWCSPenetratationIgnoreEntities", "SeatWeaponizer.FilterVehicle", function(wep, owner, filter)
--     if !owner:IsPlayer() or !owner:InVehicle() or !owner:GetAllowWeaponsInVehicle() then
--         return
--     end

--     local vehicle = owner:GetVehicle()

--     table.insert(filter, vehicle)

--     local vParent = vehicle:GetParent()

--     if vParent and vParent != NULL then
--         table.insert(filter, vParent)
--     end
-- end)

local pGetActiveWeapon = PLAYER.GetActiveWeapon

-- HACK: https://gitlab.com/cynhole/swcs/-/blob/master/lua/weapons/weapon_swcs_base/shared.lua#L933
-- PlayerTick does not run when inside a vehicle. VehicleMove is called instead.
hook.Add("VehicleMove", "swcs.ProcessActivities", function(ply, veh, mv)
    if !IsValid(ply) then
        return
    end

    local wep = pGetActiveWeapon(ply)

    if !IsValid(wep) or wep == NULL then
        return
    end

    local tbl = wep:GetTable()

    if !weapons.IsBasedOn(tbl.ClassName, "weapon_swcs_base") then
        return
    end

    if tbl.m_bProcessActivities then
        tbl.ProcessActivities(wep, tbl)

        tbl.m_bProcessActivities = false
    end
end)

if CLIENT then
    local eGetOwner = ENTITY.GetOwner
    local pGetVehicle = PLAYER.GetVehicle
    local eGetParent = ENTITY.GetParent

    -- HACK: Simfphys vehicles modify the seats normal view origin via CalcVehicleView, this makes viewmodels heavily offset.
    -- So instead, we get our EyePos adjusted by the custom view defined in the vehicle.
    hook.Add("CalcViewModelView", "SeatWeaponizer.SimfphysFix", function(wep, vm, oldPos, oldAng, pos, ang)
        local ply = eGetOwner(wep)

        if !pGetAllowWeaponsInVehicle(ply) then
            return
        end

        local veh = pGetVehicle(ply)

        if !IsValid(veh) then
            return
        end

        local parent = eGetParent(veh)

        if !IsValid(parent) or parent == NULL or !(parent.IsGlideVehicle or parent.IsSimfphyscar) then
            return
        end

        return GetEyePos(ply, veh, parent), ang
    end)
else
    local enabled = CreateConVar("sv_seat_weaponizer", 1, FCVAR_ARCHIVE, "Enables/disables weapons being allowed in vehicles.", 0, 1)
    local passengersOnly = CreateConVar("sv_seat_weaponizer_passengers_only", 0, FCVAR_ARCHIVE, "Enables/disables weapons being allowed only for passengers.", 0, 1)
    local pSetAllowWeaponsInVehicle = PLAYER.SetAllowWeaponsInVehicle

    hook.Add("PlayerEnteredVehicle", "SeatWeaponizer.Enable", function(ply, veh, role)
        if !enabled:GetBool() then
            return
        end

        local vehicle = CLib.GetVehicle(veh)

        if passengersOnly:GetBool() and ply:IsDriver(vehicle) then
            pSetAllowWeaponsInVehicle(ply, false)

            return
        end

        pSetAllowWeaponsInVehicle(ply, true)
    end)

    hook.Add("PlayerLeaveVehicle", "SeatWeaponizer.Disable", function(ply, veh)
        pSetAllowWeaponsInVehicle(ply, false)

        -- WORKAROUND: This fixes the players EyeAngles being tilted after exiting.
        timer.Simple(0, function()
            if !IsValid(ply) then
                return
            end

            local angles = ply:EyeAngles()
            angles.r = 0

            ply:SetEyeAngles(angles)
        end)
    end)

    local eIsPlayer = ENTITY.IsPlayer

    -- Sanity check for weapons that fire explosive projectiles.
    hook.Add("EntityTakeDamage", "SeatWeaponizer.ExplosiveFilter", function(target, dmgInfo)
        if eIsPlayer(target) and pGetAllowWeaponsInVehicle(target) and target:InVehicle() and target == dmgInfo:GetAttacker() and !dmgInfo:IsExplosionDamage() then
            dmgInfo:SetDamage(0)
        end
    end)
end