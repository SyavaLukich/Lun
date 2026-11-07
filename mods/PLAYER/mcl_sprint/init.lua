--[[
Sprint mod for Luanti, adapted for standalone use.

Based on the original mcl_sprint by GunshipPenguin.
No hard dependencies on mcl_hunger, mcl_fovapi, or playerphysics.
]]

local math = math
local vector = vector
local pairs = pairs

local get_node = minetest.get_node
local get_gametime = minetest.get_gametime
local add_particlespawner = minetest.add_particlespawner
local get_player_by_name = minetest.get_player_by_name

local registered_nodes = minetest.registered_nodes

-- Опциональная совместимость с mcl_hunger.
-- Если мод mcl_hunger отсутствует, переменные остаются nil.
local get_hunger = mcl_hunger and mcl_hunger.get_hunger
local exhaust = mcl_hunger and mcl_hunger.exhaust

-- Configuration variables
mcl_sprint = {}
mcl_sprint.SPEED = 1.3

-- Хранилище состояния игроков
local players = {}

-- Возвращает true, если игрок спринтует, false если нет,
-- nil если игрок не найден.
function mcl_sprint.is_sprinting(playername)
    if players[playername] then
        return players[playername].sprinting
    else
        return nil
    end
end

minetest.register_on_joinplayer(function(player)
    local playerName = player:get_player_name()

    players[playerName] = {
        sprinting = false,
        timeOut = 0,
        shouldSprint = false,
        clientSprint = false,
        lastPos = player:get_pos(),
        sprintDistance = 0,
        fov = 1.0,
        -- Сохраняем базовую скорость, чтобы восстановить её после спринта.
        baseSpeed = 1.0,
        channel = minetest.mod_channel_join("mcl_sprint:" .. playerName),
    }
end)

minetest.register_on_leaveplayer(function(player)
    local playerName = player:get_player_name()
    players[playerName] = nil
end)

local function cancelClientSprinting(name)
    players[name].channel:send_all("")
    players[name].clientSprint = false
end

-- Вспомогательная функция для установки FOV без mcl_fovapi.
local function setSprintFOV(player, sprinting)
    if sprinting then
        player:set_fov(1.1, true, 0.15)
    else
        player:set_fov(0, true, 0.15)
    end
end

local function setSprinting(playerName, sprinting)
    -- Если состояние не меняется — выходим.
    if not sprinting and not mcl_sprint.is_sprinting(playerName) then
        return
    end

    local player = minetest.get_player_by_name(playerName)
    if not player or not players[playerName] then
        return false
    end

    players[playerName].sprinting = sprinting

    if sprinting then
        -- Сохраняем текущую скорость как базовую (если ещё не сохраняли).
        if not players[playerName].baseSpeed then
            players[playerName].baseSpeed = 1.0
        end
        player:set_physics_override({
            speed = players[playerName].baseSpeed * mcl_sprint.SPEED,
        })
        setSprintFOV(player, true)
    else
        player:set_physics_override({
            speed = players[playerName].baseSpeed or 1.0,
        })
        setSprintFOV(player, false)
    end

    return true
end

-- Возвращает тайл верхней грани узла (для партиклов).
local function get_top_node_tile(param2, paramtype2)
    if paramtype2 == "colorwallmounted" then
        paramtype2 = "wallmounted"
        param2 = param2 % 8
    elseif paramtype2 == "colorfacedir" then
        paramtype2 = "facedir"
        param2 = param2 % 32
    end

    if paramtype2 == "wallmounted" then
        if param2 == 0 then
            return 2
        elseif param2 == 1 then
            return 1
        else
            return 5
        end
    elseif paramtype2 == "facedir" then
        if param2 >= 0 and param2 <= 3 then
            return 1
        elseif param2 == 4 or param2 == 10 or param2 == 13 or param2 == 19 then
            return 6
        elseif param2 == 5 or param2 == 11 or param2 == 14 or param2 == 16 then
            return 3
        elseif param2 == 6 or param2 == 8 or param2 == 15 or param2 == 17 then
            return 5
        elseif param2 == 7 or param2 == 9 or param2 == 12 or param2 == 18 then
            return 4
        elseif param2 >= 20 and param2 <= 23 then
            return 2
        else
            return 1
        end
    else
        return 1
    end
end

minetest.register_on_modchannel_message(function(channel_name, sender, message)
    if channel_name == "mcl_sprint:" .. sender then
        if players[sender] then
            players[sender].clientSprint = minetest.is_yes(message)
        end
    end
end)

minetest.register_on_respawnplayer(function(player)
    cancelClientSprinting(player:get_player_name())
end)

minetest.register_globalstep(function(dtime)
    local gameTime = get_gametime()

    for playerName, playerInfo in pairs(players) do
        local player = get_player_by_name(playerName)
        if player then
            local ctrl = player:get_player_control()

            -- Определяем, должен ли игрок спринтовать.
            if players[playerName].clientSprint
                or (ctrl.aux1 and ctrl.up and not ctrl.sneak) then
                players[playerName].shouldSprint = true
            else
                players[playerName].shouldSprint = false
            end

            local playerPos = player:get_pos()

            -- Партиклы и истощение — только если игрок действительно спринтует.
            if playerInfo.sprinting == true
                and not player:get_attach()
                and gameTime % 0.1 == 0 then

                -- Истощение (только если mcl_hunger доступен).
                if exhaust then
                    local lastPos = players[playerName].lastPos
                    local dist = vector.distance(
                        { x = lastPos.x, y = 0, z = lastPos.z },
                        { x = playerPos.x, y = 0, z = playerPos.z }
                    )
                    players[playerName].sprintDistance =
                        players[playerName].sprintDistance + dist

                    if players[playerName].sprintDistance >= 1 then
                        local superficial = math.floor(
                            players[playerName].sprintDistance
                        )
                        exhaust(playerName, mcl_hunger.EXHAUST_SPRINT * superficial)
                        players[playerName].sprintDistance =
                            players[playerName].sprintDistance - superficial
                    end
                end

                -- Партиклы под ногами.
                local playerNode = get_node({
                    x = playerPos.x,
                    y = playerPos.y - 1,
                    z = playerPos.z,
                })
                local def = registered_nodes[playerNode.name]

                if def and def.walkable then
                    add_particlespawner({
                        amount = math.random(1, 2),
                        time = 1,
                        minpos = { x = -0.5, y = 0.1, z = -0.5 },
                        maxpos = { x = 0.5, y = 0.1, z = 0.5 },
                        minvel = { x = 0, y = 5, z = 0 },
                        maxvel = { x = 0, y = 5, z = 0 },
                        minacc = { x = 0, y = -13, z = 0 },
                        maxacc = { x = 0, y = -13, z = 0 },
                        minexptime = 0.1,
                        maxexptime = 1,
                        minsize = 0.5,
                        maxsize = 1.5,
                        collisiondetection = true,
                        attached = player,
                        vertical = false,
                        node = playerNode,
                        node_tile = get_top_node_tile(
                            playerNode.param2,
                            def.paramtype2
                        ),
                    })
                end
            end

            -- Обновляем lastPos.
            players[playerName].lastPos = playerPos

            -- Управление состоянием спринта.
            if players[playerName].shouldSprint == true then
                local sprinting = true

                -- Блокировка спринта при голоде (только если mcl_hunger есть).
                if get_hunger and mcl_hunger.get_active and mcl_hunger.get_active() then
                    if get_hunger(player) <= 6 then
                        sprinting = false
                        cancelClientSprinting(playerName)
                    end
                end

                -- Блокировка спринта во сне (метаданные mcl_beds, не зависимость).
                if player:get_meta():get_string("mcl_beds:sleeping") == "true" then
                    sprinting = false
                    cancelClientSprinting(playerName)
                end

                setSprinting(playerName, sprinting)
            elseif players[playerName].shouldSprint == false then
                setSprinting(playerName, false)
            end
        end
    end
end)