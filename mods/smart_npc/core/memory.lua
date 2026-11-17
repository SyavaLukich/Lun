-- Память жителя: эпизоды, «мысли» и отношения.
-- Эпизод помнит событие, его эмоциональную окраску, важность и участников.
-- Сила воспоминания медленно убывает; важные события держатся дольше.

local M = {}
smart_npc.memory = M
local U = smart_npc.util

M.max_events = 80
M.max_relationships = 40
M.thought_ttl = 15 * 60 -- «свежие» мысли влияют на настроение 15 минут

function M.create()
	return {
		events = {},
		relationships = {},
		next_id = 1,
	}
end

local function clamp_valence(value)
	return U.clamp(value or 0, -100, 100)
end

-- Добавить эпизод. event = { kind, text, valence, importance, subjects, pos }
function M.add(brain, event, now)
	local mem = brain.memory
	mem.next_id = (mem.next_id or 1) + 1
	local e = {
		id = mem.next_id,
		kind = event.kind or "generic",
		text = event.text or "Что-то произошло",
		valence = clamp_valence(event.valence),
		importance = U.clamp(event.importance or 3, 1, 10),
		subjects = event.subjects or {},
		pos = event.pos and U.vector_copy(event.pos) or nil,
		time = now or 0,
		strength = event.importance or 3,
	}
	mem.events[#mem.events + 1] = e
	M.trim(brain, now)
	return e
end

function M.trim(brain, now)
	local events = brain.memory.events
	local kept = {}
	for i = 1, #events do
		local e = events[i]
		local age = (now or 0) - e.time
		-- Совсем свежие и важные не выбрасываем даже слабыми.
		if e.strength >= 0.3 or age < 90 or e.importance >= 7 then
			kept[#kept + 1] = e
		end
	end
	if #kept > M.max_events then
		table.sort(kept, function(a, b)
			local sa = a.strength * (1 + a.importance * 0.1)
			local sb = b.strength * (1 + b.importance * 0.1)
			return sa > sb
		end)
		while #kept > M.max_events do table.remove(kept) end
		table.sort(kept, function(a, b) return a.time < b.time end)
	end
	brain.memory.events = kept
end

function M.decay(brain, now)
	local half_life
	for _, e in ipairs(brain.memory.events) do
		local age = math.max(0, now - e.time)
		half_life = 1500 + e.importance * 1500 -- 25 минут ... 4 часа
		e.strength = e.importance * 0.5 ^ (age / half_life)
	end
	M.trim(brain, now)
end

-- Отношения слегка «остывают»: обида забывается, страх выветривается.
function M.decay_relationships(brain, dt, now)
	for key, rel in pairs(brain.memory.relationships) do
		rel.affinity = U.approach(rel.affinity or 0, 0, dt * 0.0015)
		rel.fear = U.approach(rel.fear or 0, 0, dt * 0.004)
		rel.trust = U.clamp(rel.trust or 0, 0, 100)
		if (rel.last_seen or 0) > 0 and now - rel.last_seen > 3600
			and math.abs(rel.affinity or 0) < 1 and (rel.fear or 0) < 1 then
			-- Совсем стёршееся знакомство удаляем, чтобы не копить мусор.
			brain.memory.relationships[key] = nil
		end
	end
end

function M.relationship(brain, key, name)
	local mem = brain.memory
	local rel = mem.relationships[key]
	if not rel then
		rel = {
			key = key,
			name = name or key,
			affinity = 0,
			trust = 0,
			fear = 0,
			familiarity = 0,
			interactions = 0,
			gifts = 0,
			hurts = 0,
			talks = 0,
			last_seen = 0,
			last_interaction = 0,
		}
		mem.relationships[key] = rel
	end
	if name then rel.name = name end
	return rel
end

function M.adjust(brain, key, name, deltas, now)
	local rel = M.relationship(brain, key, name)
	if deltas.affinity then rel.affinity = U.clamp(rel.affinity + deltas.affinity, -100, 100) end
	if deltas.trust then rel.trust = U.clamp(rel.trust + deltas.trust, 0, 100) end
	if deltas.fear then rel.fear = U.clamp(rel.fear + deltas.fear, 0, 100) end
	if deltas.familiarity then rel.familiarity = U.clamp(rel.familiarity + deltas.familiarity, 0, 100) end
	if deltas.interactions then rel.interactions = rel.interactions + deltas.interactions end
	if deltas.gifts then rel.gifts = rel.gifts + deltas.gifts end
	if deltas.hurts then rel.hurts = rel.hurts + deltas.hurts end
	if deltas.talks then rel.talks = rel.talks + deltas.talks end
	rel.last_seen = now or rel.last_seen
	rel.last_interaction = now or rel.last_interaction
	return rel
end

function M.seen(brain, key, name, now)
	local rel = M.relationship(brain, key, name)
	rel.last_seen = now
	rel.familiarity = U.clamp(rel.familiarity + 0.4, 0, 100)
	return rel
end

function M.forget(brain, id)
	for i = #brain.memory.events, 1, -1 do
		if brain.memory.events[i].id == id then
			table.remove(brain.memory.events, i)
			return true
		end
	end
	return false
end

function M.forget_subject(brain, key)
	local out = {}
	for _, e in ipairs(brain.memory.events) do
		local keep = true
		for _, subject in ipairs(e.subjects or {}) do
			if subject == key and e.importance < 8 then keep = false end
		end
		if keep then out[#out + 1] = e end
	end
	brain.memory.events = out
end

-- Поиск воспоминаний: учитываем силу, совпадение участников и тип.
function M.recall(brain, now, opts)
	opts = opts or {}
	local subjects = opts.subjects
	local kinds = opts.kinds
	local limit = opts.limit or 8
	local min_strength = opts.min_strength or 0.5
	local result = {}

	for _, e in ipairs(brain.memory.events) do
		local score = e.strength
		if subjects then
			for _, subject in ipairs(subjects) do
				if U.array_contains(e.subjects or {}, subject) then
					score = score * 2.2
					break
				end
			end
		end
		if kinds then
			local matched = false
			for _, kind in ipairs(kinds) do
				if e.kind == kind then matched = true break end
			end
			if not matched then score = score * 0.4 end
		end
		if score >= min_strength then
			result[#result + 1] = { event = e, score = score, age = now - e.time }
		end
	end

	table.sort(result, function(a, b) return a.score > b.score end)
	while #result > limit do table.remove(result) end
	return result
end

function M.recall_about(brain, now, key, limit)
	return M.recall(brain, now, { subjects = { key }, limit = limit or 5 })
end

-- Мысли для настроения: свежие эпизоды с эмоциональным весом.
function M.thoughts(brain, now, limit)
	local out = {}
	for _, e in ipairs(brain.memory.events) do
		local age = now - e.time
		if age <= M.thought_ttl and e.strength >= 0.6 then
			local freshness = 1 - age / M.thought_ttl
			local value = e.valence * (0.35 + e.importance / 12) * (0.4 + freshness * 0.6)
			if math.abs(value) >= 0.5 then
				out[#out + 1] = {
					text = e.text,
					value = value,
					kind = e.kind,
					age = age,
					event = e,
				}
			end
		end
	end
	table.sort(out, function(a, b) return math.abs(a.value) > math.abs(b.value) end)
	while #out > (limit or 8) do table.remove(out) end
	return out
end

function M.best_friend(brain)
	local best, best_affinity = nil, 0
	for _, rel in pairs(brain.memory.relationships) do
		if (rel.affinity or 0) > best_affinity then
			best, best_affinity = rel, rel.affinity
		end
	end
	return best
end

function M.worst_enemy(brain)
	local worst, worst_score = nil, 0
	for _, rel in pairs(brain.memory.relationships) do
		local score = (rel.fear or 0) * 0.6 - (rel.affinity or 0)
		if score > worst_score then
			worst, worst_score = rel, score
		end
	end
	return worst
end

function M.most_feared(brain)
	local worst, fear = nil, 0
	for _, rel in pairs(brain.memory.relationships) do
		if (rel.fear or 0) > fear then
			worst, fear = rel, rel.fear
		end
	end
	return worst
end

function M.relationships_sorted(brain)
	local list = {}
	for _, rel in pairs(brain.memory.relationships) do
		list[#list + 1] = rel
	end
	table.sort(list, function(a, b)
		local sa = math.abs(a.affinity or 0) + (a.fear or 0)
		local sb = math.abs(b.affinity or 0) + (b.fear or 0)
		return sa > sb
	end)
	return list
end

function M.relation_label(rel)
	if not rel then return "незнакомец" end
	local affinity = rel.affinity or 0
	local fear = rel.fear or 0
	if fear >= 60 then return "панически боится" end
	if affinity <= -50 then return "ненавидит" end
	if fear >= 30 and affinity < 0 then return "опасается и недолюбливает" end
	if affinity <= -20 then return "недолюбливает" end
	if fear >= 25 then return "побаивается" end
	if affinity >= 60 then return "считает близким другом" end
	if affinity >= 30 then return "считает другом" end
	if affinity >= 10 then return "приятель" end
	if rel.interactions and rel.interactions > 0 then return "знакомый" end
	if (rel.familiarity or 0) > 30 then return "видел несколько раз" end
	return "едва знаком"
end

function M.relation_color(rel)
	if not rel then return "#9e9e9e" end
	local affinity = rel.affinity or 0
	local fear = rel.fear or 0
	if fear >= 60 then return "#b06cd9" end
	if affinity <= -20 then return "#c8553d" end
	if affinity >= 30 then return "#5cb85c" end
	if affinity >= 10 then return "#8fbf5a" end
	return "#d9d9d9"
end

-- ============================ СОБЫТИЯ ============================

function M.gift(brain, giver_key, giver_name, item_label, now, amount)
	amount = amount or 1
	local e = M.add(brain, {
		kind = "gift",
		text = giver_name .. " дал(а) мне " .. item_label,
		valence = 26,
		importance = 6,
		subjects = { giver_key },
	}, now)
	M.adjust(brain, giver_key, giver_name, {
		affinity = 9 + amount * 2,
		trust = 5,
		gifts = amount,
		interactions = 1,
		familiarity = 4,
	}, now)
	return e
end

function M.attack(brain, attacker_key, attacker_name, now, damage)
	damage = damage or 1
	local e = M.add(brain, {
		kind = "attack",
		text = attacker_name .. " ударил(а) меня",
		valence = -72,
		importance = 9,
		subjects = { attacker_key },
	}, now)
	M.adjust(brain, attacker_key, attacker_name, {
		affinity = -30,
		trust = -25,
		fear = 34 + damage,
		hurts = 1,
		interactions = 1,
	}, now)
	return e
end

function M.insult(brain, key, name, now)
	local e = M.add(brain, {
		kind = "insult",
		text = name .. " обозвал(а) меня",
		valence = -46,
		importance = 7,
		subjects = { key },
	}, now)
	M.adjust(brain, key, name, {
		affinity = -16,
		trust = -10,
		fear = 8,
		hurts = 1,
		interactions = 1,
	}, now)
	return e
end

function M.hug(brain, key, name, now)
	local e = M.add(brain, {
		kind = "hug",
		text = name .. " обнял(а) меня",
		valence = 32,
		importance = 5,
		subjects = { key },
	}, now)
	M.adjust(brain, key, name, {
		affinity = 8,
		trust = 4,
		familiarity = 3,
		interactions = 1,
	}, now)
	return e
end

function M.compliment(brain, key, name, now)
	local e = M.add(brain, {
		kind = "praise",
		text = name .. " похвалил(а) меня",
		valence = 22,
		importance = 4,
		subjects = { key },
	}, now)
	M.adjust(brain, key, name, {
		affinity = 7,
		trust = 3,
		interactions = 1,
	}, now)
	return e
end

function M.conversation(brain, key, name, now, about)
	local text = name .. " поговорил(а) со мной"
	if about and about ~= "" then
		text = text .. " на тему «" .. about .. "»"
	end
	local e = M.add(brain, {
		kind = "talk",
		text = text,
		valence = 10,
		importance = 3,
		subjects = { key },
	}, now)
	M.adjust(brain, key, name, {
		affinity = 2,
		trust = 1.5,
		talks = 1,
		interactions = 1,
		familiarity = 3,
	}, now)
	return e
end

function M.meal(brain, food_label, now)
	return M.add(brain, {
		kind = "meal",
		text = "Поел(а) " .. food_label,
		valence = 14,
		importance = 3,
	}, now)
end

function M.nap(brain, now)
	return M.add(brain, {
		kind = "sleep",
		text = "Хорошо выспался(лась)",
		valence = 12,
		importance = 3,
	}, now)
end

function M.play(brain, now)
	return M.add(brain, {
		kind = "play",
		text = "Повеселился(лась) вволю",
		valence = 16,
		importance = 3,
	}, now)
end

function M.wash(brain, now)
	return M.add(brain, {
		kind = "wash",
		text = "Смыл(а) с себя грязь",
		valence = 9,
		importance = 2,
	}, now)
end

function M.explore(brain, now, place_name)
	return M.add(brain, {
		kind = "explore",
		text = "Увидел(а) новое место" .. (place_name and (": " .. place_name) or ""),
		valence = 13,
		importance = 3,
	}, now)
end

function M.satisfaction(brain, title, now)
	return M.add(brain, {
		kind = "desire",
		text = "Исполнил(а) желание: " .. title,
		valence = 13,
		importance = 2,
	}, now)
end

function M.failure(brain, title, now)
	return M.add(brain, {
		kind = "failure",
		text = "Не вышло: " .. title,
		valence = -9,
		importance = 2,
	}, now)
end

function M.beg(brain, player_name, now)
	local e = M.add(brain, {
		kind = "beg",
		text = "Попросил(а) еды у " .. player_name,
		valence = -4,
		importance = 3,
	}, now)
	return e
end

function M.thanks(brain, key, name, now)
	local e = M.add(brain, {
		kind = "thanks",
		text = "Поблагодарил(а) " .. name,
		valence = 12,
		importance = 3,
		subjects = { key },
	}, now)
	M.adjust(brain, key, name, { affinity = 3, interactions = 1 }, now)
	return e
end

function M.tantrum(brain, now)
	return M.add(brain, {
		kind = "tantrum",
		text = "Не выдержал(а) и устроил(а) истерику",
		valence = -35,
		importance = 8,
	}, now)
end

function M.reconcile(brain, key, name, now)
	local e = M.add(brain, {
		kind = "reconcile",
		text = "Помирился(лась) с " .. name,
		valence = 18,
		importance = 5,
		subjects = { key },
	}, now)
	M.adjust(brain, key, name, { affinity = 6, trust = 4, fear = -8, interactions = 1 }, now)
	return e
end

function M.place(brain, note, now, pos, valence)
	return M.add(brain, {
		kind = "place",
		text = note,
		valence = valence or 8,
		importance = 3,
		pos = pos,
	}, now)
end

-- Строки для панели: текст, знак и давность.
function M.summary(brain, now, limit)
	local lines = {}
	for _, item in ipairs(M.recall(brain, now, { limit = limit or 10 })) do
		local e = item.event
		local sign = e.valence >= 0 and "+" or "−"
		lines[#lines + 1] = {
			text = e.text,
			age = item.age,
			value = e.valence,
			marker = sign,
			color = e.valence >= 0 and "#8fbf5a" or "#c8553d",
		}
	end
	return lines
end

function M.remembered_people(brain)
	return M.relationships_sorted(brain)
end
