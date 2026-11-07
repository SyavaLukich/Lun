-- Умные NPC: жители с характером, потребностями, памятью и желаниями.
-- Идея: потребности и «желания» из The Sims + эпизодическая память,
-- мысли и отношения из Dwarf Fortress.

smart_npc = {}
smart_npc.version = "1.0.0"
smart_npc.path = minetest.get_modpath("smart_npc")
smart_npc.active = {}
smart_npc.settings = {}
smart_npc.hooks = { spawn = {}, gift = {}, conversation = {}, attack = {}, goal = {} }
smart_npc.next_id = 0

local settings = minetest.settings
local function get_raw(key)
	return settings and settings:get(key)
end

local function get_bool(key, default)
	local raw = get_raw("smart_npc." .. key)
	if raw == nil then return default end
	raw = tostring(raw):lower()
	return raw == "true" or raw == "1" or raw == "yes"
end

local function get_number(key, default)
	local raw = tonumber(get_raw("smart_npc." .. key))
	if raw == nil then return default end
	return raw
end

smart_npc.settings = {
	autospawn = get_bool("autospawn", true),
	spawn_count = math.max(1, math.floor(get_number("spawn_count", 2))),
	max_npcs = math.max(1, math.floor(get_number("max_npcs", 40))),
	need_decay_scale = math.max(0.1, get_number("need_decay_scale", 1.0)),
	gift_cooldown = math.max(0, get_number("gift_cooldown", 2.0)),
	chat_lines = get_bool("chat_lines", true),
	auto_reply = get_bool("auto_reply", true),
	debug = get_bool("debug", false),
}

local path = smart_npc.path
dofile(path .. "/core/util.lua")
dofile(path .. "/core/personality.lua")
dofile(path .. "/core/names.lua")
dofile(path .. "/core/needs.lua")
dofile(path .. "/core/memory.lua")
dofile(path .. "/core/desires.lua")
dofile(path .. "/core/brain.lua")
dofile(path .. "/core/dialogue.lua")
dofile(path .. "/world.lua")
dofile(path .. "/actions.lua")
dofile(path .. "/ui.lua")

local U = smart_npc.util
local B = smart_npc.brain
local N = smart_npc.needs
local M = smart_npc.memory
local D = smart_npc.desires
local T = smart_npc.dialogue
local W = smart_npc.world
local A = smart_npc.actions
local UI = smart_npc.ui

local SKIN_COUNT = 10

local function log(...)
	if not smart_npc.settings.debug then return end
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	minetest.log("action", "[smart_npc] " .. table.concat(parts, " "))
end

local function skin_texture(index)
	index = math.floor(tonumber(index) or 1)
	index = ((index - 1) % SKIN_COUNT) + 1
	return "npc_skin_" .. tostring(index) .. ".png"
end

-- ===========================================================================
-- Классификация предметов и блоков
-- ===========================================================================
local FOOD_GROUPS = {
	"food", "food_apple", "food_berry", "food_bread", "food_meat",
	"food_fish", "food_vegetable", "food_soup", "food_mushroom", "eatable",
}

local function has_food_group(def)
	if not def or not def.groups then return false end
	for _, group in ipairs(FOOD_GROUPS) do
		if def.groups[group] and def.groups[group] ~= 0 then return true end
	end
	return false
end

function smart_npc.is_food_node(name)
	local def = minetest.registered_nodes[name]
	return has_food_group(def)
end

function smart_npc.is_food_item(itemstring)
	if not itemstring or itemstring == "" then return false end
	local name = itemstring:match("^([^%s]+)") or itemstring
	local def = minetest.registered_items[name]
	if has_food_group(def) then return true end
	return smart_npc.is_food_node(name)
end

function smart_npc.item_label(itemstring)
	local name = (itemstring or ""):match("^([^%s]+)") or itemstring or ""
	local def = minetest.registered_items[name]
	if def and def.description and def.description ~= "" then return def.description end
	def = minetest.registered_nodes[name]
	if def and def.description and def.description ~= "" then return def.description end
	return name
end

-- Списки блоков собираем после загрузки всех модов.
minetest.register_on_mods_loaded(function()
	smart_npc.food_nodes = {}
	smart_npc.water_nodes = {}
	smart_npc.interesting_nodes = {}

	for name, def in pairs(minetest.registered_nodes) do
		local groups = def.groups or {}
		if has_food_group(def) then
			smart_npc.food_nodes[#smart_npc.food_nodes + 1] = name
		end
		if groups.water and groups.liquid then
			smart_npc.water_nodes[#smart_npc.water_nodes + 1] = name
		end
		if groups.tree or groups.wood or groups.torch or groups.water or groups.stone then
			smart_npc.interesting_nodes[#smart_npc.interesting_nodes + 1] = name
		end
	end

	table.sort(smart_npc.food_nodes)
	table.sort(smart_npc.water_nodes)
	table.sort(smart_npc.interesting_nodes)
	while #smart_npc.interesting_nodes > 80 do table.remove(smart_npc.interesting_nodes) end
	if #smart_npc.food_nodes == 0 and minetest.registered_nodes["default:apple"] then
		smart_npc.food_nodes = { "default:apple" }
	end
	if #smart_npc.water_nodes == 0 and minetest.registered_nodes["default:water_source"] then
		smart_npc.water_nodes = { "default:water_source", "default:water_flowing" }
	end
	if #smart_npc.interesting_nodes == 0 then
		smart_npc.interesting_nodes = { "default:stone", "default:tree", "default:torch" }
	end
	log("блоки:", #smart_npc.food_nodes, "еда,", #smart_npc.water_nodes, "вода,",
		#smart_npc.interesting_nodes, "интересные")
end)

-- ===========================================================================
-- Создание и настройка жителей
-- ===========================================================================
local function unique_name(base)
	if not base then return nil end
	local used = {}
	for _, entity in pairs(smart_npc.active) do
		if entity._brain then used[entity._brain.name] = true end
	end
	if not used[base] then return base end
	for i = 2, 50 do
		local candidate = base .. " " .. tostring(i)
		if not used[candidate] then return candidate end
	end
	return base
end

function smart_npc.new_brain(pos, opts)
	if type(opts) ~= "table" then opts = {} end
	smart_npc.next_id = (smart_npc.next_id or 0) + 1
	local id = opts.id or string.format("npc_%d_%d", math.floor(minetest.get_us_time() / 1000), smart_npc.next_id)
	local brain = B.create({
		id = id,
		now = W.now(),
		pos = pos,
		seed = opts.seed or math.random(1, 2147483646),
		name = opts.name,
		full_name = opts.full_name,
		gender = opts.gender,
		age = opts.age,
		skin = opts.skin,
		needs_scale = opts.needs_scale or smart_npc.settings.need_decay_scale,
	})
	if not opts.full_name then
		brain.name = unique_name(brain.name)
	end
	return brain
end

function smart_npc.apply_identity(entity, brain)
	brain = brain or entity._brain
	if not brain then return end
	local infotext = string.format("%s · %s · %s", brain.name,
		brain.personality.occupation or "житель", brain.mood_label or "ровно")
	entity.object:set_properties({
		textures = { skin_texture(brain.skin), "npc_blank.png", "npc_blank.png" },
		infotext = infotext,
	})
	entity._infotext_at = W.now()
end

function smart_npc.setup(entity, brain)
	if not entity or not entity.object then return end
	brain = B.migrate(brain or entity._brain)
	if not brain then return end
	if not brain.id then
		smart_npc.next_id = (smart_npc.next_id or 0) + 1
		brain.id = string.format("npc_%d_%d", math.floor(minetest.get_us_time() / 1000), smart_npc.next_id)
	end
	-- Загруженная копия не должна вытеснить уже активного жителя с тем же id.
	local active = smart_npc.active[brain.id]
	if active and active ~= entity then
		local candidate
		repeat
			smart_npc.next_id = (smart_npc.next_id or 0) + 1
			candidate = string.format("npc_%d_%d", math.floor(minetest.get_us_time() / 1000), smart_npc.next_id)
		until not smart_npc.active[candidate]
		log("повтор id", brain.id, "заменён на", candidate)
		brain.id = candidate
	end
	entity._brain = brain
	entity._action = nil
	entity._anim = nil
	entity._step_timer = 0
	entity._last_brain = W.now()
	entity._next_brain = 0
	entity._last_say = 0
	entity._last_ambient = W.now()
	entity._next_ambient = W.now() + U.rand_int(brain, 40, 90)

	entity.object:set_armor_groups({ immortal = 1 })
	smart_npc.apply_identity(entity, brain)
	W.animate(entity, "stand")
	smart_npc.active[brain.id] = entity
	smart_npc.call_hook("spawn", entity, brain)
	log("появился", brain.name, brain.id)
	return brain
end

function smart_npc.spawn(pos, opts)
	if type(opts) ~= "table" then opts = {} end
	if opts.brain ~= nil and type(opts.brain) ~= "table" then opts.brain = nil end
	if U.count(smart_npc.active) >= smart_npc.settings.max_npcs then
		return nil, "max_npcs"
	end
	local px, py, pz = type(pos) == "table" and tonumber(pos.x), type(pos) == "table" and tonumber(pos.y), type(pos) == "table" and tonumber(pos.z)
	if not px or not py or not pz or px ~= px or py ~= py or pz ~= pz then
		return nil, "no_pos"
	end
	if opts.brain and opts.brain.id and smart_npc.active[opts.brain.id] then
		return nil, "duplicate_id"
	end
	local spawn_pos = W.find_spawn_pos(pos)
	if not W.has_ground_below(spawn_pos, 12) then
		return nil, "no_ground"
	end
	local payload
	if opts.brain then
		payload = { brain = opts.brain }
	else
		payload = { spawn_opts = opts }
	end
	local object = minetest.add_entity(spawn_pos, "smart_npc:npc", minetest.serialize(payload))
	if not object then return nil, "add_entity_failed" end
	local entity = object:get_luaentity()
	if not entity then return nil, "no_luaentity" end
	return entity
end

function smart_npc.remove(entity)
	if not entity or not entity.object then return end
	if entity._brain then smart_npc.active[entity._brain.id] = nil end
	entity.object:remove()
end

function smart_npc.count()
	return U.count(smart_npc.active)
end

function smart_npc.nearest(pos, radius)
	if type(pos) ~= "table" then return nil end
	local best, best_distance
	for _, entity in pairs(smart_npc.active) do
		if entity.object and entity._brain then
			local epos = entity.object:get_pos()
			if epos then
				local distance = U.distance(pos, epos)
				if distance <= (radius or 8) and (not best_distance or distance < best_distance) then
					best, best_distance = entity, distance
				end
			end
		end
	end
	return best, best_distance
end

function smart_npc.by_name(name)
	if type(name) ~= "string" then return nil end
	name = name:lower()
	for _, entity in pairs(smart_npc.active) do
		if entity._brain and (entity._brain.name:lower() == name
			or (entity._brain.full_name or ""):lower() == name) then
			return entity
		end
	end
	return nil
end

function smart_npc.get_brain(value)
	if type(value) == "table" then return value._brain end
	if type(value) == "string" then
		local entity = smart_npc.active[value]
		return entity and entity._brain or nil
	end
	return nil
end

function smart_npc.get_mood(entity)
	local brain = smart_npc.get_brain(entity)
	return brain and brain.mood or nil, brain and brain.mood_label or nil
end

function smart_npc.set_need(entity, need, value)
	local brain = smart_npc.get_brain(entity)
	if brain and N.defs[need] then
		N.set(brain, need, value)
		return true
	end
	return false
end

function smart_npc.remember(entity, event)
	local brain = smart_npc.get_brain(entity)
	if not brain then return nil end
	return M.add(brain, event, W.now())
end

function smart_npc.register_hook(event, func)
	if not smart_npc.hooks[event] or type(func) ~= "function" then return false end
	table.insert(smart_npc.hooks[event], func)
	return true
end

function smart_npc.call_hook(event, ...)
	local hooks = smart_npc.hooks[event]
	if not hooks then return end
	for _, func in ipairs(hooks) do
		local ok, err = pcall(func, ...)
		if not ok then
			minetest.log("error", "[smart_npc] hook " .. event .. ": " .. tostring(err))
		end
	end
end

-- Угощение едой: используется и правым кликом, и кнопкой в панели.
function smart_npc.give_food(player, entity, itemstack)
	if not player or not entity or not entity._brain then return "Не получилось.", false end
	local now = W.now()
	local brain = entity._brain
	local stack = itemstack or player:get_wielded_item()
	if not stack or stack:is_empty() or not smart_npc.is_food_item(stack:get_name()) then
		return "Возьмите еду в руку (яблоко, ягоды) и попробуйте снова.", false
	end
	if entity._last_gift and now - entity._last_gift < smart_npc.settings.gift_cooldown then
		return "Дайте жителю пару секунд — он ещё благодарит вас за прошлый подарок.", false
	end
	entity._last_gift = now
	local player_name = player:get_player_name()
	local item_name = stack:get_name()
	local label = smart_npc.item_label(item_name)

	if not minetest.is_creative_enabled(player_name) then
		stack:take_item(1)
		player:set_wielded_item(stack)
	end

	B.receive_gift(brain, "player:" .. player_name, player_name, label, now)
	N.add(brain, "hunger", 4)
	W.say(entity, T.gift_response(brain, player_name, label), true)
	W.particles(entity.object:get_pos(), "npc_heart.png", 5, 0.5, 1.9)
	if entity.object:get_pos() then
		W.sound(entity.object:get_pos(), "default_item_smoke", 0.4)
	end
	smart_npc.call_hook("gift", entity, brain, player, item_name)
	return string.format("Вы дали %s. %s бережно убрал(а) еду и благодарит вас.", label, brain.name), true
end

-- ===========================================================================
-- Сущность
-- ===========================================================================
minetest.register_entity("smart_npc:npc", {
	initial_properties = {
		physical = true,
		collide_with_objects = false,
		collisionbox = { -0.32, 0.0, -0.32, 0.32, 1.78, 0.32 },
		visual = "mesh",
		mesh = "npc.b3d",
		textures = { "npc_skin_1.png", "npc_blank.png", "npc_blank.png" },
		visual_size = { x = 1, y = 1 },
		stepheight = 0.6,
		make_footstep_sound = false,
		hp_max = 100,
		breath_max = 10,
		pointable = true,
		static_save = true,
		infotext = "Житель",
	},

	on_activate = function(self, staticdata, dtime_s)
		self._step_timer = 0
		self._next_brain = 0
		self._action = nil
		self._anim = nil

		local brain
		if staticdata and staticdata ~= "" then
			local ok, data = pcall(minetest.deserialize, staticdata)
			if ok and type(data) == "table" then
				if data.brain then
					brain = B.migrate(data.brain)
				elseif type(data.spawn_opts) == "table" then
					brain = smart_npc.new_brain(self.object:get_pos(), data.spawn_opts)
				end
			end
		end
		if not brain then
			brain = smart_npc.new_brain(self.object:get_pos(), {})
		end
		self._brain = brain
		smart_npc.setup(self, brain)
	end,

	on_deactivate = function(self, removal)
		local brain = self._brain
		if brain and smart_npc.active[brain.id] == self then
			smart_npc.active[brain.id] = nil
		end
		self._action = nil
	end,

	get_staticdata = function(self)
		if not self._brain then return "" end
		-- Временные данные восприятия не сохраняем: они устареют к загрузке.
		local brain = self._brain
		local last_context, cache, now = brain.last_context, brain.cache, brain.now
		brain.last_context, brain.cache, brain.now = nil, nil, nil
		local ok, data = pcall(minetest.serialize, { brain = brain })
		brain.last_context, brain.cache, brain.now = last_context, cache, now
		if not ok then
			minetest.log("error", "[smart_npc] не удалось сохранить жителя: " .. tostring(data))
			return ""
		end
		return data
	end,

	on_step = function(self, dtime)
		if not self._brain or not self.object then return end
		local brain = self._brain
		local now = W.now()

		-- Спасение из пустоты: в творческом мире легко свалиться с платформы.
		if now - (self._rescue_at or 0) > 2 then
			self._rescue_at = now
			local pos = self.object:get_pos()
			if pos and (pos.y < -30 or (brain.knowledge.home and pos.y < brain.knowledge.home.y - 60)) then
				local target = brain.knowledge.home
				if not target or target.y < -20 then
					local player = minetest.get_connected_players()[1]
					target = player and player:get_pos()
				end
				if target then
					W.teleport_near(self, target)
					M.add(brain, {
						kind = "fall",
						text = "Чуть не упал(а) в пустоту",
						valence = -18,
						importance = 5,
					}, now)
				else
					self.object:set_pos({ x = 0, y = 10, z = 0 })
				end
			end
		end

		if brain.paused then
			A.tick(self, dtime)
			return
		end

		self._step_timer = (self._step_timer or 0) + dtime
		if self._step_timer < 0.2 then return end
		local step_dt = math.min(self._step_timer, 2)
		self._step_timer = 0

		if now >= (self._next_brain or 0) then
			local dt = math.min(now - (self._last_brain or now), 10)
			local ctx = W.scan(self, brain, now)
			ctx.now = now
			ctx.dt = dt
			B.tick(brain, ctx)
			self._last_brain = now
			self._next_brain = now + 1.2 + (U.hash(brain.id) % 8) * 0.1

			if now - (self._infotext_at or 0) > 10 then
				smart_npc.apply_identity(self, brain)
			end

			-- Редкая «болтовня вслух» о самочувствии: не чаще раза в минуту.
			if now >= (self._next_ambient or 0) then
				self._next_ambient = now + U.rand_int(brain, 55, 120)
				self._last_ambient = now
				if smart_npc.settings.chat_lines and not (brain.goal and brain.goal.action == "tantrum")
					and U.rand_int(brain, 1, 100) <= 70 then
					W.say(self, T.ambient(brain, now))
				end
			end
		end

		A.tick(self, step_dt)
	end,

	on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
		if not puncher or not puncher:is_player() or not self._brain then return end
		local player_name = puncher:get_player_name()
		local now = W.now()
		B.attacked_by(self._brain, "player:" .. player_name, player_name, now, damage or 1)
		W.say(self, T.attack_response(self._brain, player_name), true)
		local pos = self.object:get_pos()
		if pos then
			W.particles(pos, "npc_anger.png", 8, 0.5, 1.9)
			W.sound(pos, "player_damage", 0.5)
		end
		self.object:set_hp(100)
		smart_npc.call_hook("attack", self, self._brain, puncher, damage)
	end,

	on_rightclick = function(self, clicker)
		if not clicker or not clicker:is_player() or not self._brain then return end
		local stack = clicker:get_wielded_item()
		if stack and not stack:is_empty() and smart_npc.is_food_item(stack:get_name()) then
			local message, ok = smart_npc.give_food(clicker, self, stack)
			if not ok then
				minetest.chat_send_player(clicker:get_player_name(), minetest.colorize("#e08b6a", message))
			end
			return true
		end
		UI.show(clicker, self, 1, "")
		return nil
	end,

	on_death = function(self, killer)
		local brain = self._brain
		if brain then
			smart_npc.active[brain.id] = nil
		end
		self.object:remove()
	end,
})

local function spawn_error_text(err)
	if err == "max_npcs" then return "Достигнут предел числа жителей." end
	if err == "no_ground" then return "Под этим местом нет твёрдой земли." end
	if err == "no_pos" then return "Не указано место для жителя." end
	if err == "duplicate_id" then return "Житель с таким идентификатором уже существует." end
	return "Не удалось создать жителя: " .. tostring(err)
end

-- ===========================================================================
-- Предмет-призыватель
-- ===========================================================================
minetest.register_craftitem("smart_npc:spawner", {
	description = "Призвать умного жителя\nПоставьте рядом: у него будет характер, память и желания.",
	inventory_image = "npc_spawner.png",
	stack_max = 1,
	on_use = function(itemstack, user, pointed_thing)
		if not user or not user:is_player() then return itemstack end
		local pos
		if pointed_thing and pointed_thing.type == "node" and pointed_thing.above then
			pos = pointed_thing.above
		else
			local base = user:get_pos()
			local dir = user:get_look_dir()
			pos = { x = base.x + dir.x * 2, y = base.y, z = base.z + dir.z * 2 }
		end
		local entity, err = smart_npc.spawn(pos, {})
		if not entity then
			minetest.chat_send_player(user:get_player_name(),
				minetest.colorize("#e08b6a", spawn_error_text(err)))
			return itemstack
		end
		local brain = entity._brain
		minetest.chat_send_player(user:get_player_name(), minetest.colorize("#9fd3ff",
			string.format("Появился %s — %s. Нажмите правой кнопкой без еды в руке, чтобы поговорить.",
				brain.full_name, brain.personality.occupation)))
		return itemstack
	end,
})

if minetest.registered_items["default:apple"] and minetest.registered_items["default:stone"]
	and minetest.registered_items["default:torch"] then
	minetest.register_craft({
		output = "smart_npc:spawner",
		recipe = {
			{ "default:apple", "default:torch", "default:apple" },
			{ "default:stone", "default:stone", "default:stone" },
		},
	})
end

-- ===========================================================================
-- Чат и взаимодействие
-- ===========================================================================
function smart_npc.nearest_to_player(player, radius)
	local pos = player:get_pos()
	return smart_npc.nearest(pos, radius or 8)
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	UI.handle_fields(player, formname, fields)
end)

minetest.register_on_leaveplayer(function(player)
	UI.forget(player:get_player_name())
end)

minetest.register_on_chat_message(function(player_name, message)
	if not smart_npc.settings.auto_reply then return end
	local player = minetest.get_player_by_name(player_name)
	if not player then return end
	local entity = smart_npc.nearest_to_player(player, 14)
	if not entity or not entity._brain then return end

	local now = W.now()
	local reply = T.chat_reply(entity._brain, player_name, message, now)
	if not reply or not reply.text then return end

	if reply.insult then
		B.insulted_by(entity._brain, "player:" .. player_name, player_name, now)
	elseif reply.follow then
		D.add(entity._brain, {
			id = "reaction:follow:" .. player_name,
			action = "follow",
			title = "Идти за " .. player_name,
			line = "Меня позвали",
			target = "player:" .. player_name,
			utility = 85,
			ttl = 120,
		}, now)
		-- Просьба выполняется сразу, не дожидаясь выбора желания.
		B.set_custom_goal(entity._brain, "follow", "Идти за " .. player_name, now,
			{ target = "player:" .. player_name })
	elseif reply.stay then
		for i = #entity._brain.desires, 1, -1 do
			if entity._brain.desires[i].action == "follow" then
				table.remove(entity._brain.desires, i)
			end
		end
		entity._brain.flags.following = nil
		entity._brain.goal = nil
	else
		B.converse(entity._brain, "player:" .. player_name, player_name, now, reply.topic, { gain = 8 })
	end

	W.say(entity, reply.text, true)
	smart_npc.call_hook("conversation", entity, entity._brain, player, message, reply)
end)

-- ===========================================================================
-- Автопоявление и команды
-- ===========================================================================
minetest.register_on_joinplayer(function(player)
	if not smart_npc.settings.autospawn then return end
	local player_name = player:get_player_name()
	minetest.after(3, function()
		local current = minetest.get_player_by_name(player_name)
		if not current then return end
		if smart_npc.count() > 0 then return end
		local base = current:get_pos()
		if not base then return end
		-- Без твёрдой земли под игроком жители будут падать в пустоту.
		local has_ground = false
		for dy = 1, 12 do
			local node = minetest.get_node({ x = math.floor(base.x), y = math.floor(base.y) - dy, z = math.floor(base.z) })
			local def_node = minetest.registered_nodes[node.name]
			if def_node and def_node.walkable then
				has_ground = true
				break
			end
		end
		if not has_ground then return end
		for i = 1, smart_npc.settings.spawn_count do
			local angle = (i / smart_npc.settings.spawn_count) * math.pi * 2
			local pos = {
				x = base.x + math.cos(angle) * 2.5,
				y = base.y,
				z = base.z + math.sin(angle) * 2.5,
			}
			smart_npc.spawn(pos, {})
		end
		minetest.chat_send_player(player_name, minetest.colorize("#9fd3ff",
			"Рядом поселились жители. Правый клик по ним открывает панель, еда в руке — угощение. " ..
			"Команда /npc поможет управлять."))
	end)
end)

local function require_server(name)
	local privs = minetest.get_player_privs(name)
	if not privs or not privs.server then
		return false, "Нужно право server."
	end
	return true
end

minetest.register_chatcommand("npc", {
	params = "spawn [имя] | list | info | panel | feed | home | calm | freeze | remove",
	description = "Управление умными жителями",
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then return false, "Игрок не найден." end
		local args = U.split(param or "", "%s")
		local action = args[1] or "info"
		local pos = player:get_pos()
		local now = W.now()

		if action == "spawn" then
			if not pos then return false, "Не удалось определить позицию игрока." end
			local wanted
			if #args >= 2 then
				local parts = {}
				for i = 2, #args do parts[#parts + 1] = args[i] end
				wanted = table.concat(parts, " ")
			end
			local dir = player:get_look_dir()
			local target = { x = pos.x + dir.x * 2, y = pos.y, z = pos.z + dir.z * 2 }
			local entity, err = smart_npc.spawn(target, { name = wanted })
			if not entity then
				return false, spawn_error_text(err)
			end
			local brain = entity._brain
			return true, string.format("Появился %s — %s. Настроение: %s.",
				brain.full_name, brain.personality.occupation, brain.mood_label)
		end

		if action == "list" then
			local lines = {}
			for _, entity in pairs(smart_npc.active) do
				local brain = entity._brain
				if brain then
					lines[#lines + 1] = string.format("%s — %s · %s · %s",
						brain.name, brain.personality.occupation or "житель",
						brain.mood_label or "ровно", brain.goal and brain.goal.title or "без дела")
				end
			end
			if #lines == 0 then return true, "Жителей пока нет. /npc spawn" end
			table.sort(lines)
			return true, table.concat(lines, "\n")
		end

		if action == "panel" then
			local entity = smart_npc.nearest(pos, 10)
			if not entity then return false, "Рядом никого нет." end
			UI.show(player, entity, 1, "")
			return true
		end

		if action == "feed" then
			local entity = smart_npc.nearest(pos, 10)
			if not entity then return false, "Рядом никого нет." end
			local stack = player:get_wielded_item()
			if stack and not stack:is_empty() and smart_npc.is_food_item(stack:get_name()) then
				local message, ok = smart_npc.give_food(player, entity, stack)
				return ok, message
			end
			local brain = entity._brain
			B.receive_gift(brain, "player:" .. name, name, "еду", now)
			brain.carry.food = math.max(0, (brain.carry.food or 0) - 1)
			B.eat(brain, "еду от " .. name, now, 45)
			W.say(entity, T.thanks(brain, name), true)
			return true, brain.name .. " благодарит вас за еду."
		end

		if action == "home" then
			local entity = smart_npc.nearest(pos, 10)
			if not entity then return false, "Рядом никого нет." end
			B.set_home(entity._brain, pos)
			return true, entity._brain.name .. " запомнил(а) это место как дом."
		end

		if action == "remove" then
			local ok, err = require_server(name)
			if not ok then return false, err end
			local entity = smart_npc.nearest(pos, 8)
			if not entity then return false, "Рядом никого нет." end
			local who = entity._brain and entity._brain.name or "житель"
			smart_npc.remove(entity)
			return true, who .. " исчез(ла)."
		end

		if action == "calm" then
			local ok, err = require_server(name)
			if not ok then return false, err end
			local entity = smart_npc.nearest(pos, 10)
			if not entity then return false, "Рядом никого нет." end
			local brain = entity._brain
			brain.stress = 0
			brain.mood = 75
			for _, need in ipairs(N.order) do
				N.set(brain, need, 85)
			end
			B.update_mood(brain, now)
			return true, brain.name .. " успокоен(а)."
		end

		if action == "freeze" then
			local ok, err = require_server(name)
			if not ok then return false, err end
			local entity = smart_npc.nearest(pos, 10)
			if not entity then return false, "Рядом никого нет." end
			entity._brain.paused = not entity._brain.paused
			return true, entity._brain.name .. (entity._brain.paused and " замер(ла)." or " снова живёт.")
		end

		if action == "info" or action == "help" then
			local entity = smart_npc.nearest(pos, 8)
			if not entity then
				return true, "Умные жители: /npc spawn · /npc list · /npc panel · /npc feed · /npc home · " ..
					"/npc calm · /npc freeze · /npc remove"
			end
			local brain = entity._brain
			local lines = {
				B.describe(brain),
				"Занятие: " .. A.describe(entity) .. " · желание: " .. (brain.goal and brain.goal.title or "нет"),
			}
			local thoughts = M.thoughts(brain, now, 3)
			for _, thought in ipairs(thoughts) do
				lines[#lines + 1] = string.format("Мысль (%+d): %s", U.round(thought.value), thought.text)
			end
			local desires = D.top(brain, 2)
			for _, desire in ipairs(desires) do
				lines[#lines + 1] = "Хочет: " .. desire.title
			end
			return true, table.concat(lines, "\n")
		end

		return false, "Неизвестная команда. /npc help"
	end,
})

-- Команда «поговорить с ближайшим» удобна без клика.
minetest.register_chatcommand("npc_talk", {
	params = "",
	description = "Открыть панель ближайшего жителя",
	func = function(name)
		local player = minetest.get_player_by_name(name)
		if not player then return false end
		local entity = smart_npc.nearest(player:get_pos(), 10)
		if not entity then return false, "Рядом никого нет." end
		UI.show(player, entity, 4, "")
		return true
	end,
})

log("мод загружен, версия", smart_npc.version)
