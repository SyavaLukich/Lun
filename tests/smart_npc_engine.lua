-- Интеграционные тесты мода smart_npc на заглушке Luanti.
-- Проверяют регистрацию, сущность, панель, команды, чат и сохранение.
-- Запуск из корня репозитория:
--     lua tests/smart_npc_engine.lua

local root = os.getenv("SMART_NPC_PATH") or "mods/smart_npc"
math.randomseed(12345)
local stub = dofile("tests/lun_stub.lua")

local checks = 0
local failures = {}
local tests_run = 0

local function fail(message, level)
	error(message, (level or 2) + 1)
end

local function check(value, message)
	checks = checks + 1
	if not value then fail(message or "проверка не прошла") end
end

local function check_equal(actual, expected, message)
	checks = checks + 1
	if actual ~= expected then
		fail(string.format("%s: получено %s, ожидалось %s",
			message or "сравнение", tostring(actual), tostring(expected)))
	end
end

local function check_string(value, message)
	checks = checks + 1
	if type(value) ~= "string" or #value == 0 then
		fail((message or "ожидалась строка") .. ": " .. tostring(value))
	end
end

local function run(name, func)
	tests_run = tests_run + 1
	local ok, err = pcall(func)
	if ok then
		print("  ✓ " .. name)
	else
		print("  ✗ " .. name .. "\n      " .. tostring(err))
		failures[#failures + 1] = { name = name, err = err }
	end
end

-- ===========================================================================
-- Загрузка мода
-- ===========================================================================
local chunk = assert(loadfile(root .. "/init.lua"))
chunk()
stub.run_mods_loaded()

local smart_npc = assert(_G.smart_npc, "мод не создал пространство имён")
local U = smart_npc.util
local B = smart_npc.brain
local N = smart_npc.needs
local M = smart_npc.memory
local W = smart_npc.world
local UI = smart_npc.ui
local def = assert(stub.registered_entities["smart_npc:npc"], "сущность не зарегистрирована")

local function entities()
	local list = {}
	for _, entity in pairs(smart_npc.active) do list[#list + 1] = entity end
	table.sort(list, function(a, b) return a._brain.id < b._brain.id end)
	return list
end

local function first_entity()
	return entities()[1]
end

local player = stub.add_player("Тестер", { x = 0.5, y = 1, z = 0.5 })

local function nearest_entity()
	return smart_npc.nearest(player:get_pos(), 14)
end
stub.join_player(player)
stub.advance(4)

-- ===========================================================================
-- Тесты
-- ===========================================================================
run("регистрация мода", function()
	check_equal(stub.settings_values["smart_npc.auto_reply"], nil)
	check(stub.registered_craftitems["smart_npc:spawner"] ~= nil, "предмет-призыватель есть")
	check(stub.chatcommands["npc"] ~= nil, "команда /npc есть")
	check(#stub.formspecs == 0, "панель не открывалась сама")
	check(def.on_rightclick ~= nil, "обработчик правого клика зарегистрирован")
	check(def.on_right_click == nil, "не используется устаревшее имя on_right_click")
	check(#smart_npc.food_nodes >= 1, "список еды собран")
	check(#smart_npc.water_nodes >= 1, "список воды собран")
	check(#smart_npc.interesting_nodes >= 1, "список интересных блоков собран")
end)

run("автопоявление жителей", function()
	check_equal(smart_npc.count(), 2, "появилось два жителя")
	for id, entity in pairs(smart_npc.active) do
		check(entity.object ~= nil, "у жителя есть объект")
		check(entity._brain ~= nil, "у жителя есть мозг")
		check(entity._brain.id == id, "ключ реестра совпадает с id")
		check(type(entity._brain.full_name) == "string", "имя задано")
		check_equal(entity.object.armor_groups.immortal, 1, "житель неуязвим")
		check_string(entity.object.props.infotext)
	end
end)

run("опора определяется по блоку под ногами", function()
	stub.set_node(20, 0, 20, "default:stone")
	check(W.is_grounded({ x = 20.5, y = 1, z = 20.5 }), "на блоке есть опора")
	check(not W.is_grounded({ x = 20.5, y = 4, z = 20.5 }), "в воздухе опоры нет")
	check(not W.is_grounded(nil), "без позиции опоры нет")
end)

run("повтор id при загрузке не вытесняет жителя", function()
	local first, second = entities()[1], entities()[2]
	local old_id = second._brain.id
	local first_id = first._brain.id
	check(first ~= nil and second ~= nil, "есть два жителя")
	smart_npc.active[old_id] = nil
	second._brain.id = first_id
	smart_npc.setup(second, second._brain)
	check(second._brain.id ~= first_id, "копии выдан новый id")
	check(smart_npc.active[first_id] == first, "первый житель остался в реестре")
	check(smart_npc.active[second._brain.id] == second, "второй житель в реестре под новым id")
	-- Возвращаем исходное состояние для следующих тестов.
	smart_npc.active[second._brain.id] = nil
	second._brain.id = old_id
	smart_npc.active[old_id] = second
end)

run("длительная жизнь на платформе", function()
	-- Немного еды рядом, чтобы жители находили её и ели.
	stub.set_node(4, 1, 2, "default:apple")
	stub.set_node(-3, 1, 3, "default:apple")
	local errors = {}
	local steps = 2400 -- 8 минут модельного времени
	for i = 1, steps do
		stub.advance(0.2)
		local ok, err = pcall(stub.step_all, 0.2)
		if not ok then
			errors[#errors + 1] = tostring(err)
			break
		end
		if i % 100 == 0 then
			stub.set_node(math.random(-8, 8), 1, math.random(-8, 8), "default:apple")
		end
	end
	check_equal(#errors, 0, "ошибок при симуляции нет: " .. table.concat(errors, " | "))

	check_equal(smart_npc.count(), 2, "жители не пропали")
	local meals, chats, naps, memories, moods = 0, 0, 0, 0, {}
	for _, entity in pairs(smart_npc.active) do
		local brain = entity._brain
		meals = meals + (brain.stats.meals or 0)
		chats = chats + (brain.stats.chats or 0)
		naps = naps + (brain.stats.naps or 0)
		memories = memories + #brain.memory.events
		moods[#moods + 1] = brain.mood
		for _, need in ipairs(N.order) do
			local value = N.get(brain, need)
			check(value >= 0 and value <= 100, "потребность " .. need .. " в диапазоне")
		end
		check(brain.mood >= 0 and brain.mood <= 100, "настроение в диапазоне")
		check(brain.stress >= 0 and brain.stress <= 100, "стресс в диапазоне")
		check(#brain.desires <= 12, "желания не распухли")
		check(brain.goal ~= nil or #brain.desires > 0, "у жителя есть занятие или желание")
	end
	check(meals > 0, "жители хотя бы раз поели (еда: " .. meals .. ")")
	check(memories > 0, "воспоминания появились")
	check(#moods == 2, "настроения посчитаны")
end)

run("кадры анимации в пределах модели", function()
	local path = root .. "/models/npc.b3d"
	local file = assert(io.open(path, "rb"), "модель на месте")
	local data = file:read("*a")
	file:close()
	local pos = data:find("ANIM", 1, true)
	check(pos ~= nil, "в модели есть блок ANIM")
	local b1, b2, b3, b4 = data:byte(pos + 12, pos + 15)
	local frames = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	check(frames > 0, "кадры посчитаны: " .. tostring(frames))
	for name, range in pairs(smart_npc.world.animations) do
		check(range.x >= 0 and range.y >= range.x, "диапазон " .. name .. " корректен")
		check(range.y < frames, "кадры " .. name .. " есть в модели (" .. range.x .. ".." .. range.y .. " из " .. frames .. ")")
	end
end)

run("панель: все вкладки", function()
	local entity = first_entity()
	local before = #stub.formspecs
	for tab = 1, 4 do
		UI.show(player, entity, tab)
		check(#stub.formspecs > before, "панель показана")
		local formspec = stub.formspecs[#stub.formspecs].formspec
		check_string(formspec, "формспека не пустая")
		check(formspec:find("formspec_version", 1, true), "версия формспеки указана")
		check(formspec:find("tabheader", 1, true), "вкладки есть")
		check(#formspec < 60000, "форма не раздулась")
	end

	stub.receive_fields(player, "smart_npc:panel", { npc_tabs = "2" })
	stub.receive_fields(player, "smart_npc:panel", { npc_tabs = "3" })
	stub.receive_fields(player, "smart_npc:panel", { npc_tabs = "4" })
	check(#stub.formspecs > before, "переключение вкладок работает")

	-- Некорректный номер скина не должен ломать ссылку на портрет.
	local skin = entity._brain.skin
	entity._brain.skin = 0
	UI.show(player, entity, 4)
	check(stub.formspecs[#stub.formspecs].formspec:find("npc_portrait_10.png", 1, true) ~= nil,
		"нулевой скин показывается как десятый портрет")
	entity._brain.skin = skin
end)

run("разговор через панель", function()
	local failures_before = #failures
	local entity = first_entity()
	UI.show(player, entity, 4)
	local social_before = N.get(entity._brain, "social")
	stub.receive_fields(player, "smart_npc:panel", { topic_mood = true })
	check(N.get(entity._brain, "social") >= social_before, "разговор поднял общение")
	check(#entity._brain.memory.events > 0, "разговор запомнен")

	stub.receive_fields(player, "smart_npc:panel", { topic_memory = true })
	stub.receive_fields(player, "smart_npc:panel", { topic_wants = true })
	stub.receive_fields(player, "smart_npc:panel", { topic_self = true })
	stub.receive_fields(player, "smart_npc:panel", { topic_help = true })
	stub.receive_fields(player, "smart_npc:panel", { topic_greet = true })
	stub.receive_fields(player, "smart_npc:panel", { topic_bye = true })
	check_equal(#failures, failures_before, "вопросы не вызвали ошибок")
end)

run("просьба идти следом", function()
	local entity = first_entity()
	local brain = entity._brain
	brain.goal = nil
	UI.show(player, entity, 4, "")
	stub.receive_fields(player, "smart_npc:panel", { act_follow = true })
	check(brain.goal ~= nil and brain.goal.action == "follow", "цель «идти следом» поставлена сразу")
	stub.advance(0.4)
	stub.step_all(0.2)
	check_equal(brain.flags.following, "player:Тестер", "житель взял игрока под опеку")
	for _ = 1, 10 do
		stub.advance(0.2)
		stub.step_all(0.2)
	end
	check(brain.goal ~= nil and brain.goal.action == "follow", "просьба идти следом не рассыпалась за 2 секунды")

	brain.goal = nil
	brain.memory.relationships["player:Тестер"].fear = 60
	UI.show(player, entity, 4, "")
	stub.receive_fields(player, "smart_npc:panel", { act_follow = true })
	check(brain.goal == nil or brain.goal.action ~= "follow", "испуганный житель отказывается идти")
	brain.memory.relationships["player:Тестер"].fear = 0
	for i = #brain.desires, 1, -1 do
		if brain.desires[i].action == "follow" then table.remove(brain.desires, i) end
	end
	brain.goal = nil
	brain.flags.following = nil
	entity._action = nil
	W.stop(entity)
end)

run("житель сам начинает разговор", function()
	local entity = first_entity()
	local brain = entity._brain
	local old_pos = player:get_pos()
	local epos = entity.object:get_pos()
	player:set_pos({ x = epos.x + 1, y = epos.y, z = epos.z })
	brain.last_context = W.scan(entity, brain, W.now())
	entity._action = nil
	brain.goal = {
		desire_id = "test:talk",
		action = "talk",
		title = "Поговорить",
		target = "player:Тестер",
		story = true,
		started = W.now(),
		special = true,
	}
	local chats_before = brain.stats.chats or 0
	smart_npc.actions.tick(entity, 0.2)
	check(entity._action ~= nil and entity._action.story == true, "флаг истории дошёл до действия")
	for _ = 1, 30 do smart_npc.actions.tick(entity, 0.2) end
	check((brain.stats.chats or 0) > chats_before, "житель поговорил по своей инициативе")
	brain.goal = nil
	smart_npc.actions.stop(entity)
	player:set_pos(old_pos)
end)

run("испуганный житель не идёт разговаривать", function()
	local entity = first_entity()
	local brain = entity._brain
	local key = "player:Тестер"
	local old_pos = player:get_pos()
	local epos = entity.object:get_pos()
	player:set_pos({ x = epos.x + 1, y = epos.y, z = epos.z })
	local rel = brain.memory.relationships[key] or M.relationship(brain, key)
	local saved_fear = rel.fear
	rel.fear = 60
	brain.last_context = W.scan(entity, brain, W.now())
	brain.goal = {
		desire_id = "test:fear_talk",
		action = "talk",
		title = "Поговорить",
		target = key,
		started = W.now(),
		special = true,
	}
	entity._action = nil
	smart_npc.actions.tick(entity, 0.2)
	check(entity._action == nil, "разговор с обидчиком не начался")
	brain.goal = nil
	rel.fear = saved_fear
	W.stop(entity)
	player:set_pos(old_pos)
end)

run("все действия запускаются", function()
	local entity = first_entity()
	local brain = entity._brain
	local old_pos = player:get_pos()
	local epos = entity.object:get_pos()
	player:set_pos({ x = epos.x + 1.5, y = epos.y, z = epos.z })
	brain.paused = false
	brain.last_context = W.scan(entity, brain, W.now())
	local failed = {}
	for name in pairs(smart_npc.actions.registry) do
		entity._action = nil
		brain.goal = {
			desire_id = "test:" .. name,
			action = name,
			title = name,
			target = "player:Тестер",
			target_pos = { x = epos.x + 1.5, y = epos.y, z = epos.z },
			started = W.now(),
			special = true,
		}
		local ok, err = pcall(function()
			for _ = 1, 8 do smart_npc.actions.tick(entity, 0.2) end
		end)
		if not ok then failed[#failed + 1] = name .. ": " .. tostring(err) end
		brain.goal = nil
		smart_npc.actions.stop(entity)
		brain.flags.following = nil
	end
	check_equal(#failed, 0, "ошибки действий: " .. table.concat(failed, " | "))
	player:set_pos(old_pos)
end)

run("сон восстанавливает силы", function()
	local entity = first_entity()
	local brain = entity._brain
	local old_energy, old_comfort = N.get(brain, "energy"), N.get(brain, "comfort")
	brain.needs.energy = 10
	entity._action = nil
	brain.last_context = W.scan(entity, brain, W.now())
	brain.goal = {
		desire_id = "test:sleep",
		action = "sleep",
		title = "Поспать",
		started = W.now(),
		special = true,
	}
	for _ = 1, 200 do smart_npc.actions.tick(entity, 0.2) end
	check(N.get(brain, "energy") > 30, "сон заметно восстанавливает бодрость")
	check((brain.stats.naps or 0) > 0 or entity._action == nil, "сон завершился")
	brain.goal = nil
	smart_npc.actions.stop(entity)
	brain.needs.energy, brain.needs.comfort = old_energy, old_comfort
end)

run("угощение едой", function()
	local entity = first_entity()
	player.wielded = stub.new_stack("default:apple", 5)
	local hunger_before = N.get(entity._brain, "hunger")
	local answer = smart_npc.give_food(player, entity)
	check_string(answer, "есть ответ")
	check(entity._brain.carry.food >= 1, "еда попала в припасы")
	check(entity._brain.stats.gifts >= 1, "подарок учтён")
	local rel = entity._brain.memory.relationships["player:Тестер"]
	check(rel ~= nil and rel.affinity > 0, "отношение улучшилось")
	check(N.get(entity._brain, "hunger") >= hunger_before, "голод немного утолён")

	local entity2 = entities()[2]
	local carry_before = entity2._brain.carry.food or 0
	player.wielded = stub.new_stack("default:dirt", 1)
	smart_npc.give_food(player, entity2)
	check_equal(entity2._brain.carry.food or 0, carry_before, "несъедобное не принимается")
end)

run("правый клик и панель", function()
	local entity = first_entity()
	player.wielded = stub.new_stack("", 0)
	local before = #stub.formspecs
	local result = def.on_rightclick(entity, player)
	check(#stub.formspecs > before, "правый клик открыл панель")
	check_string(stub.formspecs[#stub.formspecs].formspec)

	local gift_entity = entities()[2]
	local carry_before = gift_entity._brain.carry.food or 0
	player.wielded = stub.new_stack("default:apple", 2)
	local gift_answer = def.on_rightclick(gift_entity, player)
	check(gift_answer ~= nil, "правый клик с едой обработан")
	check((gift_entity._brain.carry.food or 0) > carry_before, "еда принята")
end)

run("удар запоминается", function()
	local entity = first_entity()
	local brain = entity._brain
	local before_hurts = brain.stats.hurts or 0
	def.on_punch(entity, player, 1, {}, { x = 0, y = 0, z = 1 }, 4)
	check((brain.stats.hurts or 0) > before_hurts, "удар учтён")
	check(brain.stress > 0, "стресс вырос")
	local rel = brain.memory.relationships["player:Тестер"]
	check(rel and rel.fear > 0, "страх перед обидчиком")
	local spec = stub.particlespawners[#stub.particlespawners]
	check(spec and type(spec.glow) == "number", "glow частиц — число")
	local avoid = false
	for _, desire in ipairs(brain.desires) do
		if desire.action == "avoid" then avoid = true end
	end
	check(avoid, "появилось желание сторониться")
end)

run("чат с жителем", function()
	local entity = nearest_entity()
	local brain = entity._brain
	local before = brain.stats.chats or 0
	local handled = stub.chat("Тестер", "привет")
	check_equal(handled, false, "чат не подавляется модом")
	check_string(stub.messages[#stub.messages].message)
	check((brain.stats.chats or 0) > before, "разговор записан")

	stub.chat("Тестер", "иди за мной")
	local follow = false
	for _, desire in ipairs(brain.desires) do
		if desire.action == "follow" then follow = true end
	end
	check(follow, "просьба идти следом создаёт желание")

	-- Грубость должна испортить отношения.
	local trust_before = (brain.memory.relationships["player:Тестер"] or {}).trust or 0
	stub.chat("Тестер", "ты дурак")
	local rel = brain.memory.relationships["player:Тестер"]
	check((rel.affinity or 0) < 0 or (rel.hurts or 0) > 0, "грубость испортила отношение")
	check((rel.trust or 0) <= trust_before, "доверие не выросло")
end)

run("панель: объятие, грубость и дом", function()
	local entity = entities()[2]
	local brain = entity._brain
	local key = "player:Тестер"
	local saved_rel = brain.memory.relationships[key]
	local saved_home = brain.knowledge.home
	local saved_hurts = brain.stats.hurts
	local saved_stress = brain.stress
	brain.memory.relationships[key] = nil

	UI.show(player, entity, 4)
	stub.receive_fields(player, "smart_npc:panel", { act_hug = true })
	local rel = brain.memory.relationships[key]
	check(rel ~= nil, "объятие создало отношение")
	check((rel.affinity or 0) > 0, "объятие повысило привязанность")
	check((rel.trust or 0) > 0, "объятие повысило доверие")
	check((rel.fear or 0) == 0, "объятие не пугает")

	local affinity_after_hug = rel.affinity
	rel.fear = 60
	UI.show(player, entity, 4)
	stub.receive_fields(player, "smart_npc:panel", { act_hug = true })
	check(rel.affinity <= affinity_after_hug, "испуганный житель не тает от объятия")

	rel.fear = 0
	local hurts_before = brain.stats.hurts or 0
	UI.show(player, entity, 4)
	stub.receive_fields(player, "smart_npc:panel", { act_insult = true })
	check((brain.stats.hurts or 0) > hurts_before, "оскорбление учтено")
	check((rel.hurts or 0) > 0, "обида записана в отношения")
	check((rel.affinity or 0) < affinity_after_hug, "оскорбление испортило привязанность")

	UI.show(player, entity, 3)
	stub.receive_fields(player, "smart_npc:panel", { act_home = true })
	check(brain.knowledge.home ~= nil, "кнопка «Дом здесь» ставит дом")

	brain.flags.following = key
	brain.goal = { desire_id = "test:stay", action = "follow", title = "Идти", target = key, special = true, started = W.now() }
	stub.receive_fields(player, "smart_npc:panel", { act_stay = true })
	check(brain.flags.following == nil, "кнопка «Остаться» снимает слежку")
	check(brain.goal == nil, "кнопка «Остаться» снимает цель")

	brain.memory.relationships[key] = saved_rel
	brain.knowledge.home = saved_home
	brain.stats.hurts = saved_hurts
	brain.stress = saved_stress
	for i = #brain.desires, 1, -1 do
		if brain.desires[i].id == "reaction:avoid:" .. key then table.remove(brain.desires, i) end
	end
	brain.goal = nil
	brain.flags.following = nil
	smart_npc.ui.forget(player:get_player_name())
end)

run("команды /npc", function()
	local ok, message = stub.command("Тестер", "npc list")
	check(ok, "list работает")
	check_string(message)

	ok, message = stub.command("Тестер", "npc info")
	check(ok, "info работает")
	check_string(message)

	ok, message = stub.command("Тестер", "npc panel")
	check(ok, "panel работает")

	player.wielded = stub.new_stack("", 0)
	ok, message = stub.command("Тестер", "npc feed")
	check(ok, "feed работает")

	ok, message = stub.command("Тестер", "npc home")
	check(ok, "home работает")

	ok, message = stub.command("Тестер", "npc calm")
	check(ok, "calm работает")

	ok, message = stub.command("Тестер", "npc freeze")
	check(ok, "freeze работает")
	ok, message = stub.command("Тестер", "npc freeze")
	check(ok, "freeze снимается")

	local before = smart_npc.count()
	ok, message = stub.command("Тестер", "npc spawn")
	check(ok, "spawn работает")
	check_equal(smart_npc.count(), before + 1, "новый житель появился")

	ok, message = stub.command("Тестер", "npc remove")
	check(ok, "remove работает")
	check_equal(smart_npc.count(), before, "житель удалён")

	ok, message = stub.command("Тестер", "npc spawn Мира")
	check(ok, "spawn с именем работает")
	check_equal(smart_npc.count(), before + 1, "именованный житель появился")
	local named = false
	for _, entity in pairs(smart_npc.active) do
		if entity._brain and entity._brain.name == "Мира" then named = true end
	end
	check(named, "имя сохранено")

	ok, message = stub.command("Тестер", "npc remove")
	check(ok, "remove работает")
	check_equal(smart_npc.count(), before, "житель удалён")

	ok, message = stub.command("Тестер", "npc help")
	check(ok, "help работает")
end)

run("предмет-призыватель", function()
	local item = stub.registered_craftitems["smart_npc:spawner"]
	check(item ~= nil, "предмет есть")
	local before = smart_npc.count()
	local stack = stub.new_stack("smart_npc:spawner", 1)
	local result = item.on_use(stack, player, { type = "node", above = { x = 1, y = 1, z = 1 } })
	check(result ~= nil, "on_use вернул предмет")
	check_equal(smart_npc.count(), before + 1, "предмет создал жителя")
end)

run("ошибки появления", function()
	local entity, err = smart_npc.spawn({ x = 100, y = 6, z = 100 }, {})
	check(entity == nil, "в пустоте житель не появляется")
	check_equal(err, "no_ground", "причина — нет земли")

	local before = #stub.messages
	local item = stub.registered_craftitems["smart_npc:spawner"]
	local stack = stub.new_stack("smart_npc:spawner", 1)
	local ok = pcall(item.on_use, stack, player, { type = "node", above = { x = 100, y = 6, z = 100 } })
	check(ok, "неудачное появление не ломает предмет")
	check(#stub.messages > before, "игрок получил объяснение")
	check(stub.messages[#stub.messages].message:find("земл", 1, true) ~= nil, "сообщение про землю")

	local brain = smart_npc.new_brain({ x = 0.5, y = 1, z = 0.5 }, {})
	local first = smart_npc.spawn({ x = 0.5, y = 1, z = 0.5 }, { brain = brain })
	check(first ~= nil, "житель с готовым мозгом появился")
	local second, dup = smart_npc.spawn({ x = 0.5, y = 1, z = 0.5 }, { brain = brain })
	check(second == nil, "дубликат не создаётся")
	check_equal(dup, "duplicate_id", "причина — повтор id")
	smart_npc.remove(first)
end)

run("сохранение и восстановление", function()
	local entity = first_entity()
	local brain = entity._brain
	brain.stats.meals = 7
	local staticdata = def.get_staticdata(entity)
	check_string(staticdata, "staticdata не пустая")
	local restored = minetest.deserialize(staticdata)
	check(restored and restored.brain, "staticdata разбирается")
	check_equal(restored.brain.name, brain.name, "имя сохранилось")
	check_equal(restored.brain.stats.meals, 7, "статистика сохранилась")

	local object = minetest.add_entity({ x = 3, y = 1, z = 3 }, "smart_npc:npc", staticdata)
	check(object ~= nil, "житель восстановлен")
	local clone = object:get_luaentity()
	check(clone._brain ~= nil, "мозг восстановлен")
	check_equal(clone._brain.full_name, brain.full_name, "личность та же")
	check(clone._brain.memory ~= nil, "память восстановлена")
	check_string(clone.object.props.infotext, "подпись задана")

	-- Убеждаемся, что в сохранённом состоянии нет функций и объектов движка.
	local bad = {}
	local function walk(value, seen)
		local kind = type(value)
		if kind == "table" then
			if seen[value] then return end
			seen[value] = true
			for key, item in pairs(value) do
				local key_kind = type(key)
				if key_kind ~= "string" and key_kind ~= "number" then
					bad[#bad + 1] = "ключ " .. key_kind
				end
				walk(item, seen)
			end
		elseif kind == "userdata" or kind == "function" or kind == "thread" then
			bad[#bad + 1] = kind
		end
	end
	walk(restored.brain, {})
	check_equal(#bad, 0, "в сохранении только простые типы: " .. table.concat(bad, ", "))
	clone.object:remove()
end)

run("спасение из пустоты", function()
	local entity = first_entity()
	local brain = entity._brain
	local home = brain.knowledge.home or { x = 0, y = 1, z = 0 }
	entity.object.pos = { x = 0, y = -120, z = 0 }
	stub.advance(3)
	def.on_step(entity, 0.2)
	local pos = entity.object:get_pos()
	check(pos ~= nil and pos.y > -10, "житель вытащен из пустоты")
end)

run("деактивация убирает из реестра", function()
	local entity = first_entity()
	local brain = entity._brain
	def.on_deactivate(entity, false)
	check(smart_npc.active[brain.id] == nil, "житель удалён из реестра")
	smart_npc.setup(entity, brain)
	check(smart_npc.active[brain.id] == entity, "житель возвращён в реестр")
end)

run("максимум жителей", function()
	local limit = smart_npc.settings.max_npcs
	smart_npc.settings.max_npcs = smart_npc.count()
	local entity, err = smart_npc.spawn({ x = 0.5, y = 1, z = 0.5 }, {})
	check(entity == nil, "сверх лимита не создаётся")
	check_equal(err, "max_npcs")
	smart_npc.settings.max_npcs = limit
end)

run("панель после удаления жителя", function()
	local entity = first_entity()
	UI.show(player, entity, 1)
	local brain = entity._brain
	smart_npc.active[brain.id] = nil
	stub.receive_fields(player, "smart_npc:panel", { act_talk = true })
	check(true, "панель не падает без сущности")
	smart_npc.active[brain.id] = entity
end)

-- ===========================================================================
-- Итоги
-- ===========================================================================
print(string.format("\nПроверок: %d, тестов: %d, провалов: %d", checks, tests_run, #failures))
if #failures > 0 then
	if os.getenv("SMART_NPC_EMBEDDED") then
		_G.SMART_NPC_FAILED = true
	else
		os.exit(1)
	end
end
