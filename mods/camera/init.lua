-- Luanti 5.12+ / VoxeLibre: плавная анимация камеры между третьим лицом и "головой".
local core       = minetest
local mcl_player = mcl_player

-- ============================ КОНФИГУРАЦИЯ ============================
local CACHE_TTL_US      = 200000   -- 0.2 сек в микросекундах
local CAMERA_RAY_LENGTH = 2.75     -- максимальный отвод камеры в третьем лице
local CAMERA_LIFT       = 0.2      -- движок приподнимает камеру в третьем лице
local MIN_PROTOCOL      = 48
local OPACITY           = 0.2
local ALPHA_BYTE        = math.floor(OPACITY * 255)

local CAMERA_SPEED   = 15.0        -- блоков в секунду
local EPSILON        = 0.01        -- порог остановки

-- set_eye_offset()/get_eye_offset() используют десятые доли блока:
-- {x = -5, y = 2} — это 0,5 блока в сторону локальной +X и 0,2 блока
-- вверх. При взгляде вперёд локальная +X находится слева, поэтому
-- -5 даёт смещение вправо.
local OFFSET_THIRD      = vector.new(-5, 2, 0)
-- z = +5 (0,5 блока вперёд) компенсирует отвод камеры движком в
-- третьем лице и не даёт ей так глубоко уходить в заднюю стену.
local OFFSET_THIRD_HEAD = vector.new(0, -2, 5)
local EYE_ZERO          = vector.zero()
local OFFSET_SCALE      = 0.1       -- десятые доли блока -> блоки

local states        = {}
local cramped_cache = {}

-- ============================ RAYCAST ============================
local function node_is_solid(pos)
    local node = core.get_node(pos)
    if node.name == "ignore" then
        return true -- незагруженные участки считаем препятствием
    end
    local def = core.registered_nodes[node.name]
    return not def or def.walkable
end

local function ray_blocked(from, to)
    -- Луч может начинаться внутри блока: raycast такой узел не всегда отдаёт.
    if node_is_solid(from) then
        return true
    end

    -- Только блоки: объекты и жидкости камеру не перекрывают.
    for pointed in core.raycast(from, to, false, false) do
        if pointed.type == "node" then
            local node_pos = pointed.under or pointed.pos
            if not node_pos or node_is_solid(node_pos) then
                return true
            end
        end
    end
    return false
end

local function get_probe_eye_offset()
    -- Проверяем всегда свободный вариант (плечо), а не текущее анимированное
    -- смещение. Иначе луч сам двигает камеру: в тесноте смещение уходит к
    -- OFFSET_THIRD_HEAD, луч начинает проходить, камера возвращается к
    -- OFFSET_THIRD — и так бесконечно. Плечо — та точка, где камера будет,
    -- если считать помещение просторным, поэтому проверять нужно именно её.
    return OFFSET_THIRD
end

local function horizontal_basis(player)
    local look = player:get_look_dir()
    if not look then
        return nil
    end

    local fx, fz = look.x, look.z
    local len = math.sqrt(fx * fx + fz * fz)
    local yaw
    if len > 1e-6 then
        fx, fz = fx / len, fz / len
        yaw = core.dir_to_yaw({x = fx, y = 0, z = fz})
    else
        -- Смотрим строго вверх/вниз: берём горизонтальный угол игрока.
        yaw = (player.get_look_horizontal and player:get_look_horizontal()) or 0
        local dir = core.yaw_to_dir(yaw)
        fx, fz = dir.x, dir.z
    end

    -- Локальная +X головы (левая сторона при взгляде вперёд). В Luanti
    -- yaw_to_dir(yaw) = (-sin(yaw), 0, cos(yaw)), поэтому это yaw - 90°.
    local left = core.yaw_to_dir(yaw - math.pi / 2)
    return {x = fx, y = 0, z = fz}, {x = left.x, y = 0, z = left.z}
end

local function camera_ray_points(player)
    local pos = player:get_pos()
    if not pos then
        return nil
    end

    local props = player:get_properties()
    local eye_height = (props and props.eye_height) or 1.625
    local eye = {x = pos.x, y = pos.y + eye_height, z = pos.z}

    local forward, left = horizontal_basis(player)
    if not forward then
        return nil
    end

    local offset = get_probe_eye_offset()
    local ox = offset.x or 0
    local oy = offset.y or 0
    local oz = offset.z or 0
    -- Движок прибавляет смещение к голове до наклона (pitch), поэтому
    -- поворачиваем его только по yaw: x — локальная +X, z — вперёд.
    local head = {
        x = eye.x + (left.x * ox + forward.x * oz) * OFFSET_SCALE,
        y = eye.y + oy * OFFSET_SCALE,
        z = eye.z + (left.z * ox + forward.z * oz) * OFFSET_SCALE,
    }

    local look = player:get_look_dir()
    if not look then
        return nil
    end

    -- Начало — точка головы с плечевым смещением и подъёмом, откуда движок
    -- строит третье лицо. Конец — путь камеры назад вдоль взгляда.
    local from = {x = head.x, y = head.y + CAMERA_LIFT, z = head.z}
    local to = {
        x = from.x - look.x * CAMERA_RAY_LENGTH,
        y = from.y - look.y * CAMERA_RAY_LENGTH,
        z = from.z - look.z * CAMERA_RAY_LENGTH,
    }
    return from, to
end

-- ============================ ОПРЕДЕЛЕНИЕ ТЕСНОТЫ ============================
local function is_cramped(player)
    local name   = player:get_player_name()
    local cached = cramped_cache[name]
    local now    = core.get_us_time()

    if cached and (now - cached.time) < CACHE_TTL_US then
        return cached.result
    end

    local from, to = camera_ray_points(player)
    local result = from ~= nil and ray_blocked(from, to)

    cramped_cache[name] = {result = result, time = now}
    return result
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