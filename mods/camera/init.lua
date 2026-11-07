-- Luanti 5.12+ / VoxeLibre: плавная анимация камеры между третьим лицом и "головой".
-- + отладочная визуализация лучей (/camera_debug)
local core       = minetest
local mcl_player = mcl_player

-- ============================ КОНФИГУРАЦИЯ ============================
local CACHE_TTL_US   = 200000      -- 0.3 сек в микросекундах
local BACK_DISTANCE  = -2
local MIN_PROTOCOL   = 48
local OPACITY        = 0.2
local ALPHA_BYTE     = math.floor(OPACITY * 255)

local CAMERA_SPEED   = 15.0        -- блоков в секунду
local EPSILON        = 0.01        -- порог остановки

local OFFSET_THIRD      = vector.new(-5, 2, 0)
local OFFSET_THIRD_HEAD = vector.new(0, -2, 0)
local EYE_ZERO          = vector.zero()

local states        = {}
local cramped_cache = {}

-- ============================ RAYCAST ============================
local function ray_blocked(pos, dir)
    for pointed in core.raycast(pos, vector.add(pos, dir), false) do
        if pointed.type == "node" then
            return true
        end
    end
    return false
end

-- ============================ ОТЛАДКА ЛУЧЕЙ ============================
-- ============================ ОПРЕДЕЛЕНИЕ ТЕСНОТЫ ============================
local function is_cramped(player)
    local name   = player:get_player_name()
    local cached = cramped_cache[name]
    local now    = core.get_us_time()

    if cached and (now - cached.time) < CACHE_TTL_US then
        return cached.result or cached.result1 or cached.result2 or cached.result3 or cached.result4 or cached.result5
    end

    local pos = player:get_pos()
    pos.y = pos.y + player:get_properties().eye_height

    local backpos = vector.multiply(player:get_look_dir(),-3)
	local camera_pos = vector.add(pos, player:get_eye_offset().thirdperson_back or vector.zero())
	
	
    local result  = ray_blocked(camera_pos,     backpos)
	
    cramped_cache[name] = {result = result, result1 = result1, result2 = result2, result3 = result3, result4 = result4, result5 = result5, time = now }
    return result or result1 or result2 or result3 or result4 or result5
end

-- ============================ ПРОЗРАЧНОСТЬ ============================
local function make_transparent(textures)
    local result = {}
    for i, tex in ipairs(textures) do
        result[i] = tex .. "^[opacity:" .. ALPHA_BYTE
    end
    return result
end

local function set_textures(player, textures)
    if mcl_player and mcl_player.player_set_textures then
        mcl_player.player_set_textures(player, textures)
    else
        -- fallback на случай отсутствия mcl_player
        player:set_properties({ textures = textures })
    end
end

local function get_original_textures(player)
    if mcl_player and mcl_player.player_get_animation then
        local anim = mcl_player.player_get_animation(player)
        if anim and anim.textures then
            return anim.textures
        end
    end
    return player:get_properties().textures
end

local function update_visibility(player, state, cramped)
    if state.cramped == cramped then return end

    if cramped then
        -- Сохраняем актуальные текстуры через mcl_player (или fallback)
        state.original_textures = get_original_textures(player)
        set_textures(player, make_transparent(state.original_textures))
        player:set_properties({ use_texture_alpha = true })
    elseif state.original_textures then
        set_textures(player, state.original_textures)
        player:set_properties({ use_texture_alpha = false })
        state.original_textures = nil
    end

    state.cramped = cramped
end

-- ============================ АНИМАЦИЯ КАМЕРЫ ============================
local function animate_camera(player, state, cramped, dtime)
    local target  = cramped and OFFSET_THIRD_HEAD or OFFSET_THIRD
    local current = state.current_offset
    if current == target then return end  -- уже на месте

    local dx   = target.x - current.x
    local dy   = target.y - current.y
    local dz   = target.z - current.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local step = CAMERA_SPEED * dtime

    local next
    if dist > EPSILON and step < dist then
        local t = step / dist
        next = {
            x = current.x + dx * t,
            y = current.y + dy * t,
            z = current.z + dz * t,
        }
    else
        next = target  -- дошли в этом кадре или уже близко
    end

    state.current_offset = next
    player:set_eye_offset(EYE_ZERO, next, next)
end

-- ============================ РЕГИСТРАЦИЯ ============================
core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local info = core.get_player_information(name)
    if not player.set_camera or not player.set_eye_offset
            or not info or info.protocol_version < MIN_PROTOCOL then
        core.kick_player(name, "Для камеры нужен клиент и сервер Luanti 5.12 или новее.")
        return
    end

    states[name] = {
        cramped           = false,
        original_textures = nil,
        current_offset    = OFFSET_THIRD,
    }

    player:set_camera({ mode = "third" })
    player:set_eye_offset(EYE_ZERO, OFFSET_THIRD, OFFSET_THIRD)
end)

core.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    states[name]        = nil
    cramped_cache[name] = nil
end)

core.register_globalstep(function(dtime)
    for _, player in ipairs(core.get_connected_players()) do
        local state = states[player:get_player_name()]
        if state then
            local cramped = is_cramped(player)
            update_visibility(player, state, cramped)
            animate_camera(player, state, cramped, dtime)
        end
    end
end)