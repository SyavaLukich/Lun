-- Мозг жителя: связывает потребности, память, настроение и желания.
-- Модуль не знает о движке: всё общение с миром приходит через ctx
-- (см. world.lua), поэтому его можно целиком прогонять в тестах.

local B = {}
smart_npc.brain = B
local U = smart_npc.util
local P = smart_npc.personality
local N = smart_npc.needs
local M = smart_npc.memory
local D = smart_npc.desires

B.version = 1

B.critical_text = {
	hunger = "Сильно проголодался(лась)",
	energy = "Совсем без сил",
	social = "Чувствую себя одиноко",
	fun = "Скучно до тоски",
	hygiene = "Чувствую себя грязным(ой)",
	comfort = "Неуютно и зябко",
	safety = "Мне страшно",
}

function B.rand(brain, low, high)
	return U.rand_int(brain, low, high)
end

function B.create(opts)
	if type(opts) ~= "table" then opts = {} end
	local now = tonumber(opts.now) or 0
	local seed = opts.seed or math.random(1, 2000000000)
	local rng = U.new_rng(seed)
	local name = opts.name ~= nil and tostring(opts.name) or nil
	local full_name = opts.full_name ~= nil and tostring(opts.full_name) or nil
	local gender = opts.gender ~= nil and tostring(opts.gender) or nil
	local skin = tonumber(opts.skin)
	if not skin or skin ~= skin then skin = nil else skin = math.max(1, math.min(10, math.floor(skin))) end
	local id = opts.id ~= nil and tostring(opts.id) or nil
	if id == "" then id = nil end

	local age = tonumber(opts.age)
	if age and age == age then
		age = math.max(1, math.min(120, math.floor(age)))
	else
		age = nil
	end
	local needs_scale = tonumber(opts.needs_scale)
	if not needs_scale or needs_scale ~= needs_scale then needs_scale = 1 end
	needs_scale = math.max(0.1, math.min(10, needs_scale))

	local identity = {
		name = name,
		full_name = full_name,
		gender = gender,
		age = age,
	}
	if not identity.name then
		local generated = smart_npc.names.identity(rng)
		identity.name = generated.name
		identity.full_name = identity.full_name or generated.full_name
		identity.gender = identity.gender or generated.gender
		identity.age = identity.age or generated.age
	end
	identity.full_name = identity.full_name or identity.name
	-- Имя можно задать отдельно, но возраст и пол всё равно нужны биографии.
	identity.gender = identity.gender or "male"
	identity.age = identity.age or rng(18, 70)

	local person = P.create(rng)
	local brain = {
		version = B.version,
		id = id or ("npc_" .. tostring(seed) .. "_" .. tostring(rng(1000, 9999))),
		name = identity.name,
		full_name = identity.full_name,
		gender = identity.gender or "male",
		age = identity.age or 30,
		skin = skin or rng(1, 10),
		personality = person,
		needs = N.create(rng, person),
		memory = M.create(),
		desires = {},
		goal = nil,
		activity = "idle",
		mood = 55,
		mood_label = "ровно",
		stress = 0,
		thought_bonus = 0,
		carry = { food = 0, wood = 0, stone = 0, crafted = 0 },
		flags = {},
		paused = false,
		needs_scale = needs_scale,
		rng_seed = seed,
		rng_counter = 0,
		whim_timer = rng(8, 20),
		whim_cooldowns = {},
		knowledge = {
			home = opts.pos and U.vector_copy(opts.pos) or nil,
			spots = {},
		},
		stats = {
			spawned_at = now,
			ticks = 0,
			meals = 0,
			naps = 0,
			chats = 0,
			gifts = 0,
			hurts = 0,
			wood = 0,
			stone = 0,
			builds = 0,
			crafts = 0,
			desires_done = 0,
			desires_attempted = 0,
			tantrums = 0,
			walks = 0,
			distance = 0,
		},
	}
	brain.backstory = opts.backstory or smart_npc.names.backstory(rng, person, identity)
	brain.needs_scale = brain.needs_scale or 1
	B.update_mood(brain, now)
	return brain
end

-- ---------------------------------------------------------------------------
-- Совместимость сохранённых данных
-- ---------------------------------------------------------------------------
function B.migrate(brain)
	if type(brain) ~= "table" then return nil end

	local function table_or(value)
		if type(value) == "table" then return value end
		return {}
	end
	local function number_or(value, fallback)
		local number = tonumber(value)
		if number == nil or number ~= number then return fallback end
		return number
	end
	local function clamp_number(value, low, high, fallback)
		local number = number_or(value, fallback)
		if number < low then return low end
		if number > high then return high end
		return number
	end
	local function pos_or_nil(value)
		if type(value) ~= "table" then return nil end
		local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
		if not x or not y or not z or x ~= x or y ~= y or z ~= z then return nil end
		return { x = x, y = y, z = z }
	end

	brain.version = B.version
	if brain.id ~= nil then
		brain.id = tostring(brain.id)
		if brain.id == "" then brain.id = nil end
	end

	brain.desires = table_or(brain.desires)
	for index = #brain.desires, 1, -1 do
		local desire = brain.desires[index]
		if type(desire) ~= "table" or desire.action == nil or desire.action == "" then
			table.remove(brain.desires, index)
		else
			desire.action = tostring(desire.action)
			desire.title = tostring(desire.title or D.action_title(desire.action))
			desire.utility = number_or(desire.utility, 0)
			desire.id = tostring(desire.id or ("restored:" .. desire.action .. ":" .. tostring(index)))
			if desire.target ~= nil then desire.target = tostring(desire.target) end
		end
	end

	brain.flags = table_or(brain.flags)
	if type(brain.flags.built_kinds) ~= "table" then brain.flags.built_kinds = {} end
	if type(brain.flags.crafts) ~= "table" then brain.flags.crafts = {} end
	brain.carry = table_or(brain.carry)
	brain.carry.food = math.max(0, number_or(brain.carry.food, 0))
	brain.carry.wood = math.max(0, number_or(brain.carry.wood, 0))
	brain.carry.stone = math.max(0, number_or(brain.carry.stone, 0))
	brain.carry.crafted = math.max(0, number_or(brain.carry.crafted, 0))
	brain.knowledge = table_or(brain.knowledge)
	brain.knowledge.spots = table_or(brain.knowledge.spots)
	brain.knowledge.home = pos_or_nil(brain.knowledge.home)
	local valid_spots = {}
	for _, spot in ipairs(brain.knowledge.spots) do
		if type(spot) == "table" then
			spot.pos = pos_or_nil(spot.pos)
			if spot.pos then
				spot.tag = tostring(spot.tag or "место")
				spot.note = tostring(spot.note or "")
				spot.time = number_or(spot.time, 0)
				spot.valence = number_or(spot.valence, 0)
				spot.visits = math.max(0, number_or(spot.visits, 0))
				valid_spots[#valid_spots + 1] = spot
			end
		end
	end
	brain.knowledge.spots = valid_spots

	brain.memory = table_or(brain.memory)
	brain.memory.events = table_or(brain.memory.events)
	brain.memory.relationships = table_or(brain.memory.relationships)
	local events = {}
	local max_event_id = 0
	for _, event in ipairs(brain.memory.events) do
		if type(event) == "table" then
			event.id = math.max(0, number_or(event.id, 0))
			event.kind = tostring(event.kind or "event")
			event.text = tostring(event.text or "")
			event.valence = number_or(event.valence, 0)
			event.importance = clamp_number(event.importance, 1, 10, 3)
			event.strength = number_or(event.strength, event.importance)
			event.subjects = table_or(event.subjects)
			event.time = number_or(event.time, 0)
			event.pos = pos_or_nil(event.pos)
			max_event_id = math.max(max_event_id, event.id)
			events[#events + 1] = event
		end
	end
	brain.memory.events = events
	brain.memory.next_id = math.max(number_or(brain.memory.next_id, 0), max_event_id, #events)
	local relationships = {}
	for key, rel in pairs(brain.memory.relationships) do
		if type(rel) == "table" then
			local rel_key = tostring(rel.key or key)
			rel.key = rel_key
			rel.name = tostring(rel.name or rel_key)
			for _, field in ipairs({ "affinity", "trust", "fear", "familiarity",
				"interactions", "gifts", "hurts", "talks", "last_seen", "last_interaction" }) do
				rel[field] = number_or(rel[field], 0)
			end
			relationships[rel_key] = rel
		end
	end
	brain.memory.relationships = relationships

	brain.rng_seed = number_or(brain.rng_seed, 1)
	brain.rng_counter = math.max(0, number_or(brain.rng_counter, 0))
	brain.personality = table_or(brain.personality)
	if next(brain.personality) == nil then
		brain.personality = P.create(U.new_rng(brain.rng_seed))
	end
	brain.personality.traits = table_or(brain.personality.traits)
	for _, trait in ipairs(P.trait_order) do
		brain.personality.traits[trait] = clamp_number(brain.personality.traits[trait], 0.05, 0.95, 0.5)
	end
	brain.personality.occupation = tostring(brain.personality.occupation or "житель")
	brain.personality.title = tostring(brain.personality.title or "Житель")
	brain.personality.tone = tostring(brain.personality.tone or "calm")

	brain.needs = table_or(brain.needs)
	for _, need in ipairs(N.order) do
		brain.needs[need] = clamp_number(brain.needs[need], 0, 100, 60)
	end
	brain.needs_scale = clamp_number(brain.needs_scale, 0.1, 10, 1)
	brain.mood = clamp_number(brain.mood, 0, 100, 55)
	brain.stress = clamp_number(brain.stress, 0, 100, 0)
	brain.thought_bonus = number_or(brain.thought_bonus, 0)

	brain.stats = table_or(brain.stats)
	for _, field in ipairs({ "chats", "gifts", "hurts", "meals", "naps", "visits",
		"walks", "begs", "tantrums", "desires_attempted", "desires_done", "ticks",
		"wood", "stone", "builds", "crafts" }) do
		brain.stats[field] = math.max(0, number_or(brain.stats[field], 0))
	end
	brain.stats.spawned_at = number_or(brain.stats.spawned_at, 0)
	brain.stats.last_action = brain.stats.last_action and tostring(brain.stats.last_action) or nil

	brain.whim_timer = number_or(brain.whim_timer, 10)
	brain.whim_cooldowns = table_or(brain.whim_cooldowns)
	local cooldowns = {}
	for id, until_time in pairs(brain.whim_cooldowns) do
		local numeric = tonumber(until_time)
		if numeric and numeric == numeric then cooldowns[tostring(id)] = numeric end
	end
	brain.whim_cooldowns = cooldowns

	brain.name = tostring(brain.name or "Житель")
	if brain.name == "" then brain.name = "Житель" end
	brain.full_name = tostring(brain.full_name or brain.name)
	if brain.full_name == "" then brain.full_name = brain.name end
	brain.gender = tostring(brain.gender or "male")
	brain.age = math.floor(clamp_number(brain.age, 1, 120, 30))
	brain.skin = math.floor(clamp_number(brain.skin, 1, 10, 1))
	brain.backstory = tostring(brain.backstory or "История этого жителя пока не записана.")

	if type(brain.last_context) ~= "table" then brain.last_context = nil end
	brain.cache = table_or(brain.cache)
	brain.cache.food_pos = pos_or_nil(brain.cache.food_pos)
	brain.cache.water_pos = pos_or_nil(brain.cache.water_pos)
	brain.cache.interesting_pos = pos_or_nil(brain.cache.interesting_pos)
	brain.cache.food_at = number_or(brain.cache.food_at, nil)
	brain.cache.water_at = number_or(brain.cache.water_at, nil)
	brain.cache.interesting_at = number_or(brain.cache.interesting_at, nil)
	if brain.cache.food_pos then
		brain.cache.food_name = tostring(brain.cache.food_name or "")
	else
		brain.cache.food_name = nil
	end
	if brain.cache.interesting_pos then
		brain.cache.interesting_name = tostring(brain.cache.interesting_name or "")
	else
		brain.cache.interesting_name = nil
	end
	brain.perceive_seen = table_or(brain.perceive_seen)
	local seen = {}
	for key, value in pairs(brain.perceive_seen) do
		local numeric = tonumber(value)
		if numeric and numeric == numeric then seen[tostring(key)] = numeric end
	end
	brain.perceive_seen = seen
	if type(brain.goal) == "table" then
		brain.goal.action = tostring(brain.goal.action or "")
		if brain.goal.action == "" then
			brain.goal = nil
		else
			brain.goal.desire_id = tostring(brain.goal.desire_id or ("restored:" .. brain.goal.action))
			brain.goal.title = tostring(brain.goal.title or D.action_title(brain.goal.action))
			brain.goal.target = brain.goal.target and tostring(brain.goal.target) or nil
			brain.goal.target_pos = pos_or_nil(brain.goal.target_pos)
			brain.goal.fear = number_or(brain.goal.fear, 0)
			brain.goal.started = number_or(brain.goal.started, 0)
			brain.goal.story = brain.goal.story and true or false
			brain.goal.special = brain.goal.special and true or false
			brain.goal.build_kind = brain.goal.build_kind and tostring(brain.goal.build_kind) or nil
		end
	else
		brain.goal = nil
	end
	brain.activity = tostring(brain.activity or "wander")
	if brain.activity == "" then brain.activity = "wander" end
	brain.paused = brain.paused and true or false
	if brain.last_hurt ~= nil then
		brain.last_hurt = tonumber(brain.last_hurt)
		if brain.last_hurt ~= brain.last_hurt then brain.last_hurt = nil end
	end

	brain.mood_label = B.mood_label(brain)
	return brain
end

-- ---------------------------------------------------------------------------
-- Настроение и стресс
-- ---------------------------------------------------------------------------
function B.mood_label(brain)
	if (brain.stress or 0) >= 85 then return "срыв" end
	local mood = brain.mood or 50
	if mood >= 85 then return "восторг" end
	if mood >= 70 then return "радость" end
	if mood >= 55 then return "ровно" end
	if mood >= 42 then return "уныние" end
	if mood >= 28 then return "тоска" end
	return "отчаяние"
end

function B.mood_phrase(brain)
	local label = brain.mood_label or B.mood_label(brain)
	local phrases = {
		["восторг"] = "на седьмом небе от счастья",
		["радость"] = "в хорошем настроении",
		["ровно"] = "спокоен(на) и уравновешен(а)",
		["уныние"] = "немного приуныл(а)",
		["тоска"] = "сильно тоскует",
		["отчаяние"] = "на грани отчаяния",
		["срыв"] = "едва держит себя в руках",
	}
	return phrases[label] or "в обычном настроении"
end

function B.update_mood(brain, now)
	local person = brain.personality
	local weights = P.need_weights(person)
	local base = N.average(brain, weights)

	local thoughts = M.thoughts(brain, now or 0, 8)
	local bonus = 0
	for _, thought in ipairs(thoughts) do
		bonus = bonus + thought.value * P.thought_mult(person, thought.value)
	end
	bonus = U.clamp(bonus, -42, 30)
	brain.thought_bonus = bonus

	local relationships_bonus = 0
	local friend = M.best_friend(brain)
	if friend and (friend.affinity or 0) > 25 then
		relationships_bonus = relationships_bonus + math.min(8, friend.affinity * 0.1)
	end
	local enemy = M.worst_enemy(brain)
	if enemy then
		relationships_bonus = relationships_bonus - math.min(10, (enemy.fear or 0) * 0.08)
	end

	brain.mood = U.clamp(base + bonus + relationships_bonus, 0, 100)
	brain.mood_label = B.mood_label(brain)
	brain.thought_count = #thoughts
	return brain.mood
end

function B.update_stress(brain, dt)
	local person = brain.personality
	local mood = brain.mood or 50
	local neuroticism = P.get(person, "neuroticism")
	if mood < 35 then
		local rate = (35 - mood) * 0.012 * (0.6 + neuroticism)
		brain.stress = U.clamp((brain.stress or 0) + rate * dt, 0, 100)
	elseif mood > 62 then
		brain.stress = U.approach(brain.stress or 0, 0, dt * 0.10 * (1.2 - neuroticism))
	else
		brain.stress = U.approach(brain.stress or 0, 0, dt * 0.02)
	end
	brain.mood_label = B.mood_label(brain)
end

-- ---------------------------------------------------------------------------
-- Критические потребности оставляют след в памяти
-- ---------------------------------------------------------------------------
function B.check_critical_thoughts(brain, now)
	for _, need in ipairs(N.order) do
		local critical = N.is_critical(brain, need)
		local flag = "critical:" .. need
		if critical and not brain.flags[flag] then
			brain.flags[flag] = true
			M.add(brain, {
				kind = "need",
				text = B.critical_text[need] or ("Мучает нехватка: " .. N.label(need)),
				valence = -20,
				importance = 5,
			}, now)
		elseif not critical and N.get(brain, need) > (N.defs[need].critical + 12) then
			brain.flags[flag] = nil
		end
	end
end

-- ---------------------------------------------------------------------------
-- Цели
-- ---------------------------------------------------------------------------
function B.set_custom_goal(brain, action, title, now, extra)
	brain.goal = {
		desire_id = extra and extra.desire_id or ("special:" .. action),
		action = action,
		title = title or D.action_title(action),
		target = extra and extra.target or nil,
		target_pos = extra and extra.target_pos or nil,
		fear = extra and extra.fear or false,
		story = extra and extra.story or nil,
		build_kind = extra and extra.build_kind or nil,
		started = now,
		special = true,
	}
	brain.activity = action
	return brain.goal
end

function B.complete_goal(brain, now, success)
	local goal = brain.goal
	if not goal then return end
	if not goal.special then
		D.complete(brain, now, goal.desire_id, success)
	end
	brain.goal = nil
	brain.activity = "idle"
	return goal
end

function B.apply_desire(brain, desire, now)
	brain.goal = {
		desire_id = desire.id,
		action = desire.action,
		title = desire.title,
		target = desire.target,
		target_pos = desire.target_pos,
		fear = desire.fear,
		story = desire.story,
		build_kind = desire.build_kind,
		started = now,
		special = false,
	}
	brain.activity = desire.action
	brain.stats.last_action = desire.action
	return brain.goal
end

-- ---------------------------------------------------------------------------
-- Основной тик
-- ---------------------------------------------------------------------------
function B.tick(brain, ctx)
	ctx = ctx or {}
	local now = ctx.now or brain.now or 0
	local dt = U.clamp(ctx.dt or 1, 0, 10)
	brain.now = now

	N.update(brain, dt, now, ctx.environment)
	D.tick_timer(brain, dt)
	M.decay(brain, now)
	M.decay_relationships(brain, dt, now)
	B.check_critical_thoughts(brain, now)
	B.update_mood(brain, now)
	B.update_stress(brain, dt)
	D.refresh(brain, now, ctx)

	-- Истерика заканчивается сама, когда стресс спал: снимаем цель здесь,
	-- чтобы она не зависла, если действие по какой-то причине не тикало.
	if brain.goal and brain.goal.action == "tantrum" and brain.stress < 60 then
		B.finish_tantrum(brain, now)
		brain.goal = nil
	end

	-- Полный срыв: житель теряет контроль над собой на какое-то время.
	if brain.stress >= 85 and brain.mood <= 30 then
		if not brain.goal or brain.goal.action ~= "tantrum" then
			B.set_custom_goal(brain, "tantrum", "Истерика", now)
		end
		if not brain.flags.tantrum_reported then
			brain.flags.tantrum_reported = true
			brain.stats.tantrums = (brain.stats.tantrums or 0) + 1
			M.tantrum(brain, now)
		end
	else
		brain.flags.tantrum_reported = nil

		-- Особая просьба (например, «иди за мной») не должна рассыпаться
		-- от первого же случайного желания. Её снимает само действие.
		local special = brain.goal and brain.goal.special and brain.goal.action ~= "wander"
		local desire = (not special) and D.pick(brain, now) or nil
		if special then
			-- оставляем текущую цель как есть
		elseif desire then
			if not brain.goal or brain.goal.desire_id ~= desire.id then
				B.apply_desire(brain, desire, now)
			else
				-- Обновляем цель на месте, сохраняя начало действия.
				brain.goal.target = desire.target or brain.goal.target
				brain.goal.target_pos = desire.target_pos or brain.goal.target_pos
				brain.goal.title = desire.title
				brain.goal.build_kind = desire.build_kind or brain.goal.build_kind
				brain.activity = desire.action
			end
		elseif not brain.goal or brain.goal.action ~= "wander" then
			B.set_custom_goal(brain, "wander", "Погулять", now)
		end
	end

	brain.stats.ticks = (brain.stats.ticks or 0) + 1
	brain.mood_label = B.mood_label(brain)
	return brain.goal
end

-- ---------------------------------------------------------------------------
-- Взаимодействия
-- ---------------------------------------------------------------------------
function B.converse(brain, key, name, now, topic, opts)
	opts = opts or {}
	local gain = opts.gain or 18
	N.add(brain, "social", gain)
	N.add(brain, "fun", 3)
	M.conversation(brain, key, name, now, topic)
	brain.stats.chats = (brain.stats.chats or 0) + 1
	local rel = M.relationship(brain, key, name)
	if (rel.fear or 0) > 40 then
		brain.stress = U.clamp(brain.stress + 1.5, 0, 100)
	end
	B.update_mood(brain, now)
	return rel
end

-- Запас дерева пополняется рубкой; отдельный счётчик нужен панели и тестам.
function B.add_wood(brain, amount, now)
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	if amount == 0 then return brain.carry and brain.carry.wood or 0 end
	brain.carry = brain.carry or {}
	brain.carry.wood = math.max(0, (brain.carry.wood or 0) + amount)
	brain.stats = brain.stats or {}
	brain.stats.wood = math.max(0, (brain.stats.wood or 0) + amount)
	B.update_mood(brain, now or 0)
	return brain.carry.wood
end

-- Постройка запоминается как событие и увеличивает счётчик жителя.
function B.finish_build(brain, now, pos, title, kind)
	brain.stats = brain.stats or {}
	brain.stats.builds = math.max(0, (brain.stats.builds or 0) + 1)
	brain.flags = brain.flags or {}
	brain.flags.shelter_built = true
	if type(brain.flags.built_kinds) ~= "table" then brain.flags.built_kinds = {} end
	if kind then brain.flags.built_kinds[kind] = true end
	M.place(brain, title or "Построил(а) навес", now or 0, pos, 18)
	B.update_mood(brain, now or 0)
	return brain.stats.builds
end

-- Камень пополняется копанием; используется для построек и поделок.
function B.add_stone(brain, amount, now)
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	if amount == 0 then return brain.carry and brain.carry.stone or 0 end
	brain.carry = brain.carry or {}
	brain.carry.stone = math.max(0, (brain.carry.stone or 0) + amount)
	brain.stats = brain.stats or {}
	brain.stats.stone = math.max(0, (brain.stats.stone or 0) + amount)
	B.update_mood(brain, now or 0)
	return brain.carry.stone
end

-- Небольшая поделка: факел и подобные вещи. Счётчик нужен панели и тестам.
function B.craft(brain, label, now, placed)
	label = tostring(label or "вещь")
	brain.stats = brain.stats or {}
	brain.stats.crafts = math.max(0, (brain.stats.crafts or 0) + 1)
	brain.carry = brain.carry or {}
	brain.carry.crafted = math.max(0, (brain.carry.crafted or 0) + 1)
	brain.flags = brain.flags or {}
	if type(brain.flags.crafts) ~= "table" then brain.flags.crafts = {} end
	brain.flags.crafts[label] = true
	M.add(brain, {
		kind = "craft",
		text = "Смастерил(а) " .. label,
		valence = 12,
		importance = 5,
	}, now or 0)
	B.update_mood(brain, now or 0)
	if placed then brain.flags.last_craft_placed = true end
	return brain.stats.crafts
end

function B.receive_gift(brain, key, name, item_label, now)
	brain.carry.food = (brain.carry.food or 0) + 1
	M.gift(brain, key, name, item_label, now)
	brain.stats.gifts = (brain.stats.gifts or 0) + 1
	local rel = M.relationship(brain, key, name)
	if (rel.fear or 0) > 12 then
		rel.fear = U.clamp(rel.fear - 4, 0, 100)
	end
	-- Конфликт смягчается: желание сторониться дарителя пропадает.
	for i = #brain.desires, 1, -1 do
		local d = brain.desires[i]
		if d.action == "avoid" and d.target == key and (rel.fear or 0) < 25 then
			table.remove(brain.desires, i)
		end
	end
	B.update_mood(brain, now)
	return rel
end

function B.eat(brain, label, now, restore)
	N.add(brain, "hunger", restore or 36)
	N.add(brain, "hygiene", -2)
	M.meal(brain, label or "что-то съедобное", now)
	brain.stats.meals = (brain.stats.meals or 0) + 1
	B.update_mood(brain, now)
end

function B.beg(brain, player_name, now)
	M.beg(brain, player_name, now)
	brain.stats.begs = (brain.stats.begs or 0) + 1
end

function B.drop_follow_desires(brain)
	for i = #(brain.desires or {}), 1, -1 do
		if brain.desires[i].action == "follow" then
			table.remove(brain.desires, i)
		end
	end
end

function B.attacked_by(brain, key, name, now, damage)
	brain.last_hurt = now
	brain.stats.hurts = (brain.stats.hurts or 0) + 1
	N.add(brain, "safety", -28)
	brain.stress = U.clamp((brain.stress or 0) + 12 + P.get(brain.personality, "neuroticism") * 10, 0, 100)
	M.attack(brain, key, name, now, damage)
	brain.flags.following = nil
	brain.goal = nil
	B.drop_follow_desires(brain)
	D.add(brain, {
		id = "reaction:avoid:" .. key,
		action = "avoid",
		title = "Отойти от " .. name,
		line = "Только что было больно",
		target = key,
		utility = 95,
		ttl = 240,
		fear = true,
	}, now)
	B.update_mood(brain, now)
end

function B.insulted_by(brain, key, name, now)
	brain.stats.hurts = (brain.stats.hurts or 0) + 1
	N.add(brain, "safety", -10)
	brain.stress = U.clamp((brain.stress or 0) + 6, 0, 100)
	M.insult(brain, key, name, now)
	brain.flags.following = nil
	brain.goal = nil
	B.drop_follow_desires(brain)
	D.add(brain, {
		id = "reaction:avoid:" .. key,
		action = "avoid",
		title = "Отойти от " .. name,
		line = "Меня обидели",
		target = key,
		utility = 70,
		ttl = 180,
		fear = true,
	}, now)
	B.update_mood(brain, now)
end

function B.hugged_by(brain, key, name, now)
	M.hug(brain, key, name, now)
	N.add(brain, "comfort", 10)
	N.add(brain, "social", 10)
	B.update_mood(brain, now)
end

function B.praised_by(brain, key, name, now)
	M.compliment(brain, key, name, now)
	N.add(brain, "comfort", 6)
	B.update_mood(brain, now)
end

function B.finish_tantrum(brain, now)
	-- После срыва наступает опустошение: стресс падает надолго.
	brain.stress = 40
	brain.flags.tantrum_reported = nil
	brain.flags["critical:comfort"] = nil
	M.add(brain, {
		kind = "recovery",
		text = "Немного пришёл(пришла) в себя",
		valence = 6,
		importance = 2,
	}, now)
	B.update_mood(brain, now)
end

-- ---------------------------------------------------------------------------
-- Знания о местах
-- ---------------------------------------------------------------------------
function B.knowledge_add(brain, pos, tag, note, now, valence)
	if not pos then return end
	local spots = brain.knowledge.spots
	for _, spot in ipairs(spots) do
		if U.distance(spot.pos, pos) < 3 then
			spot.time = now
			spot.valence = valence or spot.valence
			spot.note = note or spot.note
			spot.visits = (spot.visits or 0) + 1
			return spot
		end
	end
	local spot = {
		pos = U.vector_copy(pos),
		tag = tag or "интересное",
		note = note,
		time = now,
		valence = valence or 5,
		visits = 1,
	}
	spots[#spots + 1] = spot
	if #spots > 16 then
		table.sort(spots, function(a, b)
			return (a.valence or 0) > (b.valence or 0)
		end)
		table.remove(spots)
	end
	M.place(brain, note or ("Запомнил(а) место: " .. (tag or "интересное")), now, pos, valence)
	return spot
end

function B.knowledge_best(brain, tag)
	local best
	for _, spot in ipairs(brain.knowledge.spots) do
		if spot.pos and (not tag or spot.tag == tag)
			and (not best or (spot.valence or 0) > (best.valence or 0)) then
			best = spot
		end
	end
	return best
end

function B.set_home(brain, pos)
	brain.knowledge.home = U.vector_copy(pos)
	brain.flags.home_set = true
end

function B.describe(brain)
	return string.format("%s — %s (%s). Настроение: %s (%d). Потребности: %s.",
		brain.full_name or brain.name,
		brain.personality.occupation or "житель",
		brain.personality.title or "житель",
		B.mood_label(brain),
		U.round(brain.mood or 50),
		N.describe(brain))
end
