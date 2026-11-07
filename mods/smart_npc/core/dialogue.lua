-- Реплики жителей. Текст зависит от характера, настроения, памяти и отношений,
-- поэтому один и тот же вопрос редко получает одинаковый ответ.

local T = {}
smart_npc.dialogue = T
local U = smart_npc.util
local P = smart_npc.personality
local N = smart_npc.needs
local M = smart_npc.memory
local B = smart_npc.brain
local D = smart_npc.desires

local function rnd(brain, low, high)
	return U.rand_int(brain, low, high)
end

local function pick(brain, list)
	return list[rnd(brain, 1, #list)]
end

local function relation_label(brain, player_key)
	local rel = brain.memory.relationships[player_key]
	return M.relation_label(rel), rel
end

local function address_by_relation(brain, player_name, rel)
	if not rel or (rel.interactions or 0) == 0 then
		return player_name
	end
	if (rel.affinity or 0) >= 40 then
		return pick(brain, { "друг " .. player_name, player_name, "дорогой(ая) " .. player_name })
	end
	if (rel.affinity or 0) <= -20 then
		return player_name
	end
	return pick(brain, { player_name, player_name, "сосед" })
end

T.topics = {
	{ id = "greet", title = "Привет" },
	{ id = "mood", title = "Как дела?" },
	{ id = "memory", title = "Что помнишь?" },
	{ id = "wants", title = "Чего хочешь?" },
	{ id = "self", title = "Кто ты?" },
	{ id = "help", title = "Чем помочь?" },
	{ id = "bye", title = "Пока" },
}

function T.greeting(brain, player_name, now, player_key)
	player_key = player_key or ("player:" .. player_name)
	local label, rel = relation_label(brain, player_key)
	local mood = brain.mood or 50
	local fear = rel and rel.fear or 0
	local affinity = rel and rel.affinity or 0
	local name = brain.name

	if fear >= 55 then
		return pick(brain, {
			"Не подходи... пожалуйста. Мне всё ещё страшно.",
			"Я... я лучше отойду. Ты ведь не обидишь меня?",
			"Тише. Я помню, что было в прошлый раз.",
		})
	end

	if not rel or (rel.interactions or 0) == 0 then
		return string.format("%s, %s, %s. Мы ещё не знакомы.", pick(brain, { "Привет", "Здравствуй", "Здравствуйте" }), name,
			brain.personality.occupation or "житель")
	end

	if affinity >= 45 then
		return string.format("%s, %s! Рад(а) тебя видеть. %s",
			pick(brain, { "О, привет", "Здравствуй", "Снова ты" }),
			player_name,
			pick(brain, {
				"Я как раз вспоминал(а) о тебе.",
				"Ты всегда приходишь вовремя.",
				"Сегодня день стал лучше.",
			}))
	end

	if affinity <= -25 then
		return pick(brain, {
			string.format("%s. Чего тебе?", player_name),
			"Опять ты. Я помню, что ты сделал(а).",
			string.format("Не рассчитывай на тёплый приём, %s.", player_name),
		})
	end

	if mood < 30 then
		return string.format("%s, %s... Мне сейчас не до разговоров.", pick(brain, { "Привет", "Здравствуй" }), player_name)
	end

	if brain.personality.tone == "anxious" then
		return string.format("%s, %s. Всё ли спокойно вокруг?", pick(brain, { "Здравствуй", "Привет" }), player_name)
	end

	return string.format("%s, %s. Я %s, %s.", pick(brain, { "Здравствуй", "Привет", "Добрый день" }),
		player_name, name, label)
end

local function memory_part(brain, player_name, now)
	local lines = {}
	local recall = M.recall(brain, now, {
		subjects = { "player:" .. player_name },
		limit = 2,
		min_strength = 0.6,
	})
	for _, item in ipairs(recall) do
		lines[#lines + 1] = item.event.text
	end
	if #lines == 0 then
		local recent = M.recall(brain, now, { limit = 1, min_strength = 1.2 })
		if recent[1] then lines[1] = recent[1].event.text end
	end
	return lines
end

function T.answer(brain, player_name, topic, now, player_key)
	player_key = player_key or ("player:" .. player_name)
	local rel = brain.memory.relationships[player_key]
	local mood = brain.mood or 50

	if topic == "greet" then
		return T.greeting(brain, player_name, now, player_key)
	end

	if topic == "mood" then
		local worst = N.worst(brain)
		local worst_text = {
			hunger = pick(brain, { "Живот урчит — не отказался(лась) бы от еды.", "Голод даёт о себе знать." }),
			energy = pick(brain, { "Слипаются глаза. Скорее бы отдохнуть.", "Я совсем вымотан(а)." }),
			social = pick(brain, { "Скучно без разговоров.", "Мне не хватало компании." }),
			fun = pick(brain, { "Хочется чего-нибудь весёлого.", "День какой-то пресный." }),
			hygiene = pick(brain, { "Пора бы умыться.", "Чувствую себя грязным(ой)." }),
			comfort = pick(brain, { "Здесь неуютно.", "Хочется тепла и покоя." }),
			safety = pick(brain, { "Что-то тревожно на душе.", "Я не чувствую себя в безопасности." }),
		}
		local text = string.format("Я %s.", B.mood_phrase(brain))
		if mood < 45 and worst_text[worst] then
			text = text .. " " .. worst_text[worst]
		elseif (rel and (rel.fear or 0) > 40) then
			text = text .. " Правда, рядом с тобой мне немного не по себе."
		elseif mood >= 70 then
			text = text .. " " .. pick(brain, {
				"Сегодня хороший день.",
				"Кажется, у меня всё получается.",
				"Я рад(а), что ты спросил(а).",
			})
		end
		return text
	end

	if topic == "memory" then
		local lines = memory_part(brain, player_name, now)
		if #lines == 0 then
			return "Память пока почти пуста. Я ведь недавно здесь."
		end
		local text = "Помню: " .. lines[1]
		if lines[2] then text = text .. ". И ещё: " .. lines[2] end
		return text .. "."
	end

	if topic == "wants" then
		local top = D.top(brain, 3)
		if #top == 0 then
			return "Пока мне ничего особенного не хочется. Просто живу."
		end
		local titles = {}
		for i = 1, #top do
			titles[i] = top[i].title
		end
		local text = "Сейчас больше всего хочется: " .. table.concat(titles, ", ") .. "."
		local main = top[1]
		if main and main.line then
			text = text .. " " .. main.line .. "."
		end
		return text
	end

	if topic == "self" then
		return string.format("%s. %s. %s По характеру — %s.",
			brain.full_name or brain.name,
			(brain.personality.occupation or "житель") .. " по призванию",
			brain.backstory or "",
			P.archetype_title(brain.personality))
	end

	if topic == "help" then
		if N.get(brain, "hunger") < 55 then
			return pick(brain, {
				"Если у тебя есть еда — дай мне, пожалуйста. Правый клик с едой в руке.",
				"Я бы не отказался(лась) от яблока или ягод. Нужна еда в руке.",
			})
		end
		if N.get(brain, "social") < 60 then
			return "Мне бывает одиноко. Заглядывай иногда, поговори со мной."
		end
		if brain.knowledge.home then
			return "Если хочешь помочь — просто будь рядом. И не обижай меня, ладно?"
		end
		return pick(brain, {
			"Помоги мне обустроиться. Я пока не нашёл(нашла) дом.",
			"Мне ничего не нужно. Разве что доброе слово.",
			"Если увидишь еду — запомни, где она. Я потом схожу.",
		})
	end

	if topic == "bye" then
		if (rel and (rel.affinity or 0) >= 30) then
			return pick(brain, { "До встречи, друг. Заходи ещё.", "Буду ждать. Береги себя." })
		end
		if (rel and (rel.fear or 0) >= 50) then
			return pick(brain, { "Уходи. И не возвращайся.", "Ладно. Только не подходи близко." })
		end
		return pick(brain, { "До встречи.", "Будь здоров(а).", "Заходи, если что." })
	end

	return "Не знаю, что и сказать."
end

-- Ответ на сообщение в чате. Возвращает { text, insult, follow, stay } или nil.
function T.chat_reply(brain, player_name, message, now)
	local text = U.lower(message or "")
	local player_key = "player:" .. player_name
	local name = U.lower(brain.name or "")
	local mentioned = name ~= "" and text:find(name, 1, true) ~= nil

	local function contains(...)
		for _, needle in ipairs({ ... }) do
			if text:find(needle, 1, true) then return true end
		end
		return false
	end

	if contains("дурак", "глуп", "туп", "ненавиж", "убирайся", "заткнись") then
		return {
			text = pick(brain, {
				"Зачем ты так? Я ведь ничего плохого тебе не сделал(а).",
				"Обидно слышать такое.",
				"Если тебе так проще — говори. Но я запомню.",
			}),
			insult = true,
		}
	end

	if contains("спасибо", "благодар") then
		return {
			text = pick(brain, {
				"Пожалуйста. Мне приятно.",
				"Это тебе спасибо, что помнишь обо мне.",
			}),
			topic = "благодарность",
		}
	end

	if contains("как дела", "как ты", "как настроение", "как сам") then
		return { text = T.answer(brain, player_name, "mood", now, player_key), topic = "настроение" }
	end

	if contains("помн", "вспомн", "запомн") then
		return { text = T.answer(brain, player_name, "memory", now, player_key), topic = "память" }
	end

	if contains("чего", "хочешь", "жела", "мечта") then
		return { text = T.answer(brain, player_name, "wants", now, player_key), topic = "желания" }
	end

	if contains("еда", "поесть", "голод", "яблок", "покорм", "кушать", "есть хочу") then
		if N.get(brain, "hunger") < 60 then
			return {
				text = pick(brain, {
					"Еда? Да, пожалуйста! Просто дай мне её правым кликом.",
					"Я голоден(на). Возьми еду в руку и кликни по мне.",
				}),
				topic = "еда",
			}
		end
		return { text = "Спасибо, я пока сыт(а).", topic = "еда" }
	end

	if contains("кто ты", "как тебя", "имя", "представься") then
		return { text = T.answer(brain, player_name, "self", now, player_key), topic = "знакомство" }
	end

	if contains("иди за мной", "следуй", "пошли", "за мной") then
		if (brain.memory.relationships[player_key] and brain.memory.relationships[player_key].fear or 0) >= 50 then
			return { text = "Нет. Я боюсь идти с тобой.", stay = true }
		end
		return {
			text = pick(brain, { "Хорошо, я рядом.", "Иду за тобой.", "Показывай дорогу." }),
			follow = true,
			topic = "прогулка",
		}
	end

	if contains("стой", "хватит", "останься", "не ходи") then
		return { text = pick(brain, { "Как скажешь. Останусь здесь.", "Ладно, я тут." }), stay = true }
	end

	if contains("дом", "живёшь", "где ты") then
		if brain.knowledge.home then
			return {
				text = pick(brain, { "Мой дом неподалёку. Я помню дорогу.", "Я держусь своего угла — там спокойнее." }),
				topic = "дом",
			}
		end
		return { text = "Дома у меня пока нет. Может, найдётся место?", topic = "дом" }
	end

	if contains("помог", "помощь", "помочь") then
		return { text = T.answer(brain, player_name, "help", now, player_key), topic = "помощь" }
	end

	local said_bye = text == "пока" or text:match("^%s*пока[%s!.,]") ~= nil
		or contains("до свидания", "прощай", "бай")
	if said_bye then
		return { text = T.answer(brain, player_name, "bye", now, player_key), topic = "прощание" }
	end

	if contains("привет", "здравств", "добрый день", "добрый вечер", "хай") or mentioned then
		return { text = T.greeting(brain, player_name, now, player_key), topic = "приветствие" }
	end

	return nil
end

function T.ambient(brain, now)
	local worst, value = N.worst(brain)
	if value <= 25 then
		local lines = {
			hunger = { "Совсем проголодался(лась)...", "Может, кто-нибудь угостит меня?" },
			energy = { "Ноги не держат. Надо поспать.", "Ещё немного — и я усну на ходу." },
			social = { "Как же тихо... и одиноко.", "Хоть бы кто-нибудь зашёл." },
			fun = { "Скучно. Может, прогуляться?", "Хочется хоть какого-то занятия." },
			hygiene = { "Пора помыться.", "Я весь(вся) в пыли." },
			comfort = { "Здесь так неуютно.", "Эх, тепла бы..." },
			safety = { "Мне тревожно. Оглянусь-ка.", "Кажется, за мной кто-то следит." },
		}
		local pool = lines[worst]
		if pool then return pick(brain, pool) end
	end

	if brain.stress >= 70 then
		return pick(brain, { "Всё не так. Всё совсем не так.", "Я больше не могу держать это в себе." })
	end

	if (brain.mood or 50) >= 78 then
		return pick(brain, { "Хороший день, правда?", "Как же хорошо вокруг.", "Я сегодня счастлив(а)." })
	end

	local rel = M.best_friend(brain)
	if rel and (rel.affinity or 0) >= 45 then
		return pick(brain, {
			"Вспоминаю " .. rel.name .. ". Хорошо, когда есть друг.",
			"Надеюсь, " .. rel.name .. " скоро заглянет.",
		})
	end

	local memory = M.recall(brain, now, { limit = 1, min_strength = 1.5 })
	if memory[1] then
		return "Вспомнилось: " .. memory[1].event.text .. "."
	end

	return pick(brain, { "Хм...", "Спокойно вокруг.", "Что бы поделать?" })
end

function T.beg(brain, player_name)
	return pick(brain, {
		string.format("%s, у тебя не найдётся еды? Я совсем голоден(на).", player_name),
		string.format("%s, пожалуйста... дай мне что-нибудь поесть.", player_name),
		"Я не хочу просить, но... может, у тебя есть яблоко?",
	})
end

function T.thanks(brain, player_name, gift_text)
	if gift_text then
		return string.format("Спасибо за %s, %s. Я этого не забуду.", gift_text, player_name)
	end
	return pick(brain, {
		string.format("Спасибо тебе, %s.", player_name),
		"Ты добрый человек. Я запомню это.",
	})
end

function T.attack_response(brain, player_name)
	return pick(brain, {
		"За что?! Я запомню это.",
		"Не надо! Пожалуйста, прекрати!",
		"Ты пожалеешь. Я больше не подойду к тебе.",
	})
end

function T.gift_response(brain, player_name, item_label)
	return pick(brain, {
		string.format("%s! Спасибо, %s.", item_label, player_name),
		"Вот это да. Спасибо тебе!",
		"Как раз то, чего хотелось. Благодарю.",
	})
end

function T.tantrum_line(brain)
	return pick(brain, {
		"Хватит! Я так больше не могу!",
		"Никто меня не слышит...",
		"Оставьте меня все в покое!",
		"Я устал(а) быть один(одна).",
	})
end

function T.talk_line(brain, target_name, now, story)
	if story then
		local memory = M.recall(brain, now, { limit = 1, min_strength = 1.0 })
		if memory[1] then
			return string.format("%s, послушай: %s.", target_name, memory[1].event.text)
		end
	end
	local rel = M.best_friend(brain)
	if rel and rel.name == target_name and (rel.affinity or 0) > 30 then
		return pick(brain, {
			string.format("%s, я рад(а), что ты рядом.", target_name),
			string.format("Как ты, %s? Мне тебя не хватало.", target_name),
		})
	end
	return pick(brain, {
		string.format("Привет, %s. Как ты сегодня?", target_name),
		string.format("%s, есть что нового?", target_name),
		string.format("Хорошо, что встретились, %s.", target_name),
	})
end
