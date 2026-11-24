-- Luanti 5.12+: камера за правым плечом с защитой от препятствий.
local core = minetest

local MIN_PROTOCOL = 48
local CAMERA_RAY_LENGTH = 2.75
local CAMERA_LIFT = 0.2
local OFFSET_SCALE = 0.1
local OFFSET_THIRD = vector.new(-5, 2, 0)
local OFFSET_NEAR = vector.new(0, -5, 10)
local CAMERA_SPEED_IN = 50
local CAMERA_SPEED_OUT = 15
local mcl_player = mcl_player
local EYE_ZERO = vector.zero()

-- Проверяем не только центральный луч, но и небольшой объём вокруг камеры.
-- Возвращаемся к третьему лицу лишь после устойчивого свободного обзора.
local CAMERA_RADIUS = 0.15
local SAMPLE_STEP = 0.2
local CLEAR_TIME = 0.35
local probes = {
    {x = 0, y = 0, z = 0},
    {x = CAMERA_RADIUS, y = 0, z = 0},
    {x = -CAMERA_RADIUS, y = 0, z = 0},
    {x = 0, y = CAMERA_RADIUS, z = 0},
    {x = 0, y = -CAMERA_RADIUS, z = 0},
    {x = 0, y = 0, z = CAMERA_RADIUS},
    {x = 0, y = 0, z = -CAMERA_RADIUS},
}

local states = {}

local function node_is_solid(pos)
    -- get_node_or_nil также обнаруживает ещё не загруженные участки.
    local node = core.get_node_or_nil(pos)
    if not node or node.name == "ignore" then
        return true
    end
    local def = core.registered_nodes[node.name]
    return not def or def.walkable == true
end

local function ray_blocked(from, to)
    -- Выборка дополняет raycast: непоинтабельные узлы и начало луча
    -- внутри блока не всегда возвращаются raycast. Считаем walkable-узел
    -- целым блоком: это консервативно, зато камера не проходит сквозь него.
    local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    local steps = math.max(1, math.ceil(length / SAMPLE_STEP))
    for i = 0, steps do
        local t = i / steps
        if node_is_solid({x = from.x + dx * t, y = from.y + dy * t, z = from.z + dz * t}) then
            return true
        end
    end

    for pointed in core.raycast(from, to, false, false) do
        if pointed.type == "node" then
            local pos = pointed.under or pointed.pos
            if not pos or node_is_solid(pos) then
                return true
            end
        end
    end
    return false
end

local function volume_blocked(from, to)
    for _, offset in ipairs(probes) do
        local start = {x = from.x + offset.x, y = from.y + offset.y, z = from.z + offset.z}
        local finish = {x = to.x + offset.x, y = to.y + offset.y, z = to.z + offset.z}
        if ray_blocked(start, finish) then
            return true
        end
    end
    return false
end

local function camera_path(player)
    local pos = player:get_pos()
    local look = player:get_look_dir()
    if not pos or not look then
        return nil
    end
    local props = player:get_properties()
    local eye = {x = pos.x, y = pos.y + ((props and props.eye_height) or 1.625), z = pos.z}

    local len = math.sqrt(look.x * look.x + look.z * look.z)
    local yaw
    if len > 1e-6 then
        yaw = core.dir_to_yaw({x = look.x / len, y = 0, z = look.z / len})
    else
        yaw = (player.get_look_horizontal and player:get_look_horizontal()) or 0
    end
    local forward = core.yaw_to_dir(yaw)
    local left = core.yaw_to_dir(yaw - math.pi / 2)
    local head = {
        x = eye.x + (left.x * OFFSET_THIRD.x + forward.x * OFFSET_THIRD.z) * OFFSET_SCALE,
        y = eye.y + OFFSET_THIRD.y * OFFSET_SCALE + CAMERA_LIFT,
        z = eye.z + (left.z * OFFSET_THIRD.x + forward.z * OFFSET_THIRD.z) * OFFSET_SCALE,
    }
    local camera = {
        x = head.x - look.x * CAMERA_RAY_LENGTH,
        y = head.y - look.y * CAMERA_RAY_LENGTH,
        z = head.z - look.z * CAMERA_RAY_LENGTH,
    }
    return eye, head, camera
end

local function is_cramped(player)
    local eye, head, camera = camera_path(player)
    if not eye then
        return true
    end
    -- Проверяем и путь от глаз к плечу: иначе плечевое смещение способно
    -- перенести начало луча за стену или внутрь неё.
    return volume_blocked(eye, head) or volume_blocked(head, camera)
end

local function set_textures(player, textures)
    if mcl_player and mcl_player.player_set_textures then
        mcl_player.player_set_textures(player, textures)
    else
        player:set_properties({textures = textures})
    end
end

local function set_cramped(player, state, cramped)
    if state.cramped == cramped then return end
    state.cramped = cramped
    if cramped then
        local props = player:get_properties()
        state.original_textures = props.textures
        state.original_alpha = props.use_texture_alpha
        if state.original_textures then
            local transparent = {}
            for i, texture in ipairs(state.original_textures) do
                transparent[i] = texture .. "^[opacity:51"
            end
            set_textures(player, transparent)
            player:set_properties({use_texture_alpha = true})
        end
    elseif state.original_textures then
        set_textures(player, state.original_textures)
        player:set_properties({use_texture_alpha = state.original_alpha or false})
        state.original_textures = nil
    end
end

local function animate_camera(player, state, dtime)
    local target = state.cramped and OFFSET_NEAR or OFFSET_THIRD
    local current = state.offset
    local dx, dy, dz = target.x - current.x, target.y - current.y, target.z - current.z
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    if distance < 0.001 then return end
    local speed = state.cramped and CAMERA_SPEED_IN or CAMERA_SPEED_OUT
    local t = math.min(1, speed * dtime / distance)
    state.offset = {x = current.x + dx * t, y = current.y + dy * t, z = current.z + dz * t}
    player:set_eye_offset(EYE_ZERO, state.offset, state.offset)
end

core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local info = core.get_player_information(name)
    if not player.set_camera or not player.set_eye_offset
            or not info or not info.protocol_version or info.protocol_version < MIN_PROTOCOL then
        core.kick_player(name, "Для камеры нужен клиент и сервер Luanti 5.12 или новее.")
        return
    end

    -- До проверки начинаем с ближайшего положения, не меняя режим камеры.
    states[name] = {cramped = false, clear_time = 0, offset = OFFSET_NEAR}
    set_cramped(player, states[name], true)
    player:set_eye_offset(EYE_ZERO, OFFSET_NEAR, OFFSET_NEAR)
    player:set_camera({mode = "third"})
end)

core.register_on_leaveplayer(function(player)
    states[player:get_player_name()] = nil
end)

core.register_globalstep(function(dtime)
    for _, player in ipairs(core.get_connected_players()) do
        local state = states[player:get_player_name()]
        if state then
            if is_cramped(player) then
                state.clear_time = 0
                set_cramped(player, state, true)
            elseif state.cramped then
                state.clear_time = state.clear_time + dtime
                if state.clear_time >= CLEAR_TIME then
                    set_cramped(player, state, false)
                end
            end
            animate_camera(player, state, dtime)
        end
    end
end)
