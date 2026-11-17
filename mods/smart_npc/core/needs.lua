-- Потребности жителя. 100 — полностью удовлетворены, 0 — критическая нужда.
-- Скорость убывания зависит от характера, занятия и окружения.

local N = {}
smart_npc.needs = N
local U = smart_npc.util
local P = smart_npc.personality

N.order = { "hunger", "energy", "social", "fun", "hygiene", "comfort", "safety" }

N.defs = {
	hunger = { label = "Сытость", decay = 0.055, low = 45, critical = 20 },
	energy = { label = "Бодрость", decay = 0.048, low = 45, critical = 18 },
	social = { label = "Общение", decay = 0.042, low = 45, critical = 18 },
	fun = { label = "Веселье", decay = 0.038, low = 40, critical = 15 },
	hygiene = { label = "Чистота", decay = 0.016, low = 35, critical = 12 },
	comfort = { label = "Уют", decay = 0.025, low = 40, critical = 15 },
	safety = { label = "Спокойствие", decay = 0.030, low = 45, critical = 20 },
}

-- Множители убывания для разных занятий (ключ — brain.activity).
N.activity_mods = {
	idle = { hunger = 1.0, energy = 1.0 },
	wander = { hunger = 1.15, energy = 1.25, hygiene = 1.1 },
	move = { hunger = 1.2, energy = 1.35, hygiene = 1.15 },
	sleep = { hunger = 0.5, energy = -1.6, fun = 0.4, social = 0.7 },
	eat = { hunger = -1.0, energy = 1.0 },
	talk = { social = -1.0, fun = 0.7 },
	play = { fun = -1.2, energy = 1.6, hunger = 1.2, hygiene = 1.5 },
	wash = { hygiene = -1.5, fun = 0.8 },
	warm = { comfort = -1.0, energy = 0.7 },
	seek_safety = { safety = -1.0, energy = 1.3 },
	explore = { fun = -0.5, energy = 1.5, hunger = 1.2 },
	inspect = { fun = -0.5, energy = 1.05 },
	tidy = { comfort = -0.5, energy = 1.4, hygiene = -0.2 },
	tantrum = { energy = 1.5, hunger = 1.2 },
}

-- Отрицательные значения означают восстановление (см. N.update).
N.activity_mods.beg = { energy = 1.1, social = 0.7 }
N.activity_mods.avoid = { energy = 1.4, safety = -0.4 }
N.activity_mods.follow = { energy = 1.2, social = -0.3 }
N.activity_mods.solitude = { comfort = -0.5, social = 0.4, energy = 0.9 }
N.activity_mods.thank = { social = -0.8 }
N.activity_mods.reconcile = { social = -0.8 }

function N.create(rng, personality)
	local values = {}
	for _, need in ipairs(N.order) do
		local base = 62 + rng(0, 28)
		if need == "energy" then
			base = 58 + rng(0, 38)
		elseif need == "hygiene" then
			base = 68 + rng(0, 30)
		elseif need == "safety" then
			base = 72 + rng(0, 25)
		end
		values[need] = U.clamp(base, 30, 100)
	end
	-- Немного индивидуальности: у тревожного меньше стартового спокойствия.
	values.safety = U.clamp(values.safety - P.get(personality, "neuroticism") * 15, 25, 100)
	return values
end

function N.get(brain, need)
	return (brain.needs and brain.needs[need]) or 0
end

function N.set(brain, need, value)
	if not brain.needs then brain.needs = {} end
	value = tonumber(value)
	if not value or value ~= value then return end
	brain.needs[need] = U.clamp(value, 0, 100)
	brain.need_updated = brain.need_updated or {}
	brain.need_updated[need] = true
end

function N.add(brain, need, amount)
	N.set(brain, need, N.get(brain, need) + amount)
end

function N.need_activity_mod(brain, need)
	local mods = N.activity_mods[brain.activity or "idle"]
	if not mods then return 1 end
	local value = mods[need]
	if value == nil then return 1 end
	return value
end

-- env: { danger=bool, dark=bool, day=bool, company=bool, sheltered=bool,
--        warm=bool, night=bool }
function N.update(brain, dt, now, env)
	env = env or {}
	local scale = brain.needs_scale or 1
	local person = brain.personality
	local needs = brain.needs or {}
	brain.needs = needs

	for _, need in ipairs(N.order) do
		local def = N.defs[need]
		local value = needs[need] or 50
		local rate = def.decay * scale * P.decay_mod(person, need)

		-- Занятие может замедлить, остановить или обратить убывание.
		local activity_mod = N.need_activity_mod(brain, need)
		local delta

		if activity_mod < 0 then
			-- Отрицательное значение — восстановление, пунктов в секунду.
			delta = -activity_mod * dt
		else
			delta = -rate * activity_mod * dt
		end

		if need == "social" then
			if env.company then
				delta = dt * 0.18
			end
		elseif need == "safety" then
			if env.danger then
				delta = delta - rate * 3 * dt
			elseif env.dark then
				delta = delta - rate * 0.8 * dt
			else
				delta = dt * 0.5
			end
		elseif need == "comfort" then
			if env.sheltered then
				delta = delta + dt * 0.25
			end
			if env.warm then
				delta = delta + dt * 0.2
			end
		elseif need == "energy" then
			if env.night then
				delta = delta - rate * 0.15 * dt
			end
		elseif need == "fun" and brain.activity == "talk" then
			delta = delta + dt * 0.05
		end

		needs[need] = U.clamp(value + delta, 0, 100)
	end
	brain.needs_updated_at = now
end

-- Насколько потребность неудовлетворена (0..1).
function N.deficit(brain, need)
	local def = N.defs[need]
	if not def then return 0 end
	local value = N.get(brain, need)
	return U.clamp((def.low - value) / def.low, 0, 1)
end

function N.is_critical(brain, need)
	local def = N.defs[need]
	return def and N.get(brain, need) <= def.critical
end

function N.worst(brain)
	local worst, worst_value = nil, 101
	for _, need in ipairs(N.order) do
		local value = N.get(brain, need)
		if value < worst_value then
			worst, worst_value = need, value
		end
	end
	return worst, worst_value
end

function N.average(brain, weights)
	local sum, total = 0, 0
	for need, weight in pairs(weights or {}) do
		sum = sum + N.get(brain, need) * weight
		total = total + weight
	end
	if total == 0 then return 50 end
	return sum / total
end

function N.label(need)
	local def = N.defs[need]
	return def and def.label or need
end

function N.describe(brain)
	local parts = {}
	for _, need in ipairs(N.order) do
		parts[#parts + 1] = string.format("%s %d", N.label(need), U.round(N.get(brain, need)))
	end
	return table.concat(parts, " · ")
end
