--#region Variables

local npc
local tempVehicle
local hasStarted = false
local shownTextUI = false
local impoundBlip = 0

local config = require "config"
local framework = require(("modules.bridge.%s.client"):format(config.framework))
local utils = require "modules.utils.client"

--#endregion Variables

--#region Functions

---@param model? string | number
---@param type? string
---@return string | nil
local function getVehicleIcon(model, type)
    if not model and not type then return end

    local icon = type or config.vehicleClasses[GetVehicleClassFromName(model --[[@as string | number]])]
    icon = config.convertIcons[icon] or icon

    return icon
end

---@param plate string
---@param data Vehicle
---@param coords vector4
---@return boolean
---@return string
local function spawnVehicle(plate, data, coords)
    plate = plate and plate:upper() or plate

    if tempVehicle then
        if tempVehicle ~= plate then
            while tempVehicle do
                Wait(100)
            end
        else
            return false, locale("already_spawning")
        end
    end

    tempVehicle = plate
    lib.requestModel(data.model)

    local netVehicle = lib.callback.await("bGarage:server:spawnVehicle", false, data.model, type(coords) == "vector4" and coords, plate)
    if not netVehicle then
        TriggerServerEvent("bGarage:server:vehicleSpawnFailed", plate)
        tempVehicle = nil
        return false, locale("not_registered")
    end

    local attempts = 0
    while netVehicle == 0 or not NetworkDoesEntityExistWithNetworkId(netVehicle) do
        Wait(10)
        attempts += 1
        if attempts == 100 then
            break
        end
    end

    local vehicle = netVehicle == 0 and 0 or not NetworkDoesEntityExistWithNetworkId(netVehicle) and 0 or NetToVeh(netVehicle)
    if not vehicle or vehicle == 0 then
        TriggerServerEvent("bGarage:server:vehicleSpawnFailed", plate, netVehicle)
        tempVehicle = nil
        return false, locale("failed_to_spawn")
    end

    Wait(500) -- Wait for the server to completely register the vehicle

    PlaceObjectOnGroundProperly(vehicle)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    SetEntityAsMissionEntity(vehicle, true, true)
    Entity(vehicle).state:set("vehicleProperties", data.props, true)
    SetVehicleProperties(vehicle, data.props) -- Ensure vehicle props are set after the vehicle spawns

    tempVehicle = nil

    return true, locale("successfully_spawned")
end

---@todo improve handling of vehicle properties - currently works fine but can be done better
---@param bagName string
---@param key string
---@param value any
AddStateBagChangeHandler("vehicleProperties", "vehicle", function(bagName, key, value)
    if not value then return end

    local netId = tonumber(bagName:gsub("entity:", ""), 10)
    local entity, timeout = false, 0

    while not entity and timeout < 1000 do
        entity = NetworkDoesEntityExistWithNetworkId(netId)
        timeout += 1
        Wait(0)
    end

    if not entity then
        return lib.print.warn(("Statebag '(%s)' timed out after waiting '%s' ticks for entity creation on '%s'."):format(bagName, timeout, key))
    end

    Wait(500)

    local vehicle = NetworkDoesEntityExistWithNetworkId(netId) and NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or NetworkGetEntityOwner(vehicle) ~= cache.playerId or not SetVehicleProperties(vehicle, value) then return end

    Entity(vehicle).state:set(key, nil, true)
end)

local function purchaseParkingSpot(price)
    local canPay, reason = lib.callback.await("bGarage:server:payFee", price, config.garage.parking.price, false)
    if not canPay then
        framework.Notify(reason, config.notifications.duration, config.notifications.position, "error", config.notifications.icons[1])
        return
    end

    local entity = cache.vehicle or cache.ped
    local coords = GetEntityCoords(entity)
    local heading = GetEntityHeading(entity)

    local location, status = lib.callback.await("bGarage:server:setParkingSpot", false, vec4(coords.x, coords.y, coords.z, heading))
    framework.Notify(status, config.notifications.duration, config.notifications.position, "success", config.notifications.icons[1])

    if not location then return end

    lib.callback.await("bGarage:server:payFee", price, config.garage.parking.price, true)
end

local function storeVehicle()
    local vehicle = cache.vehicle
    if not vehicle or vehicle == 0 then
        framework.Notify(locale("not_in_vehicle"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[0])
        return
    end

    local plate = GetVehicleNumberPlateText(vehicle)
    ---@type Vehicle?
    local owner = lib.callback.await("bGarage:server:getVehicleOwner", false, plate)
    if not owner then
        framework.Notify(locale("not_owner"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[0])
        return
    end

    ---@type vector4?
    local location = lib.callback.await("bGarage:server:getParkingSpot", false)
    if not location then
        framework.Notify(locale("no_parking_spot"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
        return
    end

    if #(location.xyz - GetEntityCoords(vehicle)) > 5.0 then
        SetNewWaypoint(location.x, location.y)
        framework.Notify(locale("not_in_parking_spot"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
        return
    end

    local props = GetVehicleProperties(vehicle)
    ---@type boolean, string
    local status, reason = lib.callback.await("bGarage:server:setVehicleStatus", false, "parked", plate, props)
    if status then
        SetEntityAsMissionEntity(vehicle, false, false)
        lib.callback.await("bGarage:server:deleteVehicle", false, VehToNet(vehicle))
        framework.Notify(reason, config.notifications.duration, config.notifications.position, "success", config.notifications.icons[0])
    end

    if not status then
        framework.Notify(reason, config.notifications.duration, config.notifications.position, "error", config.notifications.icons[0])
        return
    end
end

local function vehicleList()
    ---@type table<string, Vehicle>
    local vehicles, amount = lib.callback.await("bGarage:server:getOwnedVehicles", false)
    if amount == 0 then
        framework.Notify(locale("no_vehicles"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
        return
    end

    ---@type vector4?
    local location = lib.callback.await("bGarage:server:getParkingSpot", false)

    local options = {
        {
            title = locale("vehicle_amount"):format(amount),
            disabled = true,
        },
    }

    for k, v in pairs(vehicles) do
        local vehicleListOptions = {}

        if v.location == "parked" then
            vehicleListOptions[#vehicleListOptions + 1] = {
                title = locale("menu_subtitle_one"),
                description = locale("menu_description_one"),
                onSelect = function(price)
                    local canPay, reason = lib.callback.await("bGarage:server:payFee", price, config.garage.retrieve.price, false)
                    if not canPay then
                        framework.Notify(reason, config.notifications.duration, config.notifications.position, "error", config.notifications.icons[0])
                        return
                    end

                    if not location then
                        framework.Notify(locale("no_parking_spot"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
                        return
                    end

                    local success, status = spawnVehicle(k, v, location)
                    framework.Notify(status, config.notifications.duration, config.notifications.position, "success", config.notifications.icons[0])

                    if not success then return end

                    lib.callback.await("bGarage:server:payFee", price, config.garage.retrieve.price, true)
                end,
            }
        end

        if v.location == "parked" or v.location == "outside" and not cache.vehicle then
            vehicleListOptions[#vehicleListOptions + 1] = {
                title = locale("menu_subtitle_two"),
                description = locale("menu_description_two"),
                onSelect = function()
                    local coords = v.location == "parked" and location?.xy or v.location == "outside" and lib.callback.await("bGarage:server:getVehicleCoords", false, k)?.xy or nil
                    if not coords then
                        framework.Notify(v.location == "outside" and locale("vehicle_doesnt_exist") or locale("no_parking_spot"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[0] or config.notifications.icons[1])
                        return
                    end

                    if coords then
                        SetNewWaypoint(coords.x, coords.y)
                        framework.Notify(locale("set_waypoint"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
                        return
                    end
                end,
            }
        end

        local make, name = GetMakeNameFromVehicleModel(v.model):firstToUpper(), GetDisplayNameFromVehicleModel(v.model):firstToUpper()
        local icon = v.location == "impound" and "🔴" or v.location == "parked" and "🟢" or "🟡"
        options[#options + 1] = {
            menu = table.type(vehicleListOptions) ~= "empty" and v.location ~= "impound" and ("vehicleList_%s"):format(k) or nil,
            title = ("%s %s - %s"):format(make, name, k),
            icon = getVehicleIcon(v.model, v.type),
            metadata = {
                Location = ("%s %s"):format(icon, v.location:firstToUpper()),
                --Coords = v.location == "impound" and ("(%s, %s, %s)"):format(config.impound.location.x, config.impound.location.y, config.impound.location.z) or v.location == "parked" and location and ("(%s,%s, %s)"):format(location.x, location.y, location.z) or nil,
            },
        }

        if table.type(vehicleListOptions) ~= "empty" then
            lib.registerContext({
                id = ("vehicleList_%s"):format(k),
                menu = "vehicleList_menu",
                title = ("%s %s - %s"):format(make, name, k),
                options = vehicleListOptions,
            })
        end
    end

    lib.registerContext({
        id = "vehicleList_menu",
        title = locale("vehicle_menu_title"),
        options = options,
    })

    shownTextUI = false
    framework.hideTextUI()
    framework.showContext("vehicleList_menu")
end

exports("vehicleList", vehicleList)

lib.addKeybind({
    defaultKey = "l",
    description = "Open the vehicle list",
    name = "vehicleList",
    onPressed = vehicleList
})

local function vehicleImpound()
    ---@type table<string, Vehicle>, number
    local vehicles, amount = lib.callback.await("bGarage:server:getImpoundedVehicles", false)
    if amount == 0 then
        framework.Notify(locale("no_impounded_vehicles"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
        return
    end

    local options = {
        {
            title = locale("vehicle_amount"):format(amount),
            disabled = true,
        },
    }

    for k, v in pairs(vehicles) do
        local make, name = GetMakeNameFromVehicleModel(v.model):firstToUpper(), GetDisplayNameFromVehicleModel(v.model):firstToUpper()
        local icon = v.location == "impound" and "🔴" or v.location == "parked" and "🟢" or "🟡"
        options[#options + 1] = {
            menu = ("vehicleImpound_%s"):format(k),
            title = ("%s %s - %s"):format(make, name, k),
            icon = getVehicleIcon(v.model, v.type),
            metadata = {
                Location = ("%s %s"):format(icon, v.location:firstToUpper()),
                --Coords = v.location == "impound" and ("(%s, %s, %s)"):format(config.impound.location.x, config.impound.location.y, config.impound.location.z) or v.location == "parked" and location and ("(%s,%s, %s)"):format(location.x, location.y, location.z) or nil,
            },
        }

        lib.registerContext({
            id = ("vehicleImpound_%s"):format(k),
            menu = "vehicleImpound_menu",
            title = ("%s %s - %s"):format(make, name, k),
            options = {
                {
                    title = locale("menu_subtitle_one"),
                    description = locale("impound_description"),
                    onSelect = function(price)
                        if config.impound.static then
                            local canPay, reason = lib.callback.await("bGarage:server:payFee", price, config.impound.price, false)
                            if not canPay then
                                framework.Notify(reason, config.notifications.duration, config.notifications.position, "error", config.notifications.icons[1])
                                return
                            end

                            local success, status = spawnVehicle(k, v, config.impound.location)
                            framework.Notify(status, config.notifications.duration, config.notifications.position, "success", config.notifications.icons[1])

                            if not success then return end

                            lib.callback.await("bGarage:server:payFee", price, config.impound.price, true)
                        else
                            local canPay, reason = lib.callback.await("bGarage:server:payFee", price, config.impound.price, false)
                            if not canPay then
                                framework.Notify(reason, config.notifications.duration, config.notifications.position, "error", config.notifications.icons[1])
                                return
                            end

                            ---@type vector4?
                            local location = lib.callback.await("bGarage:server:getParkingSpot", false)
                            if not location then
                                framework.Notify(locale("no_parking_spot"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
                                return
                            end

                            local success, status = spawnVehicle(k, v, location)
                            framework.Notify(status, config.notifications.duration, config.notifications.position, "success", config.notifications.icons[1])

                            if not success then return end

                            lib.callback.await("bGarage:server:payFee", price, config.impound.price, true)
                        end
                    end,
                },
            },
        })
    end

    lib.registerContext({
        id = "vehicleImpound_menu",
        title = locale("impounded_menu_title"),
        options = options,
    })

    shownTextUI = false
    framework.hideTextUI()
    framework.showContext("vehicleImpound_menu")
end

exports("vehicleImpound", vehicleImpound)

if config.impound.static then
    local function onEnter()
        local model = type(config.impound.entity.model) == "string" and joaat(config.impound.entity.model) or config.impound.entity.model
        lib.requestModel(model)
        if not model then return end
        local type = ("male" == "male") and 4 or 5
        npc = CreatePed(type, model, config.impound.entity.location.x, config.impound.entity.location.y, config.impound.entity.location.z, config.impound.entity.location.w, false, true)
        FreezeEntityPosition(npc, true)
        SetEntityInvincible(npc, true)
        SetBlockingOfNonTemporaryEvents(npc, true)
    end

    local function onExit()
        DeletePed(npc)
        npc = nil
    end

    ---@type CPoint
    lib.points.new({
        coords = config.impound.entity.location,
        distance = config.impound.entity.distance,
        onEnter = onEnter,
        onExit = onExit,
    })

    if config.impound.useTarget then
        exports.ox_target:addModel(config.impound.entity.model, {
            {
                label = locale("impound_label"),
                name = "impound_entity",
                icon = "fa-solid fa-car-side",
                distance = 2.5,
                onSelect = function()
                    vehicleImpound()
                end
            },
        })
    else
        CreateThread(function()
            local sleep = 500
            while true do
                sleep = 500
                local menuOpened = false
                local coords = GetEntityCoords(cache.ped)
                local markerLocation = config.impound.marker.location.xyz
                local markerDistance = config.impound.marker.distance

                if #(coords - markerLocation) < markerDistance then
                    if not menuOpened then
                        sleep = 0
                        DrawMarker(config.impound.marker.type, config.impound.marker.location.x, config.impound.marker.location.y, config.impound.marker.location.z, 0.0, 0.0, 0, 0.0, 180.0, 0.0, 1.0, 1.0, 1.0, 20, 200, 20, 50, false, false, 2, true, nil, nil, false)
                        if not shownTextUI then
                            shownTextUI = true
                            framework.showTextUI(locale("impound_show"))
                        end

                        if IsControlJustPressed(0, 38) then
                            vehicleImpound()
                        end
                        menuOpened = true
                    end
                else
                    if menuOpened then
                        menuOpened = false
                        framework.hideContext(false)
                    end

                    if shownTextUI then
                        shownTextUI = false
                        framework.hideTextUI()
                    end
                end
                Wait(sleep)
            end
        end)
    end
end

--#endregion Functions

--#region Callbacks

lib.callback.register("bGarage:client:getTempVehicle", function()
    return tempVehicle
end)

--#endregion Callbacks

--#region Events

RegisterNetEvent("bGarage:client:startedCheck", function()
    if GetInvokingResource() then return end
    hasStarted = true
end)

---@param resource string
AddEventHandler("onResourceStop", function(resource)
    if resource == cache.resource then return end
    RemoveBlip(impoundBlip)
    DeletePed(npc)
end)

--#endregion Events

--#region Commands

---@param args string[]
RegisterCommand("v", function(_, args)
    if not hasStarted then return end

    local action = args[1]
    if action == "buy" then
        purchaseParkingSpot()
    elseif action == "park" then
        storeVehicle()
    elseif action == "list" then
        vehicleList()
    elseif action == "impound" then
        if not config.impound.static then
            vehicleImpound()
        end
    end
end, false)

if config.impound.static then
    TriggerEvent("chat:addSuggestion", "/v", nil, {
        { name = "buy | park | list", help = locale("global_help") },
    })
else
    TriggerEvent("chat:addSuggestion", "/v", nil, {
        { name = "buy | park | list | impound", help = locale("static_help") },
    })
end

RegisterCommand(config.impound.command, function()
    if not hasStarted then return end

    local job = framework.hasJob()
    if not job then
        framework.Notify(locale("no_access"), config.notifications.duration, config.notifications.position, "error", config.notifications.icons[1])
        return
    end

    local vehicle = GetVehiclePedIsIn(cache.ped, false) --[[@as number?]]
    if not vehicle or vehicle == 0 then
        vehicle = lib.getClosestVehicle(GetEntityCoords(cache.ped), 5.0, true)
        if not vehicle or vehicle == 0 then
            framework.Notify(locale("no_nearby_vehicles"), config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[1])
            return
        end
    end

    local plate = GetVehicleNumberPlateText(vehicle)
    local data = lib.callback.await("bGarage:server:getVehicle", false, plate) --[[@as Vehicle?]]

    if data then
        ---@type boolean, string
        local _, reason = lib.callback.await("bGarage:server:setVehicleStatus", false, "impound", plate, data.props, data.owner)
        framework.Notify(reason, config.notifications.duration, config.notifications.position, "inform", config.notifications.icons[3])
    end

    SetEntityAsMissionEntity(vehicle, false, false)
    lib.callback.await("bGarage:server:deleteVehicle", false, VehToNet(vehicle))
end, false)

exports.ox_target:addGlobalVehicle({
    {
        label = locale("impound_vehicle"),
        name = "impound_vehicle",
        icon = "fa-solid fa-car-burst",
        distance = 2.5,
        groups = config.jobs,
        command = config.impound.command,
    },
})

--#endregion Commands

--#region Threads

CreateThread(function()
    Wait(1000)
    if hasStarted then return end
    hasStarted = lib.callback.await("bGarage:server:hasStarted", false)
end)

if config.impound.static then
    CreateThread(function()
        local settings = { id = config.impound.blip.sprite, colour = config.impound.blip.color, scale = config.impound.blip.scale }
        impoundBlip = utils.createBlip(settings, config.impound.location)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName(locale("impound_blip"))
        EndTextCommandSetBlipName(impoundBlip)
    end)
end

--#endregion Threads

SetDefaultVehicleNumberPlateTextPattern(-1, config.miscellaneous.plateTextPattern:upper())
