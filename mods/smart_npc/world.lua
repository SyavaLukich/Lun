-- Связь мозга с миром Luanti: восприятие, поиск мест, движение и частицы.
-- Все тяжёлые сканы кешируются, чтобы десятки жителей не грузили сервер.

local W = {}
smart_npc.world = W
local U = smart_npc.util
local M = smart_npc.memory

local floor = math.floor
local sqrt = math.sqrt

function W.now()
	return minetest.get_gametime()
end

function W.is_walkable_name(name)
	local def = minetest.registered_nodes[name]
	return def and def.walkable
end

function W.node_at(pos)
	return minetest.get_node({
		x = floor(pos.x),
		y = floor(pos.y),
		z = floor(pos.z),
	})
end

function W.is_solid(pos)
	local name = W.node_at(pos).name
	return W.is_walkable_name(name)
end

-- Опора определяется по блоку под ногами, а не по скорости: на вершине
-- прыжка скорость почти нулевая, и раньше это принималось за «на земле».
function W.is_grounded(pos)
	if not pos then return false end
	return W.is_solid({ x = pos.x, y = pos.y - 0.1, z = pos.z })
end

function W.is_air(pos)
	local name = W.node_at(pos).name
	return name == "air" or name == "ignore"
end

function W.has_ground_below(pos, depth)
	depth = depth or 12
	for dy = 1, depth do
		local node = W.node_at({ x = pos.x, y = pos.y - dy, z = pos.z })
		if W.is_walkable_name(node.name) then return true end
	end
	return false
end

function W.is_sheltered(pos)
	for dy = 2, 5 do
		local node = W.node_at({ x = pos.x, y = pos.y + dy, z = pos.z })
		if W.is_walkable_name(node.name) then return true end
	end
	return false
end

-- Ищет точку, где можно стоять: воздух, под ногами твёрдый блок.
function W.random_walkable_near(pos, radius, rng)
	rng = rng or function(a, b) return math.random(a, b) end
	for _ = 1, 24 do
		local x = pos.x + rng(-radius, radius)
		local z = pos.z + rng(-radius, radius)
		local y = pos.y + rng(-3, 3)
		local here = { x = x, y = y, z = z }
		local below = { x = x, y = y - 1, z = z }
		local above = { x = x, y = y + 1, z = z }
		if W.is_air(here) and W.is_air(above) and W.is_walkable_name(W.node_at(below).name) then
			return { x = floor(x) + 0.5, y = floor(y), z = floor(z) + 0.5 }
		end
	end
	return nil
end

-- Позиция для появления: чуть выше твёрдой поверхности.
function W.find_spawn_pos(pos)
	local x, z = floor(pos.x) + 0.5, floor(pos.z) + 0.5
	local y0 = floor(pos.y)

	for dy = 2, -5, -1 do
		local y = y0 + dy
		local feet_air = W.is_air({ x = x, y = y, z = z })
		local head_air = W.is_air({ x = x, y = y + 1, z = z })
		local ground = W.is_walkable_name(W.node_at({ x = x, y = y - 1, z = z }).name)
		if feet_air and head_air and ground then
			return { x = x, y = y, z = z }
		end
	end

	-- Пустой мир без опоры: ставим просто над точкой, дальше сработает спасение.
	for dy = 1, 5 do
		local y = y0 + dy
		if W.is_air({ x = x, y = y, z = z }) and W.is_air({ x = x, y = y + 1, z = z }) then
			return { x = x, y = y, z = z }
		end
	end
	return { x = x, y = y0 + 1, z = z }
end

-- ---------------------------------------------------------------------------
-- Восприятие
-- ---------------------------------------------------------------------------
local function relation_fear(brain, key)
	local rel = brain.memory.relationships[key]
	return rel and rel.fear or 0
end

function W.scan(entity, brain, now)
	local pos = entity.object:get_pos()
	if not pos then return { social_targets = {}, environment = {} } end
	brain.perceive_seen = brain.perceive_seen or {}
	brain.cache = brain.cache or {}

	local social = {}
	local danger = false
	local company = false

	for _, player in ipairs(minetest.get_connected_players()) do
		local ppos = player:get_pos()
		if ppos then
			local distance = U.distance(pos, ppos)
			if distance <= 28 then
				local name = player:get_player_name()
				local key = "player:" .. name
				social[#social + 1] = {
					key = key,
					name = name,
					kind = "player",
					pos = ppos,
					distance = distance,
					obj = player,
				}
				if distance <= 7 then company = true end
				if relation_fear(brain, key) >= 55 and distance <= 10 then danger = true end
				local seen_at = brain.perceive_seen[key] or 0
				if now - seen_at > 45 then
					brain.perceive_seen[key] = now
					M.seen(brain, key, name, now)
				end
			end
		end
	end

	-- Другие жители тоже компания и собеседники.
	for id, other in pairs(smart_npc.active or {}) do
		if other ~= entity and other.object and other._brain and id ~= brain.id then
			local opos = other.object:get_pos()
			if opos then
				local distance = U.distance(pos, opos)
				if distance <= 24 then
					local key = "npc:" .. tostring(other._brain.id)
					social[#social + 1] = {
						key = key,
						name = other._brain.name,
						kind = "npc",
						pos = opos,
						distance = distance,
						obj = other.object,
						entity = other,
					}
					if distance <= 6 then company = true end
					if relation_fear(brain, key) >= 55 and distance <= 10 then danger = true end
				end
			end
		end
	end

	table.sort(social, function(a, b) return a.distance < b.distance end)

	local head = { x = pos.x, y = pos.y + 1.5, z = pos.z }
	local light = minetest.get_node_light(head) or 15
	local time_of_day = minetest.get_timeofday() or 0.5
	local day = time_of_day > 0.25 and time_of_day < 0.75

	if brain.last_hurt and now - brain.last_hurt < 45 then
		danger = true
	end

	local environment = {
		light = light,
		day = day,
		night = not day,
		dark = light < 7,
		sheltered = W.is_sheltered(pos),
		warm = light >= 10,
		company = company,
		danger = danger,
		time_of_day = time_of_day,
	}

	-- --- еда (кеш 5 секунд) ---
	if not brain.cache.food_at or now - brain.cache.food_at > 5 then
		brain.cache.food_at = now
		brain.cache.food_pos = nil
		brain.cache.food_name = nil
		if smart_npc.food_nodes and #smart_npc.food_nodes > 0 then
			local found = minetest.find_node_near(pos, 12, smart_npc.food_nodes, true)
			if found then
				brain.cache.food_pos = found
				brain.cache.food_name = minetest.get_node(found).name
			end
		end
	end

	-- --- вода (кеш 8 секунд) ---
	if not brain.cache.water_at or now - brain.cache.water_at > 8 then
		brain.cache.water_at = now
		brain.cache.water_pos = nil
		if smart_npc.water_nodes and #smart_npc.water_nodes > 0 then
			brain.cache.water_pos = minetest.find_node_near(pos, 12, smart_npc.water_nodes, true)
		end
	end

	-- --- интересный блок (кеш 12 секунд) ---
	if not brain.cache.interesting_at or now - brain.cache.interesting_at > 12 then
		brain.cache.interesting_at = now
		brain.cache.interesting_pos = nil
		brain.cache.interesting_name = nil
		if smart_npc.interesting_nodes and #smart_npc.interesting_nodes > 0 then
			brain.cache.interesting_pos = minetest.find_node_near(pos, 10, smart_npc.interesting_nodes, true)
			if brain.cache.interesting_pos then
				brain.cache.interesting_name = minetest.get_node(brain.cache.interesting_pos).name
			end
		end
	end

	local ctx = {
		now = now,
		pos = pos,
		social_targets = social,
		environment = environment,
		food = brain.cache.food_pos,
		food_name = brain.cache.food_name,
		water = brain.cache.water_pos,
		interesting = brain.cache.interesting_pos,
		interesting_name = brain.cache.interesting_name,
	}
	-- В мозг складываем только простые данные: объекты движка сохранять нельзя.
	local stripped = {
		now = ctx.now,
		pos = U.vector_copy(ctx.pos),
		environment = ctx.environment,
		food = ctx.food,
		food_name = ctx.food_name,
		water = ctx.water,
		interesting = ctx.interesting,
		interesting_name = ctx.interesting_name,
		social_targets = {},
	}
	for _, target in ipairs(social) do
		stripped.social_targets[#stripped.social_targets + 1] = {
			key = target.key,
			name = target.name,
			kind = target.kind,
			pos = U.vector_copy(target.pos),
			distance = target.distance,
		}
	end
	brain.last_context = stripped
	ctx.stored = stripped
	return ctx
end

function W.resolve_target(brain, key, ctx)
	ctx = ctx or brain.last_context
	if not ctx or not key then return nil end
	local target = nil
	for _, candidate in ipairs(ctx.social_targets or {}) do
		if candidate.key == key then
			target = candidate
			break
		end
	end
	if target then
		target.pos = target.obj and target.obj:get_pos() or target.pos
		if target.obj then
			target.distance = U.distance(ctx.pos, target.pos)
		end
		return target
	end
	-- Житель мог выйти из зоны восприятия, но всё ещё существовать.
	if key:sub(1, 4) == "npc:" then
		local other = smart_npc.active[key:sub(5)]
		if other and other.object and other._brain then
			local opos = other.object:get_pos()
			if opos then
				return { key = key, name = other._brain.name, kind = "npc", pos = opos,
					obj = other.object, entity = other, distance = U.distance(ctx.pos, opos) }
			end
		end
	end
	-- Игрок мог отойти далеко, но остаться в мире.
	if key:sub(1, 7) == "player:" then
		local name = key:sub(8)
		local player = minetest.get_player_by_name(name)
		if player then
			local ppos = player:get_pos()
			if ppos then
				return { key = key, name = name, kind = "player", pos = ppos, obj = player, distance = U.distance(ctx.pos, ppos) }
			end
		end
	end
	return nil
end

function W.nearest_social(ctx, kind, max_distance)
	local best
	for _, target in ipairs(ctx.social_targets or {}) do
		if (not kind or target.kind == kind) and target.distance <= (max_distance or 28) then
			if not best or target.distance < best.distance then best = target end
		end
	end
	return best
end

-- ---------------------------------------------------------------------------
-- Пища
-- ---------------------------------------------------------------------------
function W.find_food_pos(brain, ctx, max_distance)
	max_distance = max_distance or 14
	local cached = brain.cache and brain.cache.food_pos
	if cached and smart_npc.is_food_node(minetest.get_node(cached).name) then
		local distance = U.distance(ctx.pos or cached, cached)
		if distance <= max_distance then return cached, minetest.get_node(cached).name end
	end
	if smart_npc.food_nodes and #smart_npc.food_nodes > 0 then
		local found = minetest.find_node_near(ctx.pos, max_distance, smart_npc.food_nodes, true)
		if found then
			local name = minetest.get_node(found).name
			brain.cache = brain.cache or {}
			brain.cache.food_pos = found
			brain.cache.food_name = name
			return found, name
		end
	end
	return nil
end

function W.find_food_item(pos, radius)
	for _, obj in ipairs(minetest.get_objects_inside_radius(pos, radius or 6)) do
		local lua = obj:get_luaentity()
		if lua and lua.itemstring and smart_npc.is_food_item(lua.itemstring) then
			return obj, lua.itemstring
		end
	end
	return nil
end

function W.item_label(itemstring)
	local name = itemstring:match("^([^%s]+)") or itemstring
	local def = minetest.registered_items[name]
	return def and def.description or name
end

-- ---------------------------------------------------------------------------
-- Анимации модели (кадры модели npc.b3d)
-- ---------------------------------------------------------------------------
local ANIMATIONS = {
	stand = { x = 0, y = 79 },
	walk = { x = 168, y = 187 },
	run = { x = 440, y = 459 },
	sit = { x = 81, y = 160 },
	lay = { x = 162, y = 166 },
	mine = { x = 189, y = 198 },
}

W.animations = ANIMATIONS

function W.animate(entity, name, speed)
	if not entity._brain or not entity.object then return end
	if entity._anim == name then return end
	entity._anim = name
	local frames = ANIMATIONS[name] or ANIMATIONS.stand
	entity.object:set_animation(frames, speed or 30, 0)
end

-- ---------------------------------------------------------------------------
-- Движение
-- ---------------------------------------------------------------------------
-- Luanti 5.17 переименовал getvelocity/setvelocity; на старых версиях
-- оставляем запасной вариант.
function W.get_velocity(obj)
	if not obj then return { x = 0, y = 0, z = 0 } end
	if obj.get_velocity then return obj:get_velocity() end
	return obj:getvelocity()
end

function W.set_velocity(obj, velocity)
	if not obj then return end
	if obj.set_velocity then
		obj:set_velocity(velocity)
	else
		obj:setvelocity(velocity)
	end
end

function W.brake(entity)
	local obj = entity.object
	local velocity = W.get_velocity(obj)
	W.set_velocity(obj, { x = 0, y = velocity.y, z = 0 })
end

function W.stop(entity)
	W.brake(entity)
	entity._path = nil
	entity._stuck_time = 0
end

function W.face(entity, pos)
	if not entity or not entity.object or type(pos) ~= "table" or pos.x == nil then return end
	local self_pos = entity.object:get_pos()
	if not self_pos then return end
	local dx, dz = pos.x - self_pos.x, pos.z - self_pos.z
	if math.abs(dx) + math.abs(dz) < 0.001 then return end
	local yaw = minetest.dir_to_yaw and minetest.dir_to_yaw({ x = dx, y = 0, z = dz })
		or (math.atan2 and math.atan2(dx, dz)) or math.atan(dx, dz)
	entity.object:set_yaw(yaw)
end

local function path_to(entity, target, now)
	local obj = entity.object
	local pos = obj:get_pos()
	local cache = entity._path
	if cache and cache.goal and U.distance(cache.goal, target) < 1.5 and (cache.expires or 0) > now then
		return cache
	end
	local path = minetest.find_path(
		{ x = pos.x, y = pos.y, z = pos.z },
		{ x = target.x, y = target.y, z = target.z },
		12, 1, 2
	)
	cache = {
		goal = U.vector_copy(target),
		path = path,
		index = 2,
		expires = now + 4,
	}
	entity._path = cache
	return cache
end

-- Двигает существо к точке. Возвращает "moving", "arrived" или "blocked".
function W.move_to(entity, target, dt, speed, radius)
	local obj = entity.object
	local pos = obj:get_pos()
	if not pos or not target then return "blocked" end
	radius = radius or 1.1

	local dx, dz = target.x - pos.x, target.z - pos.z
	local distance = sqrt(dx * dx + dz * dz)
	local dy = target.y - pos.y

	if distance <= radius and math.abs(dy) < 2.2 then
		W.brake(entity)
		entity._stuck_time = 0
		return "arrived"
	end

	local now = W.now()
	local cache
	if distance > 2.5 then
		cache = path_to(entity, target, now)
	end

	local waypoint = target
	if cache and cache.path and #cache.path >= 2 then
		local index = math.max(2, math.min(cache.index or 2, #cache.path))
		local point = cache.path[index]
		if point and U.horizontal_distance(pos, point) < 0.8 and math.abs(pos.y - point.y) < 1.6 then
			index = math.min(index + 1, #cache.path)
			cache.index = index
			point = cache.path[index]
		end
		if point then waypoint = point end
	end

	dx, dz = waypoint.x - pos.x, waypoint.z - pos.z
	local length = sqrt(dx * dx + dz * dz)
	if length < 0.001 then
		W.brake(entity)
		return "moving"
	end
	local dirx, dirz = dx / length, dz / length

	-- Прыжок через ступеньку или наверх. Опора проверяется по блоку:
	-- иначе на вершине прыжка скорость близка к нулю и житель прыгает снова.
	local velocity = W.get_velocity(obj)
	local ahead = { x = pos.x + dirx * 0.55, y = pos.y + 0.2, z = pos.z + dirz * 0.55 }
	local ahead_up = { x = pos.x + dirx * 0.55, y = pos.y + 1.2, z = pos.z + dirz * 0.55 }
	local needs_jump = W.is_solid(ahead) or (W.is_solid(ahead_up) and not W.is_solid({ x = pos.x, y = pos.y + 2.2, z = pos.z }))
		or dy > 0.8
	local grounded = W.is_grounded(pos)
	local on_ground = grounded and math.abs(velocity.y) < 2.0

	if needs_jump and on_ground then
		W.set_velocity(obj, { x = dirx * speed, y = 4.9, z = dirz * speed })
	elseif grounded and velocity.y <= 0.6 then
		-- Не накапливаем скорость падения, пока стоим на опоре.
		W.set_velocity(obj, { x = dirx * speed, y = 0, z = dirz * speed })
	else
		W.set_velocity(obj, { x = dirx * speed, y = velocity.y, z = dirz * speed })
	end

	W.face(entity, waypoint)

	-- Застревание: пытаемся прыгнуть, затем сдаёмся.
	if entity._last_move_pos then
		local moved = U.distance(pos, entity._last_move_pos)
		if moved < 0.012 and distance > 1.2 then
			entity._stuck_time = (entity._stuck_time or 0) + dt
		else
			entity._stuck_time = 0
		end
	end
	entity._last_move_pos = U.vector_copy(pos)

	if (entity._stuck_time or 0) > 1.2 and on_ground then
		W.set_velocity(obj, { x = dirx * speed, y = 5.1, z = dirz * speed })
	end
	if (entity._stuck_time or 0) > 4.5 then
		W.brake(entity)
		entity._path = nil
		return "blocked"
	end

	return "moving"
end

-- ---------------------------------------------------------------------------
-- Эффекты и речь
-- ---------------------------------------------------------------------------
function W.particles(pos, texture, amount, spread, height)
	if not pos then return end
	spread = spread or 0.5
	height = height or 1.2
	minetest.add_particlespawner({
		amount = amount or 6,
		time = 0.2,
		minpos = { x = pos.x - spread, y = pos.y + 0.3, z = pos.z - spread },
		maxpos = { x = pos.x + spread, y = pos.y + height, z = pos.z + spread },
		minvel = { x = -0.4, y = 0.4, z = -0.4 },
		maxvel = { x = 0.4, y = 1.2, z = 0.4 },
		minacc = { x = 0, y = -0.5, z = 0 },
		maxacc = { x = 0, y = 0, z = 0 },
		minexptime = 0.6,
		maxexptime = 1.4,
		minsize = 2,
		maxsize = 5,
		texture = texture,
		-- В Luanti 5.17 glow — число, а не boolean.
		glow = (texture == "npc_heart.png" or texture == "npc_zzz.png") and 1 or 0,
	})
end

function W.sound(pos, name, gain)
	if not pos then return end
	if minetest.sound_play then
		minetest.sound_play(name, { pos = pos, gain = gain or 0.5, max_hear_distance = 12 }, true)
	end
end

-- Реплика слышна игрокам поблизости; частота ограничена.
function W.say(entity, text, force)
	if not text or text == "" then return false end
	local brain = entity._brain
	local now = W.now()
	if not force then
		if not smart_npc.settings.chat_lines then return false end
		if entity._last_say and now - entity._last_say < 2.5 then return false end
	end
	entity._last_say = now

	local pos = entity.object:get_pos()
	if not pos then return false end
	local name = brain and brain.name or "Житель"
	local message = minetest.colorize("#9fd3ff", "[" .. name .. "] ") .. text
	for _, player in ipairs(minetest.get_connected_players()) do
		local ppos = player:get_pos()
		if ppos and U.distance(pos, ppos) <= 18 then
			minetest.chat_send_player(player:get_player_name(), message)
		end
	end
	return true
end

function W.is_protected(pos, brain)
	if minetest.is_protected then
		return minetest.is_protected(pos, brain and brain.name or "")
	end
	return false
end

function W.teleport_near(entity, pos)
	if not pos then return end
	local safe = W.random_walkable_near(pos, 4) or { x = pos.x, y = pos.y + 1, z = pos.z }
	entity.object:set_pos(safe)
	W.set_velocity(entity.object, { x = 0, y = 0, z = 0 })
end

-- Куда идти в случае опасности: дом, иначе освещённое место рядом.
function W.safe_spot(brain, entity)
	if brain.knowledge and brain.knowledge.home then
		return U.vector_copy(brain.knowledge.home)
	end
	local pos = entity.object:get_pos()
	local spot = W.random_walkable_near(pos, 6)
	return spot or pos
end
