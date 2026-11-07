-- Исполнение желаний: конечный автомат действий над сущностью.
-- Мозг выбирает желание (brain.goal), а этот модуль ведёт жителя по миру:
-- идёт к цели, ест, спит, разговаривает, играет и так далее.

local A = {}
smart_npc.actions = A
local U = smart_npc.util
local B = smart_npc.brain
local N = smart_npc.needs
local M = smart_npc.memory
local W = smart_npc.world
local T = smart_npc.dialogue

local ACTIONS = {}
A.registry = ACTIONS

local WALK_SPEED = 1.9
local RUN_SPEED = 2.8

local function node_description(name)
	local def = minetest.registered_nodes[name]
	return def and def.description or name
end

local function item_description(itemstring)
	local name = itemstring:match("^([^%s]+)") or itemstring
	local def = minetest.registered_items[name]
	return def and def.description or name
end

local function move_to(entity, a, target, dtime, speed, radius)
	if not target then return "blocked" end
	-- Измождённый или голодный житель плетётся медленнее.
	local brain = entity._brain
	if brain then
		if N.get(brain, "energy") < 15 then speed = speed * 0.75 end
		if N.get(brain, "hunger") < 12 then speed = speed * 0.7 end
	end
	a.goal_pos = target
	local result = W.move_to(entity, target, dtime, speed or WALK_SPEED, radius or 1.3)
	if result == "moving" then
		W.animate(entity, "walk", 30)
	end
	return result
end

local function idle(entity)
	W.brake(entity)
	W.animate(entity, "stand")
end

local function node_particle(name)
	local def = minetest.registered_nodes[name]
	if def then
		if def.inventory_image and def.inventory_image ~= "" then
			return def.inventory_image:gsub("%^.*$", "")
		end
		if def.tiles and def.tiles[1] then
			local tile = def.tiles[1]
			if type(tile) == "table" then tile = tile.name end
			if type(tile) == "string" then return tile:gsub("%^.*$", "") end
		end
	end
	return "default_apple.png"
end

-- ===========================================================================
-- ЕДА
-- ===========================================================================
ACTIONS.eat = {
	start = function(entity, brain, a, now, ctx)
		if (brain.carry.food or 0) > 0 then
			a.phase = "chew"
			a.timer = 2.5
			a.item_label = "припасённую еду"
			return a
		end

		local food_pos, food_name = W.find_food_pos(brain, ctx, 14)
		if food_pos and not W.is_protected(food_pos, brain) then
			a.phase = "go"
			a.goal_pos = { x = food_pos.x + 0.5, y = food_pos.y, z = food_pos.z + 0.5 }
			a.food_pos = food_pos
			a.food_name = food_name
			return a
		end

		local item_obj, itemstring = W.find_food_item(ctx.pos, 7)
		if item_obj then
			a.phase = "pickup"
			a.item = item_obj
			a.item_label = item_description(itemstring)
			return a
		end

		local target = W.nearest_social(ctx, "player", 12)
		if target then
			a.phase = "beg"
			a.target = target.key
			a.timer = 0
			return a
		end
		return nil
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "chew" then
			W.brake(entity)
			W.animate(entity, "mine", 20)
			a.timer = a.timer - dtime
			if math.random() < dtime * 0.6 then
				W.particles(entity.object:get_pos(), "default_apple.png", 2, 0.3, 1.2)
			end
			if a.timer <= 0 then
				brain.carry.food = math.max(0, (brain.carry.food or 1) - 1)
				B.eat(brain, a.item_label or "еду", now)
				W.sound(entity.object:get_pos(), "default_dig_crumbly", 0.4)
				return "done"
			end
			return "running"
		end

		if a.phase == "go" then
			local name = minetest.get_node(a.food_pos).name
			if not smart_npc.is_food_node(name) then
				a.phase = "search_again"
				return "running"
			end
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.6)
			if result == "arrived" then
				if W.is_protected(a.food_pos, brain) then return "fail" end
				local current = minetest.get_node(a.food_pos)
				if smart_npc.is_food_node(current.name) then
					W.particles(a.food_pos, node_particle(current.name), 6, 0.3, 0.8)
					minetest.remove_node(a.food_pos)
					W.sound(a.food_pos, "default_dig_crumbly", 0.5)
					if brain.cache then brain.cache.food_pos = nil end
					B.eat(brain, node_description(current.name), now, 36)
					return "done"
				end
				return "fail"
			elseif result == "blocked" then
				return "fail"
			end
			return "running"
		end

		if a.phase == "search_again" then
			a.timer = (a.timer or 0) + dtime
			local food_pos, food_name = W.find_food_pos(brain, ctx, 14)
			if food_pos then
				a.phase = "go"
				a.goal_pos = { x = food_pos.x + 0.5, y = food_pos.y, z = food_pos.z + 0.5 }
				a.food_pos = food_pos
				a.food_name = food_name
				a.timer = 0
				return "running"
			end
			if a.timer > 2 then return "fail" end
			return "running"
		end

		if a.phase == "pickup" then
			local item_pos = a.item and a.item:get_pos()
			if not item_pos then return "fail" end
			local result = move_to(entity, a, item_pos, dtime, WALK_SPEED, 1.2)
			if result == "arrived" then
				local lua = a.item:get_luaentity()
				local label = a.item_label or "еду"
				if lua and lua.itemstring then
					label = item_description(lua.itemstring)
				end
				a.item:remove()
				B.eat(brain, label, now, 34)
				return "done"
			elseif result == "blocked" then
				return "fail"
			end
			return "running"
		end

		if a.phase == "beg" then
			local target = W.resolve_target(brain, a.target, ctx)
			if not target then return "fail" end
			local result = move_to(entity, a, target.pos, dtime, WALK_SPEED, 2.4)
			if result == "arrived" or result == "blocked" then
				idle(entity)
				W.face(entity, target.pos)
				if not a.said then
					a.said = true
					a.timer = 0
					W.say(entity, T.beg(brain, target.name))
					B.beg(brain, target.name, now)
					W.particles(entity.object:get_pos(), "npc_sweat.png", 3, 0.4, 1.8)
				end
				a.timer = (a.timer or 0) + dtime
				if (brain.carry.food or 0) > 0 then return "done" end
				if a.timer > 18 then return "fail" end
				return "running"
			end
			return "running"
		end

		return "fail"
	end,
}

-- ===========================================================================
-- СОН
-- ===========================================================================
ACTIONS.sleep = {
	start = function(entity, brain, a, now, ctx)
		if not ctx.environment.night and N.get(brain, "energy") > 48 then
			return nil
		end
		a.phase = "go"
		a.timer = 0
		local home = brain.knowledge.home
		local pos = ctx.pos
		if home and U.distance(pos, home) > 5 and U.distance(pos, home) < 40 then
			a.goal_pos = home
		else
			a.phase = "lie"
		end
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.5)
			if result == "arrived" or result == "blocked" then
				a.phase = "lie"
				a.timer = 0
			end
			return "running"
		end

		W.brake(entity)
		W.animate(entity, "lay", 30)
		brain.activity = "sleep"
		a.timer = (a.timer or 0) + dtime
		if math.random() < dtime * 0.5 then
			W.particles(entity.object:get_pos(), "npc_zzz.png", 2, 0.5, 1.9)
		end
		if N.get(brain, "energy") >= 92 or a.timer > 35 then
			-- Сон должен заметно восстанавливать силы, а не только тянуть время.
			N.add(brain, "energy", 45)
			N.add(brain, "comfort", 6)
			M.nap(brain, now)
			brain.stats.naps = (brain.stats.naps or 0) + 1
			return "done"
		end
		if brain.last_hurt and now - brain.last_hurt < 5 then
			return "fail"
		end
		return "running"
	end,
}

-- ===========================================================================
-- РАЗГОВОР
-- ===========================================================================
local function too_fearful(brain, key)
	local rel = key and brain.memory.relationships[key]
	return rel ~= nil and (rel.fear or 0) >= 50
end

ACTIONS.talk = {
	start = function(entity, brain, a, now, ctx)
		local target = a.target and W.resolve_target(brain, a.target, ctx) or nil
		if target and too_fearful(brain, target.key) then target = nil end
		if not target then
			target = W.nearest_social(ctx, nil, 24)
			if target and too_fearful(brain, target.key) then target = nil end
		end
		if not target then return nil end
		a.target = target.key
		a.target_pos = target.pos
		a.target_name = target.name
		a.target_kind = target.kind
		a.phase = "go"
		a.timer = 0
		a.resolve_timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.resolve_timer = (a.resolve_timer or 0) + dtime
		if a.resolve_timer > 0.7 then
			a.resolve_timer = 0
			local target = W.resolve_target(brain, a.target, ctx)
			if not target or too_fearful(brain, target.key) then return "fail" end
			a.target_pos = target.pos
			a.target_name = target.name
			a.target_kind = target.kind
		end
		local target_pos = a.target_pos
		if not target_pos then return "fail" end

		if a.phase == "go" then
			local result = move_to(entity, a, target_pos, dtime, WALK_SPEED, 2.4)
			if result == "arrived" or result == "blocked" then
				a.phase = "chat"
				a.timer = 0
				if not a.said then
					a.said = true
					if a.target_kind == "player" or U.rand_int(brain, 1, 100) <= 25 then
						W.say(entity, T.talk_line(brain, a.target_name or "друг", now, a.story))
					end
					W.face(entity, target_pos)
					local gain = a.story and 22 or 16
					B.converse(brain, a.target, a.target_name or "знакомый", now, nil, { gain = gain })
					if a.target_kind == "npc" then
						-- Собеседник тоже запоминает разговор и привязывается.
						local other = smart_npc.active[a.target:sub(5)]
						if other and other._brain then
							B.converse(other._brain, "npc:" .. brain.id, brain.name, now, nil, { gain = 10 })
						end
					end
					W.particles(entity.object:get_pos(), "npc_heart.png", 2, 0.4, 1.8)
				end
			end
			return "running"
		end

		if a.phase == "chat" then
			idle(entity)
			W.face(entity, target_pos)
			a.timer = (a.timer or 0) + dtime
			if a.timer > 3.5 then return "done" end
			return "running"
		end

		return "fail"
	end,
}

-- ===========================================================================
-- ИГРЫ
-- ===========================================================================
ACTIONS.play = {
	start = function(entity, brain, a, now, ctx)
		local home = brain.knowledge.home or ctx.pos
		local target = W.random_walkable_near(home, 9, function(lo, hi) return U.rand_int(brain, lo, hi) end)
		if not target then return nil end
		a.goal_pos = target
		a.phase = "go"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, RUN_SPEED, 1.6)
			if result == "arrived" or result == "blocked" then
				a.phase = "fun"
				a.timer = 0
			end
			return "running"
		end

		a.timer = (a.timer or 0) + dtime
		brain.activity = "play"
		W.animate(entity, "run", 35)
		if math.random() < dtime * 0.9 then
			local pos = entity.object:get_pos()
			local velocity = W.get_velocity(entity.object)
			-- Прыгать можно только с настоящей опоры: иначе на вершине
			-- прыжка скорость близка к нулю и житель улетает в небо.
			if W.is_grounded(pos) and math.abs(velocity.y) < 0.5 then
				W.set_velocity(entity.object, {
					x = (math.random() - 0.5) * 2,
					y = 4.3,
					z = (math.random() - 0.5) * 2,
				})
			end
			W.particles(entity.object:get_pos(), "npc_heart.png", 3, 0.5, 1.8)
		end
		if math.random() < dtime * 0.4 then
			W.say(entity, U.pick(U.new_rng(U.hash(brain.id .. tostring(math.floor(now)))), {
				"Ух!",
				"Как здорово!",
				"Лови меня!",
			}))
		end
		if a.timer > 6 then
			M.play(brain, now)
			N.add(brain, "fun", 8)
			return "done"
		end
		return "running"
	end,
}

-- ===========================================================================
-- ГИГИЕНА
-- ===========================================================================
ACTIONS.wash = {
	start = function(entity, brain, a, now, ctx)
		local water = ctx.water
		if water then
			local spot = W.random_walkable_near(water, 3, function(lo, hi) return U.rand_int(brain, lo, hi) end)
			if spot then
				a.phase = "go"
				a.goal_pos = spot
				return a
			end
		end
		a.phase = "dry"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.6)
			if result == "arrived" or result == "blocked" then
				a.phase = "splash"
				a.timer = 0
			end
			return "running"
		end

		if a.phase == "splash" or a.phase == "dry" then
			idle(entity)
			brain.activity = "wash"
			a.timer = (a.timer or 0) + dtime
			if a.phase == "splash" then
				if math.random() < dtime * 1.2 then
					W.particles(entity.object:get_pos(), "bubble.png", 4, 0.4, 1.6)
				end
				if a.timer > 4.5 then
					N.add(brain, "hygiene", 35)
					M.wash(brain, now)
					return "done"
				end
			else
				if math.random() < dtime * 0.5 then
					W.particles(entity.object:get_pos(), "npc_sweat.png", 2, 0.4, 1.6)
				end
				if a.timer > 3 then
					N.add(brain, "hygiene", 20)
					M.wash(brain, now)
					return "done"
				end
			end
			return "running"
		end

		return "fail"
	end,
}

-- ===========================================================================
-- УЮТ И БЕЗОПАСНОСТЬ
-- ===========================================================================
ACTIONS.warm = {
	start = function(entity, brain, a, now, ctx)
		if ctx.environment.sheltered or ctx.environment.warm then
			a.phase = "enjoy"
			a.timer = 0
			return a
		end
		local home = brain.knowledge.home
		local spot = home or W.random_walkable_near(ctx.pos, 7, function(lo, hi) return U.rand_int(brain, lo, hi) end)
		if not spot then
			a.phase = "enjoy"
			a.timer = 0
			return a
		end
		a.goal_pos = spot
		a.phase = "go"
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.6)
			if result == "arrived" or result == "blocked" then
				a.phase = "enjoy"
				a.timer = 0
			end
			return "running"
		end

		W.brake(entity)
		W.animate(entity, "sit", 25)
		brain.activity = "warm"
		a.timer = (a.timer or 0) + dtime
		if a.timer > 5 then
			N.add(brain, "comfort", 20)
			M.place(brain, "Посидел(а) в уютном месте", now, entity.object:get_pos(), 6)
			return "done"
		end
		return "running"
	end,
}

ACTIONS.seek_safety = {
	start = function(entity, brain, a, now, ctx)
		a.phase = "go"
		a.timer = 0
		a.goal_pos = W.safe_spot(brain, entity)
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, RUN_SPEED, 1.6)
			if result == "arrived" or result == "blocked" then
				a.phase = "calm"
				a.timer = 0
			end
			return "running"
		end

		idle(entity)
		brain.activity = "seek_safety"
		a.timer = (a.timer or 0) + dtime
		if a.timer > 4 then
			N.add(brain, "safety", 24)
			M.place(brain, "Нашёл(нашла) спокойное место", now, entity.object:get_pos(), 7)
			return "done"
		end
		return "running"
	end,
}

-- ===========================================================================
-- ИССЛЕДОВАНИЕ И НАБЛЮДЕНИЕ
-- ===========================================================================
ACTIONS.explore = {
	start = function(entity, brain, a, now, ctx)
		local spot = W.random_walkable_near(ctx.pos, 16, function(lo, hi) return U.rand_int(brain, lo, hi) end)
		if not spot then return nil end
		a.phase = "go"
		a.goal_pos = spot
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.6)
			if result == "arrived" or result == "blocked" then
				a.phase = "look"
				a.timer = 0
				a.look_timer = 0
			end
			if a.timer > 45 then return "fail" end
			return "running"
		end

		if a.phase == "look" then
			idle(entity)
			a.look_timer = (a.look_timer or 0) + dtime
			-- Медленно оглядываемся.
			entity.object:set_yaw((entity.object:get_yaw() or 0) + dtime * 0.8)
			if a.look_timer > 3 then
				local pos = entity.object:get_pos()
				N.add(brain, "fun", 12)
				M.explore(brain, now)
				B.knowledge_add(brain, pos, "место", "Запомнил(а) новое место", now, 8)
				return "done"
			end
			return "running"
		end

		return "fail"
	end,
}

ACTIONS.inspect = {
	start = function(entity, brain, a, now, ctx)
		if not ctx.interesting then return nil end
		a.interesting = ctx.interesting
		a.note = ctx.interesting_name and node_description(ctx.interesting_name) or "что-то интересное"
		a.phase = "go"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local target = { x = a.interesting.x + 0.5, y = a.interesting.y, z = a.interesting.z + 0.5 }
			local result = move_to(entity, a, target, dtime, WALK_SPEED, 2.6)
			if result == "arrived" or result == "blocked" then
				a.phase = "look"
				a.timer = 0
			end
			return "running"
		end

		if a.phase == "look" then
			idle(entity)
			W.face(entity, { x = a.interesting.x + 0.5, y = a.interesting.y, z = a.interesting.z + 0.5 })
			a.timer = (a.timer or 0) + dtime
			if a.timer > 4 then
				N.add(brain, "fun", 10)
				M.place(brain, "Разглядывал(а) " .. a.note, now, a.interesting, 7)
				B.knowledge_add(brain, a.interesting, "интересное", "Любопытное место: " .. a.note, now, 9)
				return "done"
			end
			return "running"
		end

		return "fail"
	end,
}

ACTIONS.tidy = {
	start = function(entity, brain, a, now, ctx)
		a.phase = "go"
		a.timer = 0
		a.goal_pos = brain.knowledge.home or ctx.pos
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.8)
			if result == "arrived" or result == "blocked" then
				a.phase = "tidy"
				a.timer = 0
			end
			return "running"
		end

		W.brake(entity)
		W.animate(entity, "mine", 25)
		a.timer = (a.timer or 0) + dtime
		if math.random() < dtime * 0.4 then
			W.particles(entity.object:get_pos(), "default_snow.png", 2, 0.6, 0.5)
		end
		if a.timer > 5 then
			N.add(brain, "comfort", 16)
			N.add(brain, "hygiene", 6)
			B.knowledge_add(brain, entity.object:get_pos(), "дом", "Прибрался(ась) у дома", now, 7)
			if not brain.knowledge.home then
				B.set_home(brain, entity.object:get_pos())
			end
			return "done"
		end
		return "running"
	end,
}

-- ===========================================================================
-- ОТНОШЕНИЯ
-- ===========================================================================
ACTIONS.thank = {
	start = function(entity, brain, a, now, ctx)
		local target = a.target and W.resolve_target(brain, a.target, ctx) or nil
		if not target then
			target = W.nearest_social(ctx, nil, 24)
		end
		if not target then return nil end
		a.target = target.key
		a.target_pos = target.pos
		a.target_name = target.name
		a.phase = "go"
		a.timer = 0
		a.gift_text = nil
		local gifts = M.recall(brain, now, { subjects = { target.key }, kinds = { "gift" }, limit = 1 })
		if gifts[1] then
			local stored = gifts[1].event.text
			a.gift_text = stored:match("мне (.+)$") or stored
		end
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		local target = W.resolve_target(brain, a.target, ctx)
		if target then
			a.target_pos = target.pos
			a.target_name = target.name
		end
		if a.phase == "go" then
			local result = move_to(entity, a, a.target_pos, dtime, WALK_SPEED, 2.4)
			if result == "arrived" or result == "blocked" then
				a.phase = "talk"
				a.timer = 0
			end
			return "running"
		end

		if a.phase == "talk" then
			idle(entity)
			if a.target_pos then W.face(entity, a.target_pos) end
			if not a.said then
				a.said = true
				W.say(entity, T.thanks(brain, a.target_name or "друг", a.gift_text))
				M.thanks(brain, a.target, a.target_name or "знакомый", now)
				N.add(brain, "social", 12)
				W.particles(entity.object:get_pos(), "npc_heart.png", 3, 0.4, 1.8)
			end
			a.timer = (a.timer or 0) + dtime
			if a.timer > 3.5 then return "done" end
			return "running"
		end

		return "fail"
	end,
}

ACTIONS.avoid = {
	start = function(entity, brain, a, now, ctx)
		local threat = a.target and W.resolve_target(brain, a.target, ctx) or nil
		a.threat_key = a.target
		a.threat_pos = threat and threat.pos or nil
		a.phase = "flee"
		a.timer = 0
		a.repath = 0
		a.goal_pos = nil
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime
		a.repath = (a.repath or 0) + dtime
		local threat = W.resolve_target(brain, a.threat_key, ctx)

		if a.repath > 1.5 or not a.goal_pos then
			a.repath = 0
			local pos = entity.object:get_pos()
			if threat then
				a.threat_pos = threat.pos
				local dx, dz = pos.x - threat.pos.x, pos.z - threat.pos.z
				local length = math.sqrt(dx * dx + dz * dz)
				if length < 0.1 then dx, dz, length = 1, 0, 1 end
				local away = {
					x = pos.x + (dx / length) * 9,
					y = pos.y,
					z = pos.z + (dz / length) * 9,
				}
				a.goal_pos = W.random_walkable_near(away, 4, function(lo, hi) return U.rand_int(brain, lo, hi) end) or away
			else
				a.goal_pos = W.random_walkable_near(pos, 5, function(lo, hi) return U.rand_int(brain, lo, hi) end)
			end
		end

		local result = move_to(entity, a, a.goal_pos, dtime, RUN_SPEED, 1.4)
		if a.timer > 7 or result == "blocked" then
			N.add(brain, "safety", 14)
			local rel = brain.memory.relationships[a.threat_key]
			if rel then rel.fear = U.clamp((rel.fear or 0) - 5, 0, 100) end
			return "done"
		end
		return "running"
	end,
}

ACTIONS.follow = {
	start = function(entity, brain, a, now, ctx)
		local target = a.target and W.resolve_target(brain, a.target, ctx) or nil
		if not target then return nil end
		a.target = target.key
		a.target_pos = target.pos
		a.target_name = target.name
		a.phase = "follow"
		a.timer = 0
		brain.flags.following = target.key
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		local target = W.resolve_target(brain, a.target, ctx)
		if not target then return "fail" end
		a.target_pos = target.pos
		a.target_name = target.name
		a.timer = (a.timer or 0) + dtime

		local distance = U.distance(entity.object:get_pos(), target.pos)
		if distance > 3.5 then
			move_to(entity, a, target.pos, dtime, RUN_SPEED, 2.8)
		else
			idle(entity)
			W.face(entity, target.pos)
		end

		if math.random() < dtime * 0.08 then
			W.say(entity, U.pick(U.new_rng(U.hash(brain.id .. tostring(math.floor(now)))), {
				"Я здесь.",
				"Не отставай... то есть не отставай, я иду.",
				"Хорошо идём.",
			}))
		end

		if a.timer > 60 then
			N.add(brain, "social", 8)
			return "done"
		end
		return "running"
	end,

	stop = function(entity, brain, a)
		brain.flags.following = nil
	end,
}

ACTIONS.solitude = {
	start = function(entity, brain, a, now, ctx)
		local pos = entity.object:get_pos()
		local spot
		for _ = 1, 8 do
			local candidate = W.random_walkable_near(pos, 9, function(lo, hi) return U.rand_int(brain, lo, hi) end)
			if candidate then
				local busy = false
				for _, target in ipairs(ctx.social_targets or {}) do
					if U.distance(candidate, target.pos) < 7 then busy = true break end
				end
				if not busy then spot = candidate break end
			end
		end
		if not spot then
			spot = W.random_walkable_near(pos, 6, function(lo, hi) return U.rand_int(brain, lo, hi) end)
		end
		if not spot then return nil end
		a.goal_pos = spot
		a.phase = "go"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.6)
			if result == "arrived" or result == "blocked" then
				a.phase = "sit"
				a.timer = 0
			end
			return "running"
		end

		W.brake(entity)
		W.animate(entity, "sit", 25)
		brain.activity = "solitude"
		a.timer = (a.timer or 0) + dtime
		if a.timer > 9 then
			N.add(brain, "comfort", 12)
			N.add(brain, "fun", 5)
			M.place(brain, "Побыл(а) наедине с собой", now, entity.object:get_pos(), 5)
			return "done"
		end
		return "running"
	end,
}

-- ===========================================================================
-- МИМИКА ОТНОШЕНИЙ
-- ===========================================================================
ACTIONS.reconcile = {
	start = function(entity, brain, a, now, ctx)
		local target = a.target and W.resolve_target(brain, a.target, ctx) or nil
		if not target then return nil end
		a.target = target.key
		a.target_pos = target.pos
		a.target_name = target.name
		a.phase = "go"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		local target = W.resolve_target(brain, a.target, ctx)
		if target then
			a.target_pos = target.pos
			a.target_name = target.name
		end
		if a.phase == "go" then
			local result = move_to(entity, a, a.target_pos, dtime, WALK_SPEED, 2.4)
			if result == "arrived" or result == "blocked" then
				a.phase = "talk"
				a.timer = 0
			end
			return "running"
		end

		if a.phase == "talk" then
			idle(entity)
			if a.target_pos then W.face(entity, a.target_pos) end
			if not a.said then
				a.said = true
				W.say(entity, "Давай забудем прошлое. Мне не хочется ссориться, " .. (a.target_name or "друг") .. ".")
				M.reconcile(brain, a.target, a.target_name or "знакомый", now)
				N.add(brain, "social", 10)
			end
			a.timer = (a.timer or 0) + dtime
			if a.timer > 4 then return "done" end
			return "running"
		end

		return "fail"
	end,
}

-- ===========================================================================
-- ПРОСЬБА, ИСТЕРИКА, ПРОГУЛКА, ВИЗИТ
-- ===========================================================================
ACTIONS.beg = {
	start = function(entity, brain, a, now, ctx)
		local target = W.nearest_social(ctx, "player", 14)
		if not target then return nil end
		a.target = target.key
		a.target_pos = target.pos
		a.target_name = target.name
		a.phase = "go"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		local target = W.resolve_target(brain, a.target, ctx)
		if target then
			a.target_pos = target.pos
			a.target_name = target.name
		end
		if a.phase == "go" then
			local result = move_to(entity, a, a.target_pos, dtime, WALK_SPEED, 2.5)
			if result == "arrived" or result == "blocked" then
				a.phase = "ask"
				a.timer = 0
			end
			return "running"
		end

		if a.phase == "ask" then
			idle(entity)
			if a.target_pos then W.face(entity, a.target_pos) end
			if not a.said then
				a.said = true
				W.say(entity, T.beg(brain, a.target_name or "друг"))
				B.beg(brain, a.target_name or "игрок", now)
				W.particles(entity.object:get_pos(), "npc_sweat.png", 3, 0.4, 1.8)
			end
			a.timer = (a.timer or 0) + dtime
			if (brain.carry.food or 0) > 0 then return "done" end
			if a.timer > 18 then return "fail" end
			return "running"
		end

		return "fail"
	end,
}

ACTIONS.tantrum = {
	start = function(entity, brain, a, now, ctx)
		a.phase = "cry"
		a.timer = 0
		brain.activity = "tantrum"
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		W.brake(entity)
		W.animate(entity, "lay", 30)
		brain.activity = "tantrum"
		a.timer = (a.timer or 0) + dtime
		if math.random() < dtime * 0.8 then
			W.particles(entity.object:get_pos(), "npc_anger.png", 3, 0.5, 1.9)
		end
		if math.random() < dtime * 0.25 then
			W.say(entity, T.tantrum_line(brain))
		end
		if brain.stress < 60 or a.timer > 30 then
			B.finish_tantrum(brain, now)
			return "done"
		end
		return "running"
	end,
}

-- ===========================================================================
-- РУБКА И СТРОИТЕЛЬСТВО
-- ===========================================================================
local function pay_for(brain, resource)
	brain.carry[resource] = math.max(0, (brain.carry[resource] or 0) - 1)
end

local function tree_at(pos)
	if type(pos) ~= "table" or pos.x == nil or pos.y == nil or pos.z == nil then
		return false
	end
	return smart_npc.is_tree_node(minetest.get_node(pos).name)
end

local function leaves_at(pos)
	if type(pos) ~= "table" or pos.x == nil or pos.y == nil or pos.z == nil then
		return false
	end
	local def = minetest.registered_nodes[minetest.get_node(pos).name]
	return def and def.groups and (def.groups.leaves or 0) > 0 or false
end

-- После ствола убираем небольшую крону, чтобы дерево не оставалось висеть.
local function clear_leaves(center, brain)
	if not center then return end
	local cx, cy, cz = math.floor(center.x), math.floor(center.y), math.floor(center.z)
	for dx = -2, 2 do
		for dz = -2, 2 do
			for dy = 1, 5 do
				local pos = { x = cx + dx, y = cy + dy, z = cz + dz }
				if leaves_at(pos) and not W.is_protected(pos, brain) then
					minetest.remove_node(pos)
				end
			end
		end
	end
end

ACTIONS.chop = {
	start = function(entity, brain, a, now, ctx)
		local tree = a.target_pos
		if not tree_at(tree) then
			local from = (ctx and ctx.pos) or brain.knowledge.home
			tree = W.find_resource_pos(from, smart_npc.tree_nodes, 20, brain)
		end
		if not tree then return nil end
		local approach = W.approach_pos(tree, 3)
		if not approach then return nil end
		a.tree_pos = U.vector_copy(tree)
		a.tree_start = U.vector_copy(tree)
		a.goal_pos = approach
		a.phase = "go"
		a.timer = 0
		a.chopped = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime

		if a.phase == "go" then
			if not tree_at(a.tree_pos) then
				return a.chopped > 0 and "done" or "fail"
			end
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.5)
			if result == "arrived" or result == "blocked" then
				a.phase = "chop"
				a.timer = 0
			elseif a.timer > 30 then
				return "fail"
			end
			return "running"
		end

		if a.phase == "chop" then
			idle(entity)
			W.face(entity, a.tree_pos)
			W.animate(entity, "mine", 20)
			if a.timer < 0.8 then return "running" end
			a.timer = 0

			local pos = entity.object:get_pos()
			local horizontal = pos and U.horizontal_distance(pos, a.tree_pos) or math.huge
			local vertical = pos and math.abs(pos.y - a.tree_pos.y) or math.huge
			if not pos or horizontal > 2.8 or vertical > 4.5 then
				local approach = W.approach_pos(a.tree_pos, 3)
				if approach then
					a.goal_pos = approach
					a.phase = "go"
					return "running"
				end
				return "fail"
			end
			if not tree_at(a.tree_pos) then
				return a.chopped > 0 and "done" or "fail"
			end
			if W.is_protected(a.tree_pos, brain) then return "fail" end

			local name = minetest.get_node(a.tree_pos).name
			W.particles(a.tree_pos, node_particle(name), 6, 0.35, 0.9)
			W.sound(a.tree_pos, "default_dig_choppy", 0.45)
			minetest.remove_node(a.tree_pos)
			a.chopped = (a.chopped or 0) + 1
			B.add_wood(brain, 1, now)
			N.add(brain, "energy", -2)
			N.add(brain, "fun", 1)

			local above = { x = a.tree_pos.x, y = a.tree_pos.y + 1, z = a.tree_pos.z }
			if a.chopped >= 5 or not tree_at(above) then
				clear_leaves(a.tree_start, brain)
				M.place(brain, "Заготовил(а) древесину: " .. tostring(a.chopped), now, a.tree_start, 10)
				W.say(entity, "Готово. Теперь есть чем заняться.")
				return "done"
			end
			a.tree_pos = above
			return "running"
		end

		return "fail"
	end,
}

ACTIONS.build = {
	start = function(entity, brain, a, now, ctx)
		local kind = a.build_kind
		if not W.build_kind_valid(kind) then
			kind = W.choose_build_kind(brain) or "shelter"
		end
		a.build_kind = kind
		local site = W.find_build_site(brain, ctx, 8, kind)
		if not site then return nil end

		local plan = W.affordable_plan(kind, site, brain)
		if not plan then return nil end

		a.site = U.vector_copy(site)
		a.plan = plan
		a.index = 1
		a.placed = 0
		a.skipped = 0
		a.phase = "go"
		a.timer = 0
		a.title = W.build_kind_goal(kind)
		-- Строитель стоит в центре: стены вырастут вокруг, а дверь останется проходом.
		a.goal_pos = U.vector_copy(site)
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime
		local pos = entity.object:get_pos()

		if a.phase == "go" then
			-- Приходим именно в центр. Слишком широкий радиус прибытия
			-- раньше позволял остановиться на месте будущей стены.
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 0.75)
			if result == "arrived" then
				local at_center = pos and U.horizontal_distance(pos, a.site) <= 0.9
					and math.abs(pos.y - a.site.y) <= 0.9
				if at_center then
					a.phase = "build"
					a.timer = 0
				else
					a.arrive_tries = (a.arrive_tries or 0) + 1
					entity._path = nil
					if a.arrive_tries > 12 then return "fail" end
				end
			elseif result == "blocked" then
				-- Не строим издалека: иначе можно случайно замуровать себя.
				return "fail"
			elseif a.timer > 35 then
				return "fail"
			end
			return "running"
		end

		if a.phase == "build" then
			-- Перед первой установкой ещё раз убеждаемся, что стоим в центре.
			if not pos or U.horizontal_distance(pos, a.site) > 1.15
				or math.abs(pos.y - a.site.y) > 1.15 then
				a.phase = "go"
				a.timer = 0
				a.goal_pos = U.vector_copy(a.site)
				return "running"
			end

			idle(entity)
			W.face(entity, a.site)
			W.animate(entity, "mine", 18)
			if a.timer < 0.3 then return "running" end
			a.timer = 0

			local creative = W.is_creative()
			local placed_now = false
			while a.index <= #a.plan and not placed_now do
				local entry = a.plan[a.index]
				a.index = a.index + 1
				if W.is_air(entry.pos) and not W.node_occupied(entry.pos, entity) then
					if W.is_protected(entry.pos, brain) then return "fail" end
					local resource = W.resource_for_node(entry.node)
					if not creative then
						if (brain.carry[resource] or 0) < 1 then return "fail" end
						pay_for(brain, resource)
					end
					minetest.set_node(entry.pos, { name = entry.node })
					a.placed = (a.placed or 0) + 1
					placed_now = true
					W.particles(entry.pos, node_particle(entry.node), 3, 0.3, 0.5)
					if a.placed % 4 == 0 then
						W.sound(entry.pos, "default_place_node_hard", 0.4)
					end
					-- На всякий случай выбираемся, если блок всё же оказался
					-- на месте жителя (например, из-за чужой постройки).
					W.escape_solid(entity, a.site)
				else
					a.skipped = (a.skipped or 0) + 1
				end
			end

			if a.index > #a.plan then
				if (a.placed or 0) == 0 then return "fail" end
				W.escape_solid(entity, a.site)
				local done_title, say = W.build_kind_done(a.build_kind)
				B.finish_build(brain, now, a.site, done_title, a.build_kind)
				W.say(entity, say)
				return "done"
			end
			return "running"
		end

		return "fail"
	end,
}

ACTIONS.dig = {
	start = function(entity, brain, a, now, ctx)
		local target = a.target_pos
		if not target or not W.is_diggable_name(W.node_at(target).name)
			or not W.is_air({ x = target.x, y = target.y + 1, z = target.z })
			or W.node_occupied(target, entity) or W.is_protected(target, brain) then
			target = W.find_dig_pos((ctx and ctx.pos) or brain.knowledge.home, 14, brain, entity)
		end
		if not target then return nil end
		local approach = W.approach_pos(target, 2)
		if not approach then
			approach = W.free_standing_pos({ x = target.x + 1, y = target.y, z = target.z }, 2)
		end
		if not approach then return nil end
		a.dig_pos = U.vector_copy(target)
		a.goal_pos = approach
		a.phase = "go"
		a.timer = 0
		a.dug = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime

		if a.phase == "go" then
			if not W.is_diggable_name(W.node_at(a.dig_pos).name) then
				return "fail"
			end
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.5)
			if result == "arrived" or result == "blocked" then
				a.phase = "dig"
				a.timer = 0
			elseif a.timer > 28 then
				return "fail"
			end
			return "running"
		end

		if a.phase == "dig" then
			idle(entity)
			W.face(entity, a.dig_pos)
			W.animate(entity, "mine", 20)
			if a.timer < 0.9 then return "running" end
			a.timer = 0

			local pos = entity.object:get_pos()
			local horizontal = pos and U.horizontal_distance(pos, a.dig_pos) or math.huge
			local vertical = pos and math.abs(pos.y - a.dig_pos.y) or math.huge
			if not pos or horizontal > 3.0 or vertical > 2.8 then
				local approach = W.approach_pos(a.dig_pos, 2)
				if approach then
					a.goal_pos = approach
					a.phase = "go"
					return "running"
				end
				return "fail"
			end
			if not W.is_diggable_name(W.node_at(a.dig_pos).name) then return "fail" end
			if W.node_occupied(a.dig_pos, entity) then return "fail" end
			if W.is_protected(a.dig_pos, brain) then return "fail" end

			local name = W.node_at(a.dig_pos).name
			W.particles(a.dig_pos, node_particle(name), 6, 0.35, 0.8)
			W.sound(a.dig_pos, "default_dig_cracky", 0.45)
			minetest.remove_node(a.dig_pos)
			a.dug = (a.dug or 0) + 1
			B.add_stone(brain, 1, now)
			N.add(brain, "energy", -2)
			N.add(brain, "fun", 1)
			W.say(entity, "Набрал(а) камня. Пригодится для дела.")
			return "done"
		end

		return "fail"
	end,
}

ACTIONS.craft = {
	start = function(entity, brain, a, now, ctx)
		local recipe = W.craft_recipe(brain)
		if not recipe then return nil end
		a.recipe = recipe
		a.phase = "craft"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime
		idle(entity)
		W.animate(entity, "mine", 16)
		if a.timer < 1.8 then return "running" end

		local recipe = a.recipe or {}
		if not W.is_creative() then
			if (brain.carry.wood or 0) < (recipe.wood or 0)
				or (brain.carry.stone or 0) < (recipe.stone or 0) then
				return "fail"
			end
			brain.carry.wood = (brain.carry.wood or 0) - (recipe.wood or 0)
			brain.carry.stone = (brain.carry.stone or 0) - (recipe.stone or 0)
		end

		local placed = false
		if recipe.node then
			local home = brain.knowledge and brain.knowledge.home
			local pos = entity.object:get_pos()
			placed = W.place_torch(home or pos, brain, entity)
		end
		B.craft(brain, recipe.label or recipe.title, now, placed)
		if placed then
			W.say(entity, recipe.say or "Готово. Смастерил(а) полезную вещь.")
		else
			W.say(entity, "Смастерил(а) " .. tostring(recipe.title or "вещь") .. ", но места для неё пока нет.")
		end
		return "done"
	end,
}

ACTIONS.visit = {
	start = function(entity, brain, a, now, ctx)
		local spot = a.target_pos
		if spot then
			a.goal_pos = { x = spot.x, y = spot.y, z = spot.z }
			a.phase = "go"
			a.timer = 0
			return a
		end
		local known = B.knowledge_best(brain)
		if not known then return nil end
		a.goal_pos = { x = known.pos.x, y = known.pos.y, z = known.pos.z }
		a.phase = "go"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime
		if a.phase == "go" then
			local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED, 1.8)
			if result == "arrived" or result == "blocked" then
				a.phase = "remember"
				a.timer = 0
			end
			if a.timer > 45 then return "fail" end
			return "running"
		end

		if a.phase == "remember" then
			idle(entity)
			a.timer = (a.timer or 0) + dtime
			if a.timer > 4 then
				N.add(brain, "comfort", 10)
				N.add(brain, "fun", 8)
				M.place(brain, "Навестил(а) знакомое место", now, a.goal_pos, 8)
				return "done"
			end
			return "running"
		end

		return "fail"
	end,
}

ACTIONS.wander = {
	start = function(entity, brain, a, now, ctx)
		local base = brain.knowledge.home or ctx.pos
		local spot = W.random_walkable_near(base, 10, function(lo, hi) return U.rand_int(brain, lo, hi) end)
		if not spot then return nil end
		a.goal_pos = spot
		a.phase = "go"
		a.timer = 0
		return a
	end,

	update = function(entity, brain, a, dtime, now, ctx)
		a.timer = (a.timer or 0) + dtime
		local result = move_to(entity, a, a.goal_pos, dtime, WALK_SPEED * 0.9, 1.4)
		if result == "arrived" or result == "blocked" or a.timer > 20 then
			return "done"
		end
		return "running"
	end,
}

-- ===========================================================================
-- УПРАВЛЕНИЕ
-- ===========================================================================
local function stop_action(entity, brain, a, success)
	if a and a.stop then a.stop(entity, brain, a, success) end
	entity._action = nil
	entity._anim = nil
	W.stop(entity)
	if entity.object then
		W.animate(entity, "stand")
	end
end

local function end_action(entity, brain, a, success, now)
	stop_action(entity, brain, a, success)
	local finished = B.complete_goal(brain, now, success)
	if finished and smart_npc.call_hook then
		smart_npc.call_hook("goal", entity, brain, finished, success)
	end
	-- Не оставляем жителя без дела до следующего тика мозга: пусть гуляет.
	if entity.object and not brain.goal and not brain.paused then
		B.set_custom_goal(brain, "wander", "Погулять", now)
	end
end

local function start_action(entity, brain, goal, now, ctx)
	local def = ACTIONS[goal.action]
	if not def or not def.start then return nil end
	local a = {
		kind = goal.action,
		desire_id = goal.desire_id,
		title = goal.title,
		target = goal.target,
		target_pos = goal.target_pos,
		fear = goal.fear,
		story = goal.story,
		build_kind = goal.build_kind,
		started = now,
	}
	local result = def.start(entity, brain, a, now, ctx)
	if result == nil then return nil end
	return a
end

function A.tick(entity, dtime)
	local brain = entity._brain
	if not brain then return end
	if not entity.object or not entity.object:get_pos() then return end

	if brain.paused then
		idle(entity)
		if entity._action then stop_action(entity, brain, entity._action, false) end
		return
	end

	local now = W.now()
	local goal = brain.goal
	local a = entity._action

	if not goal then
		if a then stop_action(entity, brain, a, false) end
		idle(entity)
		return
	end

	if a and (a.desire_id ~= goal.desire_id or a.kind ~= goal.action) then
		stop_action(entity, brain, a, false)
		a = nil
	end

	local ctx = brain.last_context
	if not ctx then
		ctx = W.scan(entity, brain, now)
	end

	if not a then
		a = start_action(entity, brain, goal, now, ctx)
		entity._action = a
		if not a then
			B.complete_goal(brain, now, false)
			idle(entity)
			return
		end
	end

	local def = ACTIONS[a.kind]
	if not def or not def.update then
		stop_action(entity, brain, a, false)
		B.complete_goal(brain, now, false)
		return
	end

	local status = def.update(entity, brain, a, dtime, now, ctx)
	if status == "done" then
		end_action(entity, brain, a, true, now)
	elseif status == "fail" then
		end_action(entity, brain, a, false, now)
	elseif (now - a.started) > 120 then
		end_action(entity, brain, a, false, now)
	end
end

function A.stop(entity)
	local brain = entity._brain
	if entity._action then
		stop_action(entity, brain, entity._action, false)
	end
end

function A.describe(entity)
	local a = entity._action
	if not a then return "Ничем не занят(а)" end
	return smart_npc.desires.action_title(a.kind)
end
