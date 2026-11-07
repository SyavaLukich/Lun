-- Желания (аналог whims в The Sims и «желаний» в Dwarf Fortress).
-- Часть желаний растёт из потребностей, часть — из характера, памяти и отношений.

local D = {}
smart_npc.desires = D
local U = smart_npc.util
local P = smart_npc.personality
local M = smart_npc.memory
local N = smart_npc.needs

D.max_whims = 3
D.whim_interval = { 20, 42 }

D.need_defs = {
	hunger = { action = "eat", threshold = 58, weight = 1.8, title = "Поесть", line = "Проголодался(лась)" },
	energy = { action = "sleep", threshold = 50, weight = 1.7, title = "Поспать", line = "Слипаются глаза" },
	social = { action = "talk", threshold = 54, weight = 1.25, title = "Поговорить", line = "Скучно без компании" },
	fun = { action = "play", threshold = 48, weight = 1.0, title = "Развлечься", line = "Хочется чего-то весёлого" },
	hygiene = { action = "wash", threshold = 42, weight = 0.8, title = "Помыться", line = "Пора смыть грязь" },
	comfort = { action = "warm", threshold = 45, weight = 1.0, title = "Устроиться поудобнее", line = "Не хватает уюта" },
	safety = { action = "seek_safety", threshold = 55, weight = 1.6, title = "Укрыться в безопасности", line = "Тревожно на душе" },
}

local function find_desire(brain, id)
	for i, d in ipairs(brain.desires or {}) do
		if d.id == id then return d, i end
	end
	return nil
end

function D.get_need_desire(brain, id)
	return find_desire(brain, "need:" .. id)
end

local function best_social_target(brain, ctx)
	local targets = ctx.social_targets
	if not targets or #targets == 0 then return nil end
	local best, best_score = nil, -math.huge
	local extraversion = P.get(brain.personality, "extraversion")
	for _, target in ipairs(targets) do
		local rel = brain.memory.relationships[target.key]
		local affinity = rel and rel.affinity or 0
		local fear = rel and rel.fear or 0
		local score = affinity + (target.kind == "player" and 4 or 0)
			- target.distance * 0.6 - fear * 0.8 + extraversion * 3
		-- Сильно испуганный житель не ищет компании обидчика.
		if score > best_score and fear < 50 then
			best, best_score = target, score
		end
	end
	return best
end

-- Цель для «поблагодарить»/«мириться»/«сторониться».
local function target_by_key(ctx, key)
	if not ctx.social_targets then return nil end
	for _, target in ipairs(ctx.social_targets) do
		if target.key == key then return target end
	end
	return nil
end

local function recent_event(brain, now, kinds, max_age)
	local best, best_score = nil, 0
	for _, e in ipairs(brain.memory.events) do
		local age = now - e.time
		if age <= max_age then
			local matched = false
			for _, kind in ipairs(kinds) do
				if e.kind == kind then matched = true break end
			end
			if matched then
				local score = e.importance / (1 + age / 600)
				if score > best_score then best, best_score = e, score end
			end
		end
	end
	return best
end

local function subject_of(event)
	if not event or not event.subjects then return nil end
	return event.subjects[1]
end

local function add_whim(brain, now, def)
	for _, existing in ipairs(brain.desires) do
		if existing.id == def.id then
			-- Обновляем существующее желание, но не плодим дубли.
			for k, v in pairs(def) do existing[k] = v end
			return existing
		end
	end
	def.source = "whim"
	def.created = now
	def.expires = now + (def.ttl or 300)
	brain.desires[#brain.desires + 1] = def
	return def
end

local function can_whim(brain, now, action)
	local until_time = (brain.whim_cooldowns or {})[action]
	return not until_time or now >= until_time
end

-- Проверки мира необязательны: ядро желаний можно гонять без Luanti.
local function has_tree_near(brain, ctx)
	local W = smart_npc.world
	if not W or not W.find_resource_pos or not ctx or not ctx.pos then return true end
	return W.find_resource_pos(ctx.pos, smart_npc.tree_nodes, 20, brain) ~= nil
end

local function can_build_now(brain)
	local W = smart_npc.world
	if not W or not W.is_creative then return true end
	if W.is_creative() then return true end
	local wood, stone = brain.carry.wood or 0, brain.carry.stone or 0
	return wood >= 23 or (wood >= 14 and stone >= 9)
end

-- ---------------------------------------------------------------------------
-- Потребностные желания
-- ---------------------------------------------------------------------------
local function refresh_need_desires(brain, now, ctx)
	brain.desires = brain.desires or {}
	local target = nil

	for need, def in pairs(D.need_defs) do
		local value = N.get(brain, need)
		local desire = find_desire(brain, "need:" .. need)

		if value <= def.threshold then
			local deficit = U.clamp((def.threshold - value) / def.threshold, 0, 1)
			local urgency = 0
			if value <= 20 then urgency = 26
			elseif value <= 32 then urgency = 12 end
			local utility = 12 + deficit * 55 * def.weight
				* P.desire_weight(brain.personality, def.action) + urgency

			if not desire then
				desire = {
					id = "need:" .. need,
					source = "need",
					need = need,
					action = def.action,
					title = def.title,
					line = def.line,
					created = now,
				}
				brain.desires[#brain.desires + 1] = desire
			end

			desire.utility = utility
			desire.expires = now + 120
			desire.cooldown_until = desire.cooldown_until or 0
			desire.progress = U.round((1 - deficit) * 100)

			if need == "social" then
				target = best_social_target(brain, ctx)
				desire.target = target and target.key or nil
				if not target then
					desire.utility = desire.utility * 0.4
				end
			end
		elseif desire and value > def.threshold + 6 then
			U.array_remove(brain.desires, desire)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Желания из характера, памяти и отношений
-- ---------------------------------------------------------------------------
local function generate_whims(brain, now, ctx)
	local whims = 0
	for _, d in ipairs(brain.desires) do
		if d.source == "whim" then whims = whims + 1 end
	end
	if whims >= D.max_whims then return end

	local o = P.get(brain.personality, "openness")
	local c = P.get(brain.personality, "conscientiousness")
	local e = P.get(brain.personality, "extraversion")
	local a = P.get(brain.personality, "agreeableness")
	local n = P.get(brain.personality, "neuroticism")

	local candidates = {}

	-- Любознательные хотят осмотреть окрестности.
	if o >= 0.45 and can_whim(brain, now, "explore") then
		candidates[#candidates + 1] = {
			id = "whim:explore",
			action = "explore",
			title = "Осмотреть окрестности",
			line = "Тянет узнать, что за тем поворотом",
			utility = 8 + o * 22 + U.rand_int(brain, -3, 3),
			ttl = 240,
		}
	end

	-- Аккуратные — прибраться и проверить хозяйство.
	if c >= 0.5 and brain.knowledge.home and can_whim(brain, now, "tidy") then
		candidates[#candidates + 1] = {
			id = "whim:tidy",
			action = "tidy",
			title = "Прибраться у дома",
			line = "Беспорядок не даёт покоя",
			utility = 7 + c * 20 + U.rand_int(brain, -3, 3),
			ttl = 300,
		}
	end

	-- Хозяйственные жители заготавливают дерево для будущих построек.
	if c >= 0.3 and (brain.carry and (brain.carry.wood or 0) < 30)
		and can_whim(brain, now, "chop") and has_tree_near(brain, ctx) then
		candidates[#candidates + 1] = {
			id = "whim:chop",
			action = "chop",
			title = "Заготовить дерево",
			line = "Для хозяйства нужно немного древесины",
			utility = 10 + c * 14 + U.rand_int(brain, -3, 3),
			ttl = 300,
		}
	end

	-- Обустроиться хочется хотя бы раз: житель ставит небольшой навес у дома.
	if c >= 0.4 and brain.knowledge.home and brain.stats and (brain.stats.builds or 0) < 1
		and can_whim(brain, now, "build") and can_build_now(brain) then
		candidates[#candidates + 1] = {
			id = "whim:build",
			action = "build",
			title = "Построить навес",
			line = "Хочется укрыть свой уголок от дождя",
			utility = 22 + c * 16 + U.rand_int(brain, -3, 3),
			ttl = 420,
		}
	end

	-- Интроверты ищут тишину.
	if e <= 0.6 and N.get(brain, "social") >= 55 and can_whim(brain, now, "solitude") then
		candidates[#candidates + 1] = {
			id = "whim:solitude",
			action = "solitude",
			title = "Побыть в тишине",
			line = "Хочется немного побыть одному(ой)",
			utility = 7 + (1 - e) * 16 + U.rand_int(brain, -3, 3),
			ttl = 240,
		}
	end

	-- Свежая обида рождает желание держаться подальше.
	local hurt = recent_event(brain, now, { "attack", "insult" }, 2 * 3600)
	local hurt_key = subject_of(hurt)
	if hurt_key then
		local rel = brain.memory.relationships[hurt_key]
		local fear = rel and rel.fear or 20
		if fear >= 15 and can_whim(brain, now, "avoid") then
			candidates[#candidates + 1] = {
				id = "whim:avoid",
				action = "avoid",
				title = "Держаться подальше",
				line = "Рядом с этим человеком мне не по себе",
				utility = 18 + fear * 0.45 + U.rand_int(brain, -2, 3),
				ttl = 360,
				priority = 3,
				target = hurt_key,
				fear = true,
			}
		end
	end

	-- Подарок хочется отблагодарить.
	local gift = recent_event(brain, now, { "gift" }, 3 * 3600)
	local gift_key = subject_of(gift)
	if gift_key and can_whim(brain, now, "thank") then
		local target = target_by_key(ctx, gift_key)
		if target then
			candidates[#candidates + 1] = {
				id = "whim:thank",
				action = "thank",
				title = "Поблагодарить " .. target.name,
				line = "Доброе дело не должно остаться без благодарности",
				utility = 12 + a * 20 + U.rand_int(brain, -3, 3),
				ttl = 240,
				priority = 2,
				target = gift_key,
			}
		end
	end

	-- Мягкие люди мирятся, даже если их обидели.
	if a >= 0.55 and hurt_key and can_whim(brain, now, "reconcile") then
		local target = target_by_key(ctx, hurt_key)
		local rel = brain.memory.relationships[hurt_key]
		if target and rel and (rel.affinity or 0) < 0 and (rel.fear or 0) < 55 then
			candidates[#candidates + 1] = {
				id = "whim:reconcile",
				action = "reconcile",
				title = "Помириться с " .. target.name,
				line = "Ссора тяжелее, чем кажется",
				utility = 8 + a * 16 + U.rand_int(brain, -3, 3),
				ttl = 300,
				priority = 2,
				target = hurt_key,
			}
		end
	end

	-- Компанейские хотят побыть с другом.
	local friend = M.best_friend(brain)
	if e >= 0.55 and friend and (friend.affinity or 0) >= 35 and can_whim(brain, now, "follow") then
		local target = target_by_key(ctx, friend.key)
		if target then
			candidates[#candidates + 1] = {
				id = "whim:follow",
				action = "follow",
				title = "Побыть рядом с " .. target.name,
				line = "С другом и молчать приятно",
				utility = 8 + a * 10 + e * 8 + U.rand_int(brain, -3, 3),
				ttl = 240,
				target = friend.key,
			}
		end
	end

	-- Настроение хорошее — хочется поделиться им.
	if e >= 0.6 and brain.mood >= 68 and can_whim(brain, now, "tell_story") then
		local target = best_social_target(brain, ctx)
		if target then
			candidates[#candidates + 1] = {
				id = "whim:tell_story",
				action = "talk",
				title = "Рассказать историю " .. target.name,
				line = "Есть чем поделиться",
				utility = 10 + e * 16 + U.rand_int(brain, -3, 3),
				ttl = 180,
				target = target.key,
				story = true,
			}
		end
	end

	-- Припасённая еда манит даже не очень голодного.
	if brain.carry and (brain.carry.food or 0) > 0 and N.get(brain, "hunger") <= 78
		and can_whim(brain, now, "eat") then
		candidates[#candidates + 1] = {
			id = "whim:snack",
			action = "eat",
			title = "Перекусить",
			line = "Припасённая еда так и просится в руки",
			utility = 16 + U.rand_int(brain, -3, 3),
			ttl = 180,
		}
	end

	-- Навестить место, которое понравилось раньше.
	if brain.knowledge.spots and #brain.knowledge.spots > 0 and can_whim(brain, now, "visit") then
		local spot
		for _, s in ipairs(brain.knowledge.spots) do
			if (s.valence or 0) > 0 and (s.visits or 0) < 3 then
				spot = s
				break
			end
		end
		if spot then
			candidates[#candidates + 1] = {
				id = "whim:visit",
				action = "visit",
				title = "Навестить знакомое место",
				line = "Там было спокойно и хорошо",
				utility = 7 + o * 12 + U.rand_int(brain, -3, 3),
				ttl = 300,
				target_pos = U.vector_copy(spot.pos),
			}
		end
	end

	if #candidates == 0 then return end

	-- Берём лучшее из доступных и слегка шумим, чтобы поведение не было машинным.
	table.sort(candidates, function(x, y)
		local px, py = x.priority or 0, y.priority or 0
		if px ~= py then return px > py end
		return x.utility > y.utility
	end)
	local chosen = candidates[1]
	chosen.utility = math.max(5, chosen.utility)
	add_whim(brain, now, chosen)
	chosen.whim_candidate = nil

	local action = chosen.action
	brain.whim_cooldowns = brain.whim_cooldowns or {}
	brain.whim_cooldowns[action] = now + U.rand_int(brain, 90, 220)
end

function D.refresh(brain, now, ctx)
	ctx = ctx or {}
	brain.desires = brain.desires or {}

	refresh_need_desires(brain, now, ctx)

	if (brain.whim_timer or 0) <= 0 then
		generate_whims(brain, now, ctx)
		brain.whim_timer = U.rand_int(brain, D.whim_interval[1], D.whim_interval[2])
	end

	D.prune(brain, now)
end

function D.tick_timer(brain, dt)
	brain.whim_timer = (brain.whim_timer or 0) - dt
end

function D.prune(brain, now)
	brain.desires = brain.desires or {}
	local out = {}
	for _, d in ipairs(brain.desires) do
		local expired = d.expires and now > d.expires
		local need_def = d.need and D.need_defs[d.need]
		local need_ok = d.source ~= "need" or (need_def ~= nil and N.get(brain, d.need) <= need_def.threshold + 6)
		if not expired and need_ok then
			out[#out + 1] = d
		elseif d.source == "whim" then
			brain.whim_cooldowns = brain.whim_cooldowns or {}
			brain.whim_cooldowns[d.action] = math.max(brain.whim_cooldowns[d.action] or 0, now + 30)
		end
	end
	brain.desires = out
end

-- Выбор текущего желания. Небольшой бонус текущей цели не даёт метаться.
function D.pick(brain, now)
	local best, best_utility = nil, -math.huge
	local current_id = brain.goal and brain.goal.desire_id
	for _, d in ipairs(brain.desires or {}) do
		if (d.cooldown_until or 0) <= now and (d.expires or math.huge) > now then
			local utility = d.utility
			if d.fear then utility = utility + 4 end
			if d.id == current_id then utility = utility + 10 end
			if utility > best_utility then
				best, best_utility = d, utility
			end
		end
	end
	return best
end

function D.find(brain, id)
	return find_desire(brain, id)
end

function D.complete(brain, now, desire_id, success)
	local desire, index = find_desire(brain, desire_id)
	if not desire then return end

	if desire.source == "whim" then
		table.remove(brain.desires, index)
		brain.whim_cooldowns = brain.whim_cooldowns or {}
		brain.whim_cooldowns[desire.action] = now + U.rand_int(brain, 120, 260)
	else
		desire.cooldown_until = success and (now + 15) or (now + 45)
	end

	if success then
		M.satisfaction(brain, desire.title, now)
		brain.stats.desires_done = (brain.stats.desires_done or 0) + 1
	elseif desire.source == "whim" then
		M.failure(brain, desire.title, now)
	end
	brain.stats.desires_attempted = (brain.stats.desires_attempted or 0) + 1
end

function D.add(brain, desire, now)
	desire.source = desire.source or "custom"
	desire.created = desire.created or now
	desire.expires = desire.expires or (now + (desire.ttl or 300))
	desire.id = desire.id or ("custom:" .. tostring(desire.action) .. ":" .. tostring(now))
	brain.desires = brain.desires or {}
	for _, existing in ipairs(brain.desires) do
		if existing.id == desire.id then
			for key, value in pairs(desire) do existing[key] = value end
			-- Новое событие снова делает желание актуальным.
			existing.cooldown_until = nil
			return existing
		end
	end
	brain.desires[#brain.desires + 1] = desire
	return desire
end

function D.top(brain, limit)
	local list = {}
	for _, d in ipairs(brain.desires or {}) do
		list[#list + 1] = d
	end
	table.sort(list, function(a, b) return a.utility > b.utility end)
	while #list > (limit or 3) do table.remove(list) end
	return list
end

function D.action_title(action)
	local titles = {
		eat = "Ест",
		sleep = "Спит",
		talk = "Разговаривает",
		play = "Играет",
		wash = "Моется",
		warm = "Греется",
		seek_safety = "Ищет безопасное место",
		explore = "Исследует окрестности",
		inspect = "Разглядывает",
		tidy = "Прибирается",
		thank = "Благодарит",
		avoid = "Сторонится",
		follow = "Идёт следом",
		solitude = "Отдыхает в тишине",
		beg = "Просит еды",
		tantrum = "В истерике",
		reconcile = "Мирится",
		visit = "Навещает место",
		wander = "Гуляет",
		chop = "Рубит дерево",
		build = "Строит навес",
		idle = "Стоит",
	}
	return titles[action] or action
end
