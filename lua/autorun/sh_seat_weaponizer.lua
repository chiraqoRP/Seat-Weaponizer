local ENTITY = FindMetaTable("Entity")
local PLAYER = FindMetaTable("Player")
local eGetAngles = ENTITY.GetAngles

local function GetSimfphysOffset(owner, vehicle, parent, parentT, eyePos, eyeAng)
    local customView = parentT.customview

    -- HACK: ENT.customview is not present on SERVER by default.
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

    return sEyePos, eyeAng
end

local function GetGlideOffset(owner, parent, parentT, eyePos)
    local localEyePos = parent:WorldToLocal(eyePos)
    local localPos = parent:GetFirstPersonOffset(owner:GlideGetSeatIndex(), localEyePos)

    if CLIENT then
        eyeAng = Glide.Camera.angles
    else
        eyeAng = owner.GlideCam.angle
    end

    return parent:LocalToWorld(localPos), eyeAng
end

local pGetAllowWeaponsInVehicle = PLAYER.GetAllowWeaponsInVehicle
local eEyePos = ENTITY.EyePos
local eGetTable = ENTITY.GetTable

local function GetEyeOffset(owner, vehicle, parent, parentT)
    local eyePos = eEyePos(owner)

    if !IsValid(parent) then
        return eyePos
    end

    parentT = parentT or eGetTable(parent)

    if !parentT.IsSimfphyscar and !parentT.IsGlideVehicle then
        return eyePos
    end

    if parentT.IsGlideVehicle then
        eyePos, eyeAng = GetGlideOffset(owner, parent, parentT, eyePos)
    else
        eyePos, eyeAng = GetSimfphysOffset(owner, vehicle, parent, parentT, eyePos, eyeAng)
    end

    return eyePos, eyeAng
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
    local eyePos, eyeAng = GetEyeOffset(owner, vehicle, vParent)
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

    if eyeAng then
        data.Dir = eyeAng:Forward()
    end

    -- ISSUE: https://github.com/Facepunch/garrysmod-requests/issues/1897 + https://github.com/Facepunch/garrysmod-requests/issues/969
    if IsValid(vParent) then
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

--     if IsValid(vParent) then
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

    if !IsValid(wep) then
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

local hud_fastswitch = GetConVar("hud_fastswitch")
local blacklist = {
    ["weapon_physgun"] = true,
    ["gmod_tool"] = true,
    ["gmod_camera"] = true,
    ["weapon_physcannon"] = true,
    ["weapon_crowbar"] = true,
    ["weapon_stunstick"] = true
}

-- Actually selects the weapon that was last picked up, which is good enough for our use-case.
local function SelectBestWeapon(ply)
    local pWeapons = ply:GetWeapons()

    for i = #pWeapons, 1, -1 do
        local weapon = pWeapons[i]

        if IsValid(weapon) and !blacklist[weapon:GetClass()] then
            input.SelectWeapon(weapon)

            break
        end
    end
end

hook.Add("PlayerSwitchWeapon", "SeatWeaponizer.Blacklist", function(ply, oldWeapon, newWeapon)
	if !pGetAllowWeaponsInVehicle(ply) or !IsValid(newWeapon) or !blacklist[newWeapon:GetClass()] then
        return
    end

    -- WORKAROUND: Setting hud_fastswitch to 1 prevents switching to any valid weapon with this hook.
    -- This is because our oldWeapon is NULL, but the surrounding weapons are almost always weapon_physgun and gmod_tool.
    -- We fix this by switching to the newest weapon that isn't blacklisted.
    if CLIENT and hud_fastswitch:GetBool() and !IsValid(oldWeapon) and IsFirstTimePredicted() then
        SelectBestWeapon(ply)
    end

    return true
end)

if CLIENT then
    local eGetOwner = ENTITY.GetOwner
    local pGetVehicle = PLAYER.GetVehicle
    local eGetParent = ENTITY.GetParent

    -- HACK: Simfphys and Glide vehicles modify the seats normal view origin via CalcVehicleView, this makes viewmodels heavily offset.
    -- So instead, we get our EyePos adjusted by the custom view defined in the vehicle.
    hook.Add("CalcViewModelView", "SeatWeaponizer.SimfphysFix", function(wep, vm, oldPos, oldAng, pos, ang)
        local ply = eGetOwner(wep)

        if !IsValid(ply) or !IsValid(wep) or !pGetAllowWeaponsInVehicle(ply) then
            return
        end

        -- WORKAROUND: Users have been reporting crashes with TacRP weapons in simfphys vehicles.
        if wep.ArcticTacRP then
            return
        end

        local veh = pGetVehicle(ply)

        if !IsValid(veh) then
            return
        end

        local parent = eGetParent(veh)

        if !IsValid(parent) or !(parent.IsSimfphyscar or parent.IsGlideVehicle) then
            return
        end

        local vPos, vAng = GetEyeOffset(ply, veh, parent)

        return vPos, vAng
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

        -- HACK: Glide vehicles can have turrets, but not every vehicle has the Turret/TurretSeat NW vars.
        -- REFERENCE: https://github.com/StyledStrike/gmod-glide/blob/main/lua/entities/gtav_insurgent.lua#L208
        if vehicle.IsGlideVehicle then
            local getTurretSeat = vehicle.GetTurretSeat

            if isfunction(getTurretSeat) then
                local turretSeat = getTurretSeat(vehicle)

                if IsValid(turretSeat) and turretSeat == veh then
                    pSetAllowWeaponsInVehicle(ply, false)

                    return
                end
            end
        end

        if passengersOnly:GetBool() and ply:IsDriver(vehicle) and !vehicle.playerdynseat then
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