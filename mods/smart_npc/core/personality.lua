-- Характер жителя: пять черт (как в The Sims) плюс архетип и профессия.
-- Черты хранятся в диапазоне 0..1 и влияют на потребности, желания и настроение.

local P = {}
smart_npc.personality = P

P.trait_order = { "openness", "conscientiousness", "extraversion", "agreeableness", "neuroticism" }

P.trait_labels = {
	openness = "Открытость",
	conscientiousness = "Добросовестность",
	extraversion = "Общительность",
	agreeableness = "Доброжелательность",
	neuroticism = "Тревожность",
}

P.trait_compact = {
	openness = "Открытость",
	conscientiousness = "Порядок",
	extraversion = "Общительность",
	agreeableness = "Доброта",
	neuroticism = "Тревожность",
}

P.trait_short = {
	openness = "любознательность",
	conscientiousness = "аккуратность",
	extraversion = "общительность",
	agreeableness = "мягкость",
	neuroticism = "тревожность",
}

-- Архетипы задают «скелет» характера; при создании черты слегка смещаются.
P.archetypes = {
	{
		id = "dreamer",
		title = "Мечтатель",
		traits = { openness = 0.86, conscientiousness = 0.34, extraversion = 0.46,
			agreeableness = 0.64, neuroticism = 0.46 },
		occupations = { "Художник", "Сказочник", "Садовник", "Звездочёт" },
	},
	{
		id = "worker",
		title = "Трудяга",
		traits = { openness = 0.40, conscientiousness = 0.88, extraversion = 0.48,
			agreeableness = 0.62, neuroticism = 0.28 },
		occupations = { "Плотник", "Каменщик", "Кузнец", "Фермер" },
	},
	{
		id = "socialite",
		title = "Душа компании",
		traits = { openness = 0.58, conscientiousness = 0.52, extraversion = 0.90,
			agreeableness = 0.82, neuroticism = 0.30 },
		occupations = { "Трактирщик", "Пекарь", "Музыкант", "Глашатай" },
	},
	{
		id = "grump",
		title = "Ворчун",
		traits = { openness = 0.44, conscientiousness = 0.58, extraversion = 0.36,
			agreeableness = 0.22, neuroticism = 0.76 },
		occupations = { "Сторож", "Сборщик налогов", "Критик", "Могильщик" },
	},
	{
		id = "hermit",
		title = "Созерцатель",
		traits = { openness = 0.82, conscientiousness = 0.56, extraversion = 0.18,
			agreeableness = 0.58, neuroticism = 0.44 },
		occupations = { "Летописец", "Травник", "Отшельник", "Картограф" },
	},
	{
		id = "keeper",
		title = "Хранитель",
		traits = { openness = 0.50, conscientiousness = 0.84, extraversion = 0.44,
			agreeableness = 0.80, neuroticism = 0.40 },
		occupations = { "Библиотекарь", "Смотритель", "Повар", "Лекарь" },
	},
	{
		id = "adventurer",
		title = "Искатель приключений",
		traits = { openness = 0.88, conscientiousness = 0.42, extraversion = 0.76,
			agreeableness = 0.56, neuroticism = 0.36 },
		occupations = { "Разведчик", "Охотник за сокровищами", "Проводник", "Рыбак" },
	},
	{
		id = "rebel",
		title = "Бунтарь",
		traits = { openness = 0.74, conscientiousness = 0.30, extraversion = 0.64,
			agreeableness = 0.20, neuroticism = 0.60 },
		occupations = { "Наёмник", "Авантюрист", "Спорщик", "Бродяга" },
	},
}

local function clamp01(value)
	if value < 0.05 then return 0.05 end
	if value > 0.95 then return 0.95 end
	return value
end

function P.create(rng)
	local base = P.archetypes[rng(1, #P.archetypes)]
	local traits = {}
	for _, trait in ipairs(P.trait_order) do
		-- Небольшой разброс, чтобы два «Трудяги» не были близнецами.
		local jitter = (rng(0, 240) - 120) / 1000
		traits[trait] = clamp01(base.traits[trait] + jitter)
	end
	local person = {
		traits = traits,
		archetype = base.id,
		title = base.title,
		occupation = base.occupations[rng(1, #base.occupations)],
		tone = P.tone_for(traits),
	}
	return person
end

function P.tone_for(traits)
	if traits.neuroticism >= 0.66 then return "anxious" end
	if traits.agreeableness <= 0.3 then return "grumpy" end
	if traits.extraversion >= 0.7 then return "warm" end
	if traits.openness >= 0.72 then return "curious" end
	return "calm"
end

function P.get(person, trait)
	person = person or {}
	return (person.traits and person.traits[trait]) or 0.5
end

function P.label(person, trait)
	return P.trait_labels[trait] or trait
end

function P.archetype_title(person)
	return (person and person.title) or "Житель"
end

function P.describe(person)
	local bits = {}
	for _, trait in ipairs(P.trait_order) do
		local value = P.get(person, trait)
		if value >= 0.7 then
			bits[#bits + 1] = "очень " .. P.trait_short[trait]
		elseif value <= 0.3 then
			bits[#bits + 1] = "совсем не " .. P.trait_short[trait]
		end
	end
	if #bits == 0 then
		return "Уравновешенный характер без крайностей."
	end
	return "Характер: " .. table.concat(bits, ", ") .. "."
end

-- Вклад потребностей в настроение. Общительному важнее общение,
-- тревожному — безопасность, любознательному — развлечения.
function P.need_weights(person)
	return {
		hunger = 0.22,
		energy = 0.18,
		social = 0.13 + P.get(person, "extraversion") * 0.06,
		fun = 0.10 + P.get(person, "openness") * 0.05,
		hygiene = 0.07,
		comfort = 0.11,
		safety = 0.11 + P.get(person, "neuroticism") * 0.07,
	}
end

-- Скорость убывания потребности.
function P.decay_mod(person, need)
	local e = P.get(person, "extraversion")
	local o = P.get(person, "openness")
	local c = P.get(person, "conscientiousness")
	local n = P.get(person, "neuroticism")
	if need == "hunger" then return 0.9 + e * 0.15 + (1 - c) * 0.1 end
	if need == "energy" then return 0.85 + n * 0.3 end
	if need == "social" then return 0.7 + e * 0.7 end
	if need == "fun" then return 0.8 + o * 0.5 end
	if need == "hygiene" then return 0.9 + c * 0.3 end
	if need == "comfort" then return 0.9 + n * 0.2 end
	if need == "safety" then return 0.7 + n * 0.8 end
	return 1
end

-- Насколько сильно характер подталкивает к действию.
function P.desire_weight(person, action)
	local e = P.get(person, "extraversion")
	local o = P.get(person, "openness")
	local c = P.get(person, "conscientiousness")
	local a = P.get(person, "agreeableness")
	local n = P.get(person, "neuroticism")
	if action == "eat" then return 0.9 + c * 0.15 end
	if action == "sleep" then return 1.0 - o * 0.1 end
	if action == "talk" then return 0.75 + e * 0.55 end
	if action == "play" then return 0.8 + o * 0.35 + e * 0.15 end
	if action == "wash" then return 0.7 + c * 0.5 end
	if action == "warm" then return 0.85 + (1 - o) * 0.25 end
	if action == "seek_safety" then return 0.8 + n * 0.6 end
	if action == "explore" then return 0.5 + o * 0.9 end
	if action == "tidy" then return 0.4 + c * 0.9 end
	if action == "solitude" then return 0.5 + (1 - e) * 0.7 end
	if action == "thank" then return 0.4 + a * 0.8 end
	if action == "avoid" then return 0.5 + n * 0.6 end
	if action == "reconcile" then return 0.4 + a * 0.8 end
	if action == "follow" then return 0.3 + a * 0.6 + e * 0.2 end
	return 1
end

-- Тревожные сильнее переживают плохое, доброжелательные — лучше держат удар.
function P.thought_mult(person, valence)
	local n = P.get(person, "neuroticism")
	local a = P.get(person, "agreeableness")
	if valence < 0 then
		return 0.55 + n * 0.9 - a * 0.2
	end
	return 0.75 + a * 0.35 + (1 - n) * 0.2
end

function P.speech_style(person)
	if person.tone == "anxious" then return "взволнованно" end
	if person.tone == "grumpy" then return "сухо" end
	if person.tone == "warm" then return "тепло" end
	if person.tone == "curious" then return "с интересом" end
	return "спокойно"
end
