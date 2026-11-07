-- Панель жителя: потребности, память, отношения, характер, желания и разговор.

local UI = {}
smart_npc.ui = UI
local U = smart_npc.util
local N = smart_npc.needs
local M = smart_npc.memory
local D = smart_npc.desires
local P = smart_npc.personality
local T = smart_npc.dialogue
local B = smart_npc.brain
local W = smart_npc.world

local esc = minetest.formspec_escape
local state = {}

local TABS = { "Состояние", "Память", "Желания", "Разговор" }

local function f(value)
	return string.format("%.2f", value)
end

local SKIN_COUNT = 10
local function portrait(skin)
	local index = math.floor(tonumber(skin) or 1)
	index = ((index - 1) % SKIN_COUNT) + 1
	return "npc_portrait_" .. tostring(index) .. ".png"
end

local function bar(x, y, width, height, value, color)
	local filled = U.clamp(value, 0, 100) / 100 * width
	if filled < 0.03 then filled = 0.03 end
	return table.concat({
		string.format("box[%s,%s;%s,%s;#252530]", f(x), f(y), f(width), f(height)),
		string.format("box[%s,%s;%s,%s;%s]", f(x), f(y), f(filled), f(height), color),
	})
end

local function label(x, y, text)
	return string.format("label[%s,%s;%s]", f(x), f(y), esc(text))
end

local function button(x, y, w, h, name, text)
	return string.format("button[%s,%s;%s,%s;%s;%s]", f(x), f(y), f(w), f(h), name, esc(text))
end

local function header(x, y, text)
	return label(x, y, text)
end

local function need_rows(brain)
	local fs = {}
	local y = 2.65
	for _, need in ipairs(N.order) do
		local value = N.get(brain, need)
		fs[#fs + 1] = label(0.5, y, N.label(need))
		fs[#fs + 1] = bar(3.3, y + 0.04, 3.5, 0.4, value, U.color_for_value(value))
		fs[#fs + 1] = label(7.0, y, tostring(U.round(value)))
		y = y + 0.55
	end
	return table.concat(fs)
end

local function mood_block(brain)
	local fs = {}
	local mood = brain.mood or 50
	fs[#fs + 1] = header(0.5, 1.3, "Настроение")
	fs[#fs + 1] = label(2.5, 1.3, string.format("%s — %d из 100", brain.mood_label or "ровно", U.round(mood)))
	fs[#fs + 1] = bar(0.5, 1.65, 6.4, 0.48, mood, U.mood_color(mood, brain.stress))
	fs[#fs + 1] = label(0.5, 2.22, "Стресс " .. U.round(brain.stress or 0) ..
		" · влияние мыслей " .. (brain.thought_bonus and (brain.thought_bonus >= 0 and "+" or "") ..
		U.round(brain.thought_bonus) or "0"))
	return table.concat(fs)
end

local function traits_block(brain)
	local fs = {}
	fs[#fs + 1] = header(0.5, 6.6, "Характер: " .. P.archetype_title(brain.personality))
	local left_x, right_x = 0.5, 6.35
	local left_bar, right_bar = 3.2, 8.55
	local left_y, right_y = 7.0, 7.0
	for index, trait in ipairs(P.trait_order) do
		local value = P.get(brain.personality, trait) * 100
		if index <= 3 then
			fs[#fs + 1] = label(left_x, left_y, P.trait_compact[trait] or trait)
			fs[#fs + 1] = bar(left_bar, left_y + 0.05, 2.9, 0.32, value, "#7f9fd0")
			left_y = left_y + 0.4
		else
			fs[#fs + 1] = label(right_x, right_y, P.trait_compact[trait] or trait)
			fs[#fs + 1] = bar(right_bar, right_y + 0.05, 2.6, 0.32, value, "#7f9fd0")
			right_y = right_y + 0.4
		end
	end
	return table.concat(fs)
end

local function activity_block(brain, entity)
	local fs = {}
	local x = 7.8
	fs[#fs + 1] = header(x, 1.3, "Сейчас")
	fs[#fs + 1] = label(x, 1.7, smart_npc.actions.describe(entity))
	if brain.goal and brain.goal.title then
		fs[#fs + 1] = label(x, 2.08, "Желание: " .. brain.goal.title)
	end
	local desires = D.top(brain, 3)
	fs[#fs + 1] = header(x, 2.6, "Главные желания")
	local dy = 3.0
	if #desires == 0 then
		fs[#fs + 1] = label(x, dy, "Пока ничего особенного")
	else
		for i = 1, #desires do
			local d = desires[i]
			fs[#fs + 1] = label(x, dy, i .. ". " .. d.title)
			fs[#fs + 1] = bar(x, dy + 0.28, 4.0, 0.22, U.clamp(d.utility, 0, 100), "#9c7fd0")
			dy = dy + 0.7
		end
	end
	return table.concat(fs)
end

local function state_tab(brain, entity, player)
	local fs = {
		string.format("box[0.4,0.95;12.2,0.05;#3a3a48]"),
		header(0.5, 1.0, brain.full_name .. " — " .. (brain.personality.occupation or "житель")),
		mood_block(brain),
		need_rows(brain),
		activity_block(brain, entity),
		traits_block(brain),
	}

	local wielded = player:get_wielded_item():get_name()
	local hint = "Возьмите еду в руку и кликните по жителю правым кликом."
	if smart_npc.is_food_item(wielded) then
		hint = "В руке " .. smart_npc.item_label(wielded) .. " — правый клик по жителю угостит его."
	end
	fs[#fs + 1] = label(0.5, 8.5, hint)

	fs[#fs + 1] = button(0.5, 9.0, 2.0, 0.65, "act_talk", "Поговорить")
	fs[#fs + 1] = button(2.65, 9.0, 2.0, 0.65, "act_feed", "Покормить")
	fs[#fs + 1] = button(4.8, 9.0, 1.8, 0.65, "act_hug", "Обнять")
	fs[#fs + 1] = button(6.75, 9.0, 1.9, 0.65, "act_insult", "Оскорбить")
	fs[#fs + 1] = button(8.8, 9.0, 1.9, 0.65, "act_follow", "Идти следом")
	fs[#fs + 1] = button(10.85, 9.0, 1.7, 0.65, "act_close", "Закрыть")
	return table.concat(fs)
end

local function memory_tab(brain, entity, player)
	local now = W.now()
	local fs = {
		header(0.5, 1.0, "Память жителя"),
		label(0.5, 1.4, "Сильные воспоминания держатся дольше. Свежие влияют на настроение."),
		header(0.5, 1.85, "Что помнит"),
	}

	local rows = {}
	for i, line in ipairs(M.summary(brain, now, 12)) do
		rows[i] = string.format("%s,%s,%s", line.color, U.formspec_safe(line.text),
			U.formspec_safe(U.format_age(line.age)))
	end
	if #rows == 0 then
		rows[1] = "#9e9e9e,Пока ничего не произошло,только что"
	end
	fs[#fs + 1] = "tablecolumns[color;text;text]"
	fs[#fs + 1] = string.format("table[0.4,2.15;7.9,3.7;memories;%s;1]", table.concat(rows, ","))

	header(8.5, 1.85, "Отношения")
	local relations = M.relationships_sorted(brain)
	local rrows = {}
	for i = 1, math.min(#relations, 10) do
		local rel = relations[i]
		rrows[i] = string.format("%s,%s", M.relation_color(rel),
			U.formspec_safe(rel.name .. " — " .. M.relation_label(rel)))
	end
	if #rrows == 0 then
		rrows[1] = "#9e9e9e,Пока никого не знает"
	end
	fs[#fs + 1] = "tablecolumns[color;text]"
	fs[#fs + 1] = string.format("table[8.4,2.15;4.2,3.7;relations;%s;1]", table.concat(rrows, ","))

	local top = M.recall(brain, now, { limit = 3 })
	if top[1] then
		local y = 6.2
		header(0.5, y, "Самое важное воспоминание")
		y = y + 0.45
		for _, line in ipairs(U.wrap(top[1].event.text .. " (" .. U.format_age(now - top[1].event.time) .. ")", 60)) do
			fs[#fs + 1] = label(0.5, y, line)
			y = y + 0.4
		end
	end

	local rel = brain.memory.relationships["player:" .. player:get_player_name()]
	if rel then
		local y = 7.8
		fs[#fs + 1] = header(0.5, y, "К вам лично")
		fs[#fs + 1] = label(0.5, y + 0.42, string.format("%s · привязанность %d · доверие %d · страх %d",
			M.relation_label(rel), U.round(rel.affinity or 0), U.round(rel.trust or 0), U.round(rel.fear or 0)))
		fs[#fs + 1] = label(0.5, y + 0.82, string.format("Разговоров: %d · подарков: %d · обид: %d",
			rel.talks or 0, rel.gifts or 0, rel.hurts or 0))
	else
		fs[#fs + 1] = label(0.5, 7.8, "Он(а) пока не запомнил(а) вас.")
	end

	fs[#fs + 1] = button(0.5, 9.0, 2.0, 0.65, "act_talk", "Поговорить")
	fs[#fs + 1] = button(2.65, 9.0, 2.0, 0.65, "act_close", "Закрыть")
	return table.concat(fs)
end

local function desires_tab(brain, entity, player)
	local fs = {
		header(0.5, 1.0, "Желания и характер"),
		label(0.5, 1.4, "Желания возникают из потребностей, привычек, памяти и отношений."),
	}
	local desires = D.top(brain, 5)
	local y = 1.9
	for _, d in ipairs(desires) do
		local source = d.source == "need" and "потребность" or (d.source == "whim" and "настроение" or "событие")
		fs[#fs + 1] = label(0.5, y, string.format("%s (%s)", d.title, source))
		fs[#fs + 1] = bar(5.4, y + 0.05, 3.4, 0.4, U.clamp(d.utility, 0, 100), d.fear and "#b06cd9" or "#9c7fd0")
		y = y + 0.58
	end
	if #desires == 0 then
		fs[#fs + 1] = label(0.5, y, "Пока житель доволен и ни к чему не стремится.")
	end

	header(0.5, 5.85, "Прошлое и хозяйство")
	local y = 6.2
	for index, line in ipairs(U.wrap(brain.backstory or "", 82)) do
		if index > 4 then break end
		fs[#fs + 1] = label(0.5, y, line)
		y = y + 0.36
	end
	local stats_y = math.max(7.0, y + 0.1)
	fs[#fs + 1] = label(0.5, stats_y, string.format("Дом: %s · припасено еды: %d · знакомых мест: %d",
		brain.knowledge.home and "есть" or "нет",
		brain.carry.food or 0,
		#(brain.knowledge.spots or {})))
	fs[#fs + 1] = label(0.5, stats_y + 0.4, string.format("Прожито: %s · еды: %d · снов: %d · разговоров: %d · подарков: %d",
		U.format_duration(W.now() - (brain.stats.spawned_at or W.now())),
		brain.stats.meals or 0, brain.stats.naps or 0, brain.stats.chats or 0, brain.stats.gifts or 0))
	fs[#fs + 1] = label(0.5, stats_y + 0.8, string.format("Исполнено желаний: %d · истерик: %d · обид: %d",
		brain.stats.desires_done or 0, brain.stats.tantrums or 0, brain.stats.hurts or 0))

	fs[#fs + 1] = button(0.5, 9.0, 2.2, 0.65, "act_home", "Дом здесь")
	fs[#fs + 1] = button(2.85, 9.0, 2.0, 0.65, "act_follow", "Позвать")
	fs[#fs + 1] = button(5.0, 9.0, 2.0, 0.65, "act_stay", "Остаться")
	fs[#fs + 1] = button(7.15, 9.0, 2.0, 0.65, "act_close", "Закрыть")
	return table.concat(fs)
end

local function dialogue_tab(brain, entity, player)
	local name = player:get_player_name()
	local st = state[name] or {}
	local answer = st.answer or ""
	local fs = {
		header(0.5, 1.0, "Разговор с " .. brain.name),
		string.format("image[0.5,1.45;2,2;%s]", portrait(brain.skin)),
		label(2.8, 1.5, string.format("%s, %d %s", brain.full_name, brain.age or 30,
			U.plural(brain.age or 30, "год", "года", "лет"))),
		label(2.8, 1.9, (brain.personality.occupation or "житель") .. " · " .. P.archetype_title(brain.personality)),
		label(2.8, 2.3, "Настроение: " .. (brain.mood_label or "ровно")),
		label(2.8, 2.7, "Отношение к вам: " .. M.relation_label(brain.memory.relationships["player:" .. name])),
	}

	local y = 3.7
	if answer == "" then
		answer = T.greeting(brain, name, W.now())
	end
	for _, line in ipairs(U.wrap(answer, 74)) do
		fs[#fs + 1] = label(0.5, y, line)
		y = y + 0.42
	end

	local topics = T.topics
	local x = 0.5
	local row = 6.4
	for i, topic in ipairs(topics) do
		fs[#fs + 1] = button(x, row, 1.75, 0.6, "topic_" .. topic.id, topic.title)
		x = x + 1.82
		if i == 6 then
			x = 0.5
			row = 7.15
		end
	end

	fs[#fs + 1] = label(0.5, 8.0, "Правый клик с едой в руке — угостить. Удар запомнится надолго.")
	fs[#fs + 1] = button(0.5, 9.0, 2.0, 0.65, "act_feed", "Покормить")
	fs[#fs + 1] = button(2.65, 9.0, 2.0, 0.65, "act_talk", "Ещё раз")
	fs[#fs + 1] = button(4.8, 9.0, 2.0, 0.65, "act_close", "Закрыть")
	return table.concat(fs)
end

function UI.show(player, entity, tab, answer)
	if not player or not entity or not entity._brain then return end
	local name = player:get_player_name()
	local brain = entity._brain
	tab = U.clamp(tab or 1, 1, #TABS)

	local st = state[name] or {}
	st.entity_id = brain.id
	st.tab = tab
	if answer ~= nil then st.answer = answer end
	state[name] = st

	local fs = {
		"formspec_version[4]",
		"size[13,10]",
		"bgcolor[#111116CC;true]",
		string.format("tabheader[0.4,0.25;npc_tabs;%s;%d;false;false]", table.concat(TABS, ","), tab),
	}

	if tab == 1 then
		fs[#fs + 1] = state_tab(brain, entity, player)
	elseif tab == 2 then
		fs[#fs + 1] = memory_tab(brain, entity, player)
	elseif tab == 3 then
		fs[#fs + 1] = desires_tab(brain, entity, player)
	else
		fs[#fs + 1] = dialogue_tab(brain, entity, player)
	end

	minetest.show_formspec(name, "smart_npc:panel", table.concat(fs))
end

function UI.get_entity(player_name)
	local st = state[player_name]
	if not st or not st.entity_id then return nil end
	local entity = smart_npc.active[st.entity_id]
	if not entity or not entity.object or not entity._brain then return nil end
	return entity
end

function UI.set_answer(player_name, text)
	local st = state[player_name]
	if st then st.answer = text end
end

function UI.forget(player_name)
	state[player_name] = nil
end

local function greet_answer(brain, player_name, now, st)
	local text = T.greeting(brain, player_name, now)
	if not st or now - (st.last_greet or 0) > 20 then
		if st then st.last_greet = now end
		B.converse(brain, "player:" .. player_name, player_name, now, "приветствие", { gain = 6 })
	end
	return text
end

function UI.handle_fields(player, formname, fields)
	if formname ~= "smart_npc:panel" then return false end
	local name = player:get_player_name()
	local entity = UI.get_entity(name)
	if not entity then
		state[name] = nil
		minetest.close_formspec(name, "smart_npc:panel")
		return true
	end
	local brain = entity._brain
	local now = W.now()
	local st = state[name] or {}
	state[name] = st

	local function refresh(answer, tab)
		UI.show(player, entity, tab or st.tab or 1, answer)
	end

	if fields.npc_tabs then
		local tab = tonumber(fields.npc_tabs) or 1
		st.tab = U.clamp(tab, 1, #TABS)
		if st.tab == 4 then
			st.answer = greet_answer(brain, name, now, st)
		end
		refresh(st.answer, st.tab)
		return true
	end

	if fields.act_close then
		minetest.close_formspec(name, "smart_npc:panel")
		state[name] = nil
		return true
	end

	local topic
	for _, t in ipairs(T.topics) do
		if fields["topic_" .. t.id] then topic = t.id break end
	end

	if topic then
		st.topic_cooldowns = st.topic_cooldowns or {}
		if (st.topic_cooldowns[topic] or 0) > now then
			st.tab = 4
			refresh("Мы только что об этом говорили. Давай сменим тему.", 4)
			return true
		end
		st.topic_cooldowns[topic] = now + 6
		local answer = T.answer(brain, name, topic, now)
		if topic ~= "greet" and topic ~= "bye" then
			B.converse(brain, "player:" .. name, name, now, topic, { gain = 7 })
		end
		st.tab = 4
		refresh(answer, 4)
		return true
	end

	if fields.act_talk then
		st.tab = 4
		refresh(greet_answer(brain, name, now, st), 4)
		return true
	end

	if fields.act_feed then
		local answer = smart_npc.give_food(player, entity)
		st.tab = 4
		refresh(answer, 4)
		return true
	end

	if fields.act_hug then
		local rel = M.relationship(brain, "player:" .. name, name)
		local answer
		if (rel.fear or 0) >= 45 then
			answer = "Не надо... Мне всё ещё страшно рядом с тобой. Сначала помиримся."
		else
			B.hugged_by(brain, "player:" .. name, name, now)
			W.particles(entity.object:get_pos(), "npc_heart.png", 5, 0.5, 1.9)
			answer = U.pick(U.new_rng(U.hash(brain.id .. tostring(math.floor(now)))), {
				"Спасибо. Мне стало теплее на душе.",
				"Как приятно! Я это запомню.",
				"Вот это по-дружески.",
			})
		end
		st.tab = 4
		refresh(answer, 4)
		return true
	end

	if fields.act_insult then
		B.insulted_by(brain, "player:" .. name, name, now)
		W.particles(entity.object:get_pos(), "npc_anger.png", 6, 0.5, 1.9)
		st.tab = 4
		refresh("Зачем ты так? Я запомню это надолго.", 4)
		return true
	end

	if fields.act_follow then
		local key = "player:" .. name
		local rel = M.relationship(brain, key, name)
		if (rel.fear or 0) >= 50 then
			st.tab = 4
			refresh("Нет. Я боюсь идти с тобой. Сначала нужно помириться.", 4)
			return true
		end
		local desire = D.find(brain, "reaction:follow:" .. name)
		if not desire then
			D.add(brain, {
				id = "reaction:follow:" .. name,
				action = "follow",
				title = "Идти за " .. name,
				line = "Меня позвали",
				target = key,
				utility = 85,
				ttl = 120,
			}, now)
		end
		-- Не ждём следующего тика мозга: просьба выполняется сразу.
		B.set_custom_goal(brain, "follow", "Идти за " .. name, now, { target = key })
		st.tab = 4
		refresh("Хорошо, я пойду за тобой.", 4)
		return true
	end

	if fields.act_stay then
		B.drop_follow_desires(brain)
		brain.flags.following = nil
		brain.goal = nil
		B.set_home(brain, entity.object:get_pos())
		W.say(entity, "Ладно, останусь здесь. Это место мне нравится.", true)
		st.tab = 3
		refresh("Ладно, останусь здесь. Это место мне нравится.", 3)
		return true
	end

	if fields.act_home then
		B.set_home(brain, entity.object:get_pos())
		W.say(entity, "Теперь я знаю, где мой дом.", true)
		st.tab = 3
		refresh("Теперь я знаю, где мой дом.", 3)
		return true
	end

	return true
end

function UI.message(player, text)
	minetest.chat_send_player(player:get_player_name(), minetest.colorize("#9fd3ff", "[Житель] ") .. text)
end
