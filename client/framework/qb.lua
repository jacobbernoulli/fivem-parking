if GetResourceState("qb-core") ~= "started" then return end

local _, QBCore = pcall(exports["qb-core"].getSharedObject) --[[@as table | false]]

if not QBCore then return end

SetVehicleProperties = QBCore.Functions.SetVehicleProperties
GetVehicleProperties = QBCore.Functions.GetVehicleProperties

---@return boolean
function HasJob()
    local job = QBCore.Functions.GetPlayerData()?.job
    if not job then return false end

    for i = 1, #Jobs do
        if job.name == Jobs[i] then
            return true
        end
    end

    return false
end

---@param message string
---@param type "inform" | "error" | "success" | "warning"
---@param icon string
---@param iconColor string
function Notify(message, type, icon, iconColor)
    return lib.notify({
        title = locale("notification_title"),
        description = message,
        duration = Notification.duration,
        position = Notification.position,
        type = type,
        icon = icon,
        iconColor = iconColor,
    })
end
