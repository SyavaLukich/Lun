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
-- Труд: деревья, площадка и план постройки
-- ---------------------------------------------------------------------------
-- Точка рядом с твёрдым блоком, где житель может стоять (ствол дерева,
-- центр будущего навеса и т.п.). Ищем по кольцам, чтобы не застрять в стволе.
function W.approach_pos(target, radius)
	if type(target) ~= "table" or target.x == nil or target.y == nil or target.z == nil then
		return nil
	end
	local bx, by, bz = floor(target.x), floor(target.y), floor(target.z)
	radius = math.max(1, math.floor(radius or 3))
	for r = 1, radius do
		for dx = -r, r do
			for dz = -r, r do
				if math.max(math.abs(dx), math.abs(dz)) == r then
					for dy = -1, 1 do
						local x, y, z = bx + dx, by + dy, bz + dz
						local feet = { x = x, y = y, z = z }
						local head = { x = x, y = y + 1, z = z }
						local below = { x = x, y = y - 1, z = z }
						if W.is_air(feet) and W.is_air(head)
							and W.is_walkable_name(W.node_at(below).name) then
							return { x = x + 0.5, y = y, z = z + 0.5 }
						end
					end
				end
			end
		end
	end
	return nil
end

function W.find_resource_pos(center, names, radius, brain)
	if not center or not names or #names == 0 then return nil end
	local found = minetest.find_node_near(center, radius or 20, names, true)
	if found and not W.is_protected(found, brain) then return found end
	return nil
end

function W.is_creative()
	if minetest.is_creative_enabled then
		local ok, value = pcall(minetest.is_creative_enabled, "")
		if ok and value then return true end
	end
	local settings = minetest.settings
	if settings and settings.get_bool then
		local ok, value = pcall(settings.get_bool, settings, "creative_mode")
		if ok and value then return true end
	end
	return false
end

function W.build_materials()
	return {
		wall = smart_npc.build_wall_node or "default:wood",
		roof = smart_npc.build_roof_node or "default:stone",
		fence = smart_npc.build_fence_node or smart_npc.build_wall_node or "default:wood",
	}
end

function W.resource_for_node(name)
	if type(name) ~= "string" then return "wood" end
	if name:find("stone", 1, true) or name:find("cobble", 1, true)
		or name:find("brick", 1, true) then
		return "stone"
	end
	return "wood"
end

-- ---------------------------------------------------------------------------
-- Постройки: несколько простых планов, чтобы жители не строили одно и то же.
-- ---------------------------------------------------------------------------
local BUILD_DEFS = {
	shelter = {
		goal = "Построить навес",
		done = "Построил(а) навес у дома",
		say = "Навес готов. Можно переждать непогоду.",
	},
	pavilion = {
		goal = "Построить беседку",
		done = "Построил(а) беседку",
		say = "Беседка готова. Здесь можно передохнуть.",
	},
	bench = {
		goal = "Построить скамью",
		done = "Построил(а) скамью",
		say = "Скамья готова. Есть где посидеть.",
	},
	fence = {
		goal = "Построить ограду",
		done = "Построил(а) ограду",
		say = "Ограда готова. Стало уютнее.",
	},
	woodpile = {
		goal = "Сложить поленницу",
		done = "Сложил(а) поленницу",
		say = "Поленница сложена. Дрова будут под рукой.",
	},
}
W.build_defs = BUILD_DEFS
W.build_kind_order = { "shelter", "pavilion", "bench", "fence", "woodpile" }

function W.build_kind_valid(kind)
	return type(kind) == "string" and BUILD_DEFS[kind] ~= nil
end

function W.build_kind_goal(kind)
	local def = BUILD_DEFS[kind] or BUILD_DEFS.shelter
	return def.goal
end

function W.build_kind_done(kind)
	local def = BUILD_DEFS[kind] or BUILD_DEFS.shelter
	return def.done, def.say
end

local function add_plan_entry(plan, x, y, z, role, node)
	plan[#plan + 1] = {
		pos = { x = x, y = y, z = z },
		role = role,
		node = node,
	}
end

-- План строится вокруг центра. Сам центр всегда остаётся свободным: там
-- стоит житель, который ставит блоки, и через него же можно выйти.
function W.build_plan(kind, center, materials)
	if type(center) ~= "table" or center.x == nil or center.y == nil or center.z == nil then
		return {}
	end
	local defaults = W.build_materials()
	materials = materials or defaults
	materials = {
		wall = materials.wall or defaults.wall,
		roof = materials.roof or defaults.roof,
		fence = materials.fence or defaults.fence or materials.wall or defaults.wall,
	}
	if not W.build_kind_valid(kind) then kind = "shelter" end
	local cx, cy, cz = floor(center.x), floor(center.y), floor(center.z)
	local plan = {}

	if kind == "bench" then
		-- Скамья у южной стороны площадки: сиденье и спинка.
		for dx = -1, 1 do
			add_plan_entry(plan, cx + dx, cy, cz + 1, "seat", materials.wall)
			add_plan_entry(plan, cx + dx, cy + 1, cz + 1, "back", materials.wall)
		end
		return plan
	end

	if kind == "fence" then
		-- Низкая ограда: столбики по углам, центр свободен.
		for dx = -1, 1, 2 do
			for dz = -1, 1, 2 do
				add_plan_entry(plan, cx + dx, cy, cz + dz, "fence", materials.fence)
				add_plan_entry(plan, cx + dx, cy + 1, cz + dz, "fence", materials.fence)
			end
		end
		return plan
	end

	if kind == "woodpile" then
		-- Поленница в два ряда у южной стороны.
		for dx = -1, 1 do
			for dy = 0, 1 do
				add_plan_entry(plan, cx + dx, cy + dy, cz + 1, "woodpile", materials.wall)
			end
		end
		return plan
	end

	if kind == "pavilion" then
		-- Открытая беседка: четыре столба и крыша.
		for dx = -1, 1, 2 do
			for dz = -1, 1, 2 do
				add_plan_entry(plan, cx + dx, cy, cz + dz, "post", materials.wall)
				add_plan_entry(plan, cx + dx, cy + 1, cz + dz, "post", materials.wall)
			end
		end
		for dx = -1, 1 do
			for dz = -1, 1 do
				add_plan_entry(plan, cx + dx, cy + 2, cz + dz, "roof", materials.roof)
			end
		end
		return plan
	end

	-- Навес: стены в два блока, крыша и дверной проём с юга.
	for dx = -1, 1 do
		for dz = -1, 1 do
			if math.abs(dx) == 1 or math.abs(dz) == 1 then
				local door = (dx == 0 and dz == 1)
				if not door then
					add_plan_entry(plan, cx + dx, cy, cz + dz, "wall", materials.wall)
					add_plan_entry(plan, cx + dx, cy + 1, cz + dz, "wall", materials.wall)
				end
			end
		end
	end
	for dx = -1, 1 do
		for dz = -1, 1 do
			add_plan_entry(plan, cx + dx, cy + 2, cz + dz, "roof", materials.roof)
		end
	end
	return plan
end

-- Старое имя оставляем для совместимости с тестами и сторонними вызовами.
function W.hut_plan(center, materials)
	return W.build_plan("shelter", center, materials)
end

function W.plan_requirements(plan)
	local req = { wood = 0, stone = 0 }
	for _, entry in ipairs(plan or {}) do
		local resource = W.resource_for_node(entry.node)
		req[resource] = (req[resource] or 0) + 1
	end
	return req
end

function W.can_afford(brain, req)
	if W.is_creative() then return true end
	local carry = brain and brain.carry or {}
	for resource, amount in pairs(req or {}) do
		if (carry[resource] or 0) < amount then return false end
	end
	return true
end

-- План с запасным вариантом: если камня не хватает, крыша делается из
-- того же материала, что и стены.
function W.affordable_plan(kind, center, brain)
	local materials = W.build_materials()
	local plan = W.build_plan(kind, center, materials)
	local req = W.plan_requirements(plan)
	if W.can_afford(brain, req) then return plan, req end
	local fallback = W.build_plan(kind, center, { wall = materials.wall, roof = materials.wall, fence = materials.fence })
	req = W.plan_requirements(fallback)
	if W.can_afford(brain, req) then return fallback, req end
	return nil, nil
end

-- Выбираем не только доступную, но и ещё не построенную постройку. Так
-- житель постепенно обустраивает участок разными вещами.
function W.choose_build_kind(brain)
	brain = brain or {}
	local built = brain.flags and brain.flags.built_kinds or {}
	if type(built) ~= "table" then built = {} end
	local any_affordable = nil
	for _, kind in ipairs(W.build_kind_order) do
		local plan = W.affordable_plan(kind, { x = 0, y = 0, z = 0 }, brain)
		if plan then
			any_affordable = any_affordable or kind
			if not built[kind] then return kind end
		end
	end
	return any_affordable
end

function W.is_build_site_clear(center)
	if not center then return false end
	local cx, cy, cz = floor(center.x), floor(center.y), floor(center.z)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local below = { x = cx + dx, y = cy - 1, z = cz + dz }
			if not W.is_walkable_name(W.node_at(below).name) then return false end
			for dy = 0, 2 do
				if not W.is_air({ x = cx + dx, y = cy + dy, z = cz + dz }) then
					return false
				end
			end
		end
	end
	return true
end

-- Не строим на голове у игрока или другого жителя: это главная причина,
-- по которой раньше можно было случайно замуровать себя или прохожего.
local function entity_overlaps_node(ep, pos)
	if not ep then return false end
	local dx = math.abs(ep.x - (pos.x + 0.5))
	local dz = math.abs(ep.z - (pos.z + 0.5))
	-- Половина ширины блока (0.5) плюс половина ширины жителя/игрока
	-- (до 0.3): всё, что ближе, уже пересекается с телом.
	if dx >= 0.8 or dz >= 0.8 then return false end
	local feet = ep.y
	-- Блок на уровне тела или головы.
	if pos.y < feet + 1.75 and pos.y + 1 > feet then return true end
	-- Блок прямо под ногами: его нельзя выкопать или заменить, иначе
	-- житель (или игрок) провалится.
	if pos.y + 1 >= feet - 0.05 and pos.y < feet then return true end
	return false
end

function W.node_occupied(pos, entity)
	if type(pos) ~= "table" then return true end
	if entity and entity.object then
		local ep = entity.object:get_pos()
		if ep and entity_overlaps_node(ep, pos) then return true end
	end
	for _, other in pairs(smart_npc.active or {}) do
		if other ~= entity and other.object then
			local ep = other.object:get_pos()
			if ep and entity_overlaps_node(ep, pos) then return true end
		end
	end
	local players = minetest.get_connected_players and minetest.get_connected_players() or {}
	for _, player in ipairs(players) do
		local ep = player:get_pos()
		if ep and entity_overlaps_node(ep, pos) then return true end
	end
	if minetest.get_objects_inside_radius then
		local center = { x = pos.x + 0.5, y = pos.y + 0.5, z = pos.z + 0.5 }
		for _, obj in ipairs(minetest.get_objects_inside_radius(center, 0.8)) do
			local ep = obj:get_pos()
			if ep and entity_overlaps_node(ep, pos) then return true end
		end
	end
	return false
end

-- Свободная точка, где можно встать. Нужна для аварийного выхода из
-- блока и для проверки места под факел.
function W.free_standing_pos(center, radius)
	if type(center) ~= "table" or center.x == nil then return nil end
	radius = math.max(0, math.floor(radius or 3))
	local cx, cy, cz = floor(center.x), floor(center.y), floor(center.z)
	for r = 0, radius do
		for dx = -r, r do
			for dz = -r, r do
				if r == 0 or math.max(math.abs(dx), math.abs(dz)) == r then
					for dy = 1, -1, -1 do
						local x, y, z = cx + dx, cy + dy, cz + dz
						local feet = { x = x, y = y, z = z }
						local head = { x = x, y = y + 1, z = z }
						local below = { x = x, y = y - 1, z = z }
						if W.is_air(feet) and W.is_air(head)
							and W.is_walkable_name(W.node_at(below).name) then
							return { x = x + 0.5, y = y, z = z + 0.5 }
						end
					end
				end
			end
		end
	end
	return nil
end

function W.entity_inside_solid(entity)
	if not entity or not entity.object then return false end
	local pos = entity.object:get_pos()
	if not pos then return false end
	return W.is_solid(pos) or W.is_solid({ x = pos.x, y = pos.y + 0.9, z = pos.z })
end

function W.escape_solid(entity, prefer)
	if not W.entity_inside_solid(entity) then return true end
	local pos = entity.object:get_pos()
	local spot = W.free_standing_pos(prefer or pos, 3)
	if not spot then return false end
	entity.object:set_pos(spot)
	W.set_velocity(entity.object, { x = 0, y = 0, z = 0 })
	entity._path = nil
	entity._stuck_time = 0
	entity._detour = nil
	entity._last_move_pos = nil
	return true
end

-- Все клетки плана должны быть свободны: иначе постройка заменит склон,
-- чужую стену или ствол. Центр при этом тоже остаётся воздухом.
function W.build_plan_clear(plan)
	for _, entry in ipairs(plan or {}) do
		if not W.is_air(entry.pos) then return false end
	end
	return true
end

local function site_has_people(center, brain)
	local self_entity = smart_npc.active and smart_npc.active[brain.id]
	for _, other in pairs(smart_npc.active or {}) do
		if other ~= self_entity and other.object then
			local ep = other.object:get_pos()
			if ep and U.horizontal_distance(center, ep) < 2.4 and math.abs(center.y - ep.y) < 3 then
				return true
			end
		end
	end
	local players = minetest.get_connected_players and minetest.get_connected_players() or {}
	for _, player in ipairs(players) do
		local ep = player:get_pos()
		if ep and U.horizontal_distance(center, ep) < 2.4 and math.abs(center.y - ep.y) < 3 then
			return true
		end
	end
	return false
end

-- Ищем ровную площадку недалеко от дома. Стены не должны пересекать
-- существующие постройки или стволы, поэтому проверяем весь объём 3×3×3.
function W.find_build_site(brain, ctx, radius, kind)
	brain = brain or {}
	local base = (brain.knowledge and brain.knowledge.home) or (ctx and ctx.pos)
	if not base then return nil end
	radius = math.max(1, math.floor(radius or 8))
	kind = W.build_kind_valid(kind) and kind or "shelter"
	local bx, by, bz = floor(base.x), floor(base.y), floor(base.z)
	for r = 0, radius do
		for dx = -r, r do
			for dz = -r, r do
				if r == 0 or math.max(math.abs(dx), math.abs(dz)) == r then
					local x, z = bx + dx, bz + dz
					for y = by + 1, by - 4, -1 do
						local center = { x = x, y = y, z = z }
						local feet = { x = x, y = y, z = z }
						local head = { x = x, y = y + 1, z = z }
						if W.is_air(feet) and W.is_air(head)
							and W.is_walkable_name(W.node_at({ x = x, y = y - 1, z = z }).name)
							and W.is_build_site_clear(center) and not site_has_people(center, brain) then
							local plan = W.build_plan(kind, center)
							local blocked = not W.build_plan_clear(plan)
							if not blocked then
								for _, entry in ipairs(plan) do
									if W.is_protected(entry.pos, brain) then blocked = true break end
								end
							end
							if not blocked then return center end
						end
					end
				end
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Копание и поделки
-- ---------------------------------------------------------------------------
function W.is_diggable_name(name)
	local def = minetest.registered_nodes[name]
	if not def or not def.groups then return false end
	return (def.groups.stone or 0) > 0 and (def.groups.tree or 0) == 0
		and (def.groups.wood or 0) == 0 and (def.groups.liquid or 0) == 0
end

-- Ищем камень на поверхности рядом, но не под ногами жителя и не в самом
-- доме: иначе житель выкопает площадку, на которой стоит.
function W.find_dig_pos(center, radius, brain, entity)
	if type(center) ~= "table" or center.x == nil then return nil end
	radius = math.max(1, math.floor(radius or 8))
	local home = brain and brain.knowledge and brain.knowledge.home
	local cx, cy, cz = floor(center.x), floor(center.y), floor(center.z)
	local self_pos = entity and entity.object and entity.object:get_pos()
	for r = 1, radius do
		for dx = -r, r do
			for dz = -r, r do
				if math.max(math.abs(dx), math.abs(dz)) == r then
					for dy = -2, 2 do
						local pos = { x = cx + dx, y = cy + dy, z = cz + dz }
						local name = W.node_at(pos).name
						if W.is_diggable_name(name) and W.is_air({ x = pos.x, y = pos.y + 1, z = pos.z })
							and W.is_walkable_name(W.node_at({ x = pos.x, y = pos.y - 1, z = pos.z }).name)
							and not W.node_occupied(pos, entity) then
							local near_self = self_pos and U.horizontal_distance(pos, self_pos) < 1.5
							local near_home = home and U.horizontal_distance(pos, home) < 2.2
							if not near_self and not near_home and not W.is_protected(pos, brain)
								and W.approach_pos(pos, 2) then
								return pos
							end
						end
					end
				end
			end
		end
	end
	return nil
end

function W.find_torch_spot(center, radius, brain, entity)
	if type(center) ~= "table" or center.x == nil then return nil end
	radius = math.max(1, math.floor(radius or 5))
	if not minetest.registered_nodes["default:torch"] then return nil end
	local cx, cy, cz = floor(center.x), floor(center.y), floor(center.z)
	for r = 0, radius do
		for dx = -r, r do
			for dz = -r, r do
				if r == 0 or math.max(math.abs(dx), math.abs(dz)) == r then
					local pos = { x = cx + dx, y = cy, z = cz + dz }
					if W.is_air(pos) and W.is_walkable_name(W.node_at({ x = pos.x, y = pos.y - 1, z = pos.z }).name)
						and W.is_air({ x = pos.x, y = pos.y + 1, z = pos.z })
						and not W.node_occupied(pos, entity) and not W.is_protected(pos, brain) then
						return pos
					end
				end
			end
		end
	end
	return nil
end

function W.craft_recipe(brain)
	local creative = W.is_creative()
	brain = brain or {}
	local carry = brain.carry or {}
	if minetest.registered_nodes["default:torch"] then
		if creative or ((carry.wood or 0) >= 1 and (carry.stone or 0) >= 1) then
			return {
				id = "torch",
				title = "факел",
				node = "default:torch",
				wood = 1,
				stone = 1,
				crafted = 1,
				label = "факел",
				say = "Смастерил(а) факел. Будет светлее.",
			}
		end
	end
	return nil
end

-- Возвращает true, если получилось поставить факел.
function W.place_torch(center, brain, entity)
	if not minetest.registered_nodes["default:torch"] then return false end
	local spot = W.find_torch_spot(center, 5, brain, entity)
	if not spot then return false end
	minetest.set_node(spot, { name = "default:torch" })
	W.particles(spot, "default_torch_on_floor.png", 4, 0.2, 0.5)
	return true, spot
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
	entity._detour = nil
	entity._detour_until = nil
	entity._last_move_pos = nil
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
		24, 1, 3
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

-- Свободная точка сбоку от препятствия: шаг в сторону, а не бесконечный
-- прыжок в стену. Если сбоку тоже стена, возвращаем nil.
local function sidestep_point(pos, dirx, dirz, sign)
	for distance = 1.6, 0.8, -0.4 do
		local x = pos.x + (-dirz * sign) * distance
		local z = pos.z + (dirx * sign) * distance
		if W.is_air({ x = x, y = pos.y, z = z })
			and W.is_air({ x = x, y = pos.y + 1, z = z })
			and W.is_walkable_name(W.node_at({ x = x, y = pos.y - 1, z = z }).name) then
			return { x = x, y = pos.y, z = z }
		end
	end
	return nil
end

-- Несколько точек перед жителем: одна точка иногда попадает в щель между
-- блоками, и тогда он не понимает, что перед ним ступенька.
local function probe_solid(pos, dirx, dirz, distance, height)
	return W.is_solid({
		x = pos.x + dirx * distance,
		y = pos.y + height,
		z = pos.z + dirz * distance,
	})
end

-- Куда нужно встать, чтобы оказаться на вершине одной ступеньки. Это
-- аварийный «подъём» после того, как обычный прыжок несколько раз не вышел.
local function climb_point(pos, dirx, dirz)
	local by = floor(pos.y)
	for distance = 0.55, 1.25, 0.2 do
		local x = floor(pos.x + dirx * distance)
		local z = floor(pos.z + dirz * distance)
		local step = { x = x, y = by, z = z }
		if W.is_solid(step)
			and W.is_air({ x = x, y = by + 1, z = z })
			and W.is_air({ x = x, y = by + 2, z = z })
			and W.is_walkable_name(W.node_at(step).name) then
			return { x = x + 0.5, y = by + 1, z = z + 0.5 }
		end
	end
	return nil
end

-- Двигает существо к точке. Возвращает "moving", "arrived" или "blocked".
function W.move_to(entity, target, dt, speed, radius)
	local obj = entity.object
	local pos = obj:get_pos()
	if not pos or type(target) ~= "table" or target.x == nil or target.z == nil then
		return "blocked"
	end
	radius = radius or 1.1

	-- Не идём внутрь твёрдого блока: для осмотра камня/ствола нужна
	-- соседняя точка, иначе житель бесконечно упирается в грань.
	if target.y ~= nil and W.is_solid(target) then
		local approach = W.approach_pos(target, 2)
		if not approach then return "blocked" end
		target = approach
	end

	if target.y == nil then
		target = { x = target.x, y = pos.y, z = target.z }
	end
	local dx, dz = target.x - pos.x, target.z - pos.z
	local distance = sqrt(dx * dx + dz * dz)
	local dy = target.y - pos.y

	-- Раньше допуск 2.2 блока означал, что житель «приходил» к цели на
	-- вершине соседнего блока, даже не запрыгнув на него. Теперь для
	-- наземной цели нужно действительно оказаться на её уровне.
	local supported = W.is_grounded(pos)
	local high_target = dy > 1.2
	if distance <= radius and math.abs(dy) <= 0.95 and (supported or high_target) then
		W.brake(entity)
		entity._stuck_time = 0
		entity._detour = nil
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
		if point and U.horizontal_distance(pos, point) < 0.8 and math.abs(pos.y - point.y) < 0.95 then
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
	local steerx, steerz = dirx, dirz

	-- Если житель упёрся и прыжок не помогает, обходим препятствие боком.
	if (entity._stuck_time or 0) > 0.9 and distance > 1.2 then
		if not entity._detour or now > (entity._detour_until or 0) then
			local side = (entity._detour_side == 1) and -1 or 1
			entity._detour_side = side
			local side_point = sidestep_point(pos, dirx, dirz, side)
			if not side_point then
				side = -side
				entity._detour_side = side
				side_point = sidestep_point(pos, dirx, dirz, side)
			end
			entity._detour = side_point
			entity._detour_until = now + 1.4
		end
		local detour = entity._detour
		if detour then
			local ddx, ddz = detour.x - pos.x, detour.z - pos.z
			local dlength = sqrt(ddx * ddx + ddz * ddz)
			if dlength > 0.15 then
				steerx, steerz = ddx / dlength, ddz / dlength
			end
		end
	end

	-- Прыжок через ступеньку или наверх. Проверяем несколько точек, чтобы
	-- не пропустить блок на краю диагонали, и не прыгаем в двухблочную
	-- стену: её всё равно не перепрыгнуть, лучше сразу обойти.
	local velocity = W.get_velocity(obj)
	local low = probe_solid(pos, steerx, steerz, 0.5, 0.2)
		or probe_solid(pos, steerx, steerz, 0.75, 0.35)
		or probe_solid(pos, steerx, steerz, 0.95, 0.2)
	local head = probe_solid(pos, steerx, steerz, 0.55, 1.15)
		or probe_solid(pos, steerx, steerz, 0.8, 1.2)
	local clear_top = not probe_solid(pos, steerx, steerz, 0.55, 1.8)
	local needs_jump = (low and (not head or clear_top)) or dy > 0.8
	local grounded = W.is_grounded(pos)
	local on_ground = grounded and math.abs(velocity.y) < 2.0

	if needs_jump and on_ground then
		W.set_velocity(obj, { x = steerx * speed, y = 5.2, z = steerz * speed })
	elseif grounded and velocity.y <= 0.6 then
		-- Не накапливаем скорость падения, пока стоим на опоре.
		W.set_velocity(obj, { x = steerx * speed, y = 0, z = steerz * speed })
	else
		W.set_velocity(obj, { x = steerx * speed, y = velocity.y, z = steerz * speed })
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
		W.set_velocity(obj, { x = steerx * speed, y = 5.2, z = steerz * speed })
	end

	-- Если прыжок несколько раз подряд не помог, аккуратно ставим жителя
	-- на вершину ровной ступеньки. Это лучше, чем полминуты «бодать» блок
	-- и затем бросить цель. Подъём разрешён только на один блок и только
	-- когда над ним есть свободное место.
	if (entity._stuck_time or 0) > 2.2 and on_ground and dy > -0.3 then
		local assist = climb_point(pos, steerx, steerz)
		if assist then
			obj:set_pos(assist)
			W.set_velocity(obj, { x = 0, y = 0, z = 0 })
			entity._stuck_time = 0
			entity._detour = nil
			entity._last_move_pos = U.vector_copy(assist)
			return "moving"
		end
	end
	if (entity._stuck_time or 0) > 4.5 then
		W.brake(entity)
		entity._path = nil
		entity._detour = nil
		return "blocked"
	end

	return "moving"
end

-- Посадить простое дерево (ствол + крона) на свободном месте. Нужно для
-- пустых творческих миров и демонстрации рубки.
function W.plant_tree(center)
	if type(center) ~= "table" or center.x == nil or center.y == nil or center.z == nil then
		return false
	end
	local trunk = nil
	for _, name in ipairs(smart_npc.tree_nodes or {}) do
		if name ~= "" then trunk = name break end
	end
	trunk = trunk or "default:tree"
	local x, y, z = floor(center.x), floor(center.y), floor(center.z)
	if not W.is_walkable_name(W.node_at({ x = x, y = y - 1, z = z }).name) then
		return false
	end
	for dy = 0, 3 do
		if not W.is_air({ x = x, y = y + dy, z = z }) then return false end
	end
	for dy = 0, 3 do
		minetest.set_node({ x = x, y = y + dy, z = z }, { name = trunk })
	end
	local leaves = minetest.registered_nodes["default:leaves"] and "default:leaves" or nil
	if leaves then
		for dx = -1, 1 do
			for dz = -1, 1 do
				if not (dx == 0 and dz == 0) then
					local leaf_pos = { x = x + dx, y = y + 3, z = z + dz }
					if W.is_air(leaf_pos) then
						minetest.set_node(leaf_pos, { name = leaves })
					end
				end
			end
		end
		if W.is_air({ x = x, y = y + 4, z = z }) then
			minetest.set_node({ x = x, y = y + 4, z = z }, { name = leaves })
		end
	end
	return true
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
