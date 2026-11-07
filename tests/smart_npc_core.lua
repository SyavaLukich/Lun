-- Тесты «мозга» умных NPC без запуска Luanti.
-- Запуск из корня репозитория:
--     lua tests/smart_npc_core.lua
-- или через lupa:
--     python3 tests/run_tests.py
--
-- Проверяются характер, потребности, память, отношения, желания, настроение
-- и длительная симуляция поведения.

local ok_all = true
local checks = 0
local failures = {}

local function fail(message, level)
	ok_all = false
	error(message, (level or 2) + 1)
end

local function assert_true(value, message)
	checks = checks + 1
	if not value then fail(message or "ожидалось true") end
end

local function assert_false(value, message)
	checks = checks + 1
	if value then fail(message or "ожидалось false") end
end

local function assert_equal(actual, expected, message)
	checks = checks + 1
	if actual ~= expected then
		fail(string.format("%s: получено %s, ожидалось %s",
			message or "сравнение", tostring(actual), tostring(expected)))
	end
end

local function assert_near(actual, expected, epsilon, message)
	checks = checks + 1
	if math.abs((actual or 0) - expected) > (epsilon or 0.001) then
		fail(string.format("%s: получено %s, ожидалось ~%s",
			message or "сравнение", tostring(actual), tostring(expected)))
	end
end

local function assert_in_range(value, low, high, message)
	checks = checks + 1
	if type(value) ~= "number" or value < low or value > high then
		fail(string.format("%s: %s вне диапазона [%s, %s]",
			message or "значение", tostring(value), tostring(low), tostring(high)))
	end
end

local function assert_string(value, message)
	checks = checks + 1
	if type(value) ~= "string" or #value == 0 then
		fail((message or "ожидалась непустая строка") .. ", получено " .. tostring(value))
	end
end

-- ===========================================================================
-- Загрузка модулей
-- ===========================================================================
local root = os.getenv("SMART_NPC_PATH") or "mods/smart_npc"
smart_npc = {}
for _, file in ipairs({
	"core/util.lua",
	"core/personality.lua",
	"core/names.lua",
	"core/needs.lua",
	"core/memory.lua",
	"core/desires.lua",
	"core/brain.lua",
	"core/dialogue.lua",
}) do
	local chunk, err = loadfile(root .. "/" .. file)
	if not chunk then
		io.stderr:write("Не удалось загрузить " .. file .. ": " .. tostring(err) .. "\n")
		os.exit(1)
	end
	chunk()
end

local U = smart_npc.util
local P = smart_npc.personality
local N = smart_npc.needs
local M = smart_npc.memory
local D = smart_npc.desires
local B = smart_npc.brain
local T = smart_npc.dialogue
local names = smart_npc.names

-- ===========================================================================
-- Вспомогательные функции
-- ===========================================================================
local function new_brain(seed, opts)
	opts = opts or {}
	opts.seed = seed or 42
	opts.now = opts.now or 0
	opts.pos = opts.pos or { x = 0, y = 0, z = 0 }
	return B.create(opts)
end

local ctx_counter = 0

local function make_ctx(brain, now, dt, opts)
	opts = opts or {}
	ctx_counter = ctx_counter + 1
	local targets = opts.targets
	if targets == nil then
		targets = {
			{ key = "player:Вася", name = "Вася", kind = "player", pos = { x = 1, y = 0, z = 0 }, distance = 1 },
			{ key = "npc:friend", name = "Мира", kind = "npc", pos = { x = 3, y = 0, z = 0 }, distance = 3 },
		}
	end
	return {
		now = now,
		dt = dt,
		pos = { x = 0, y = 0, z = 0 },
		social_targets = targets,
		environment = {
			light = opts.light or 15,
			day = opts.day ~= false,
			night = opts.day == false,
			dark = (opts.light or 15) < 7,
			sheltered = opts.sheltered ~= false,
			warm = true,
			company = opts.company ~= false,
			danger = opts.danger or false,
		},
		food = { x = 5, y = 0, z = 5 },
		food_name = "default:apple",
		water = nil,
		interesting = { x = 6, y = 0, z = 6 },
		interesting_name = "default:tree",
	}
end

-- Прогон мозга на N секунд с имитацией успешных действий.
local function simulate(brain, seconds, dt, opts)
	opts = opts or {}
	local now = opts.start or 0
	local goals = {}
	local steps = math.floor(seconds / dt)
	for _ = 1, steps do
		now = now + dt
		local ctx = make_ctx(brain, now, dt, opts)
		B.tick(brain, ctx)
		local goal = brain.goal
		if goal then
			goals[goal.action] = (goals[goal.action] or 0) + 1
			if opts.complete ~= false then
				if goal.action == "eat" then
					B.eat(brain, "яблоко", now, 45)
				elseif goal.action == "sleep" then
					N.set(brain, "energy", 95)
				elseif goal.action == "talk" then
					B.converse(brain, "player:Вася", "Вася", now, nil, { gain = 22 })
				elseif goal.action == "wash" then
					N.set(brain, "hygiene", 95)
				elseif goal.action == "warm" then
					N.set(brain, "comfort", 90)
				elseif goal.action == "seek_safety" then
					N.set(brain, "safety", 95)
				end
				B.complete_goal(brain, now, true)
			end
		end
	end
	return now, goals
end

-- ===========================================================================
-- Тесты
-- ===========================================================================
local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

test("математика и русский текст", function()
	assert_equal(U.clamp(5, 0, 3), 3, "clamp сверху")
	assert_equal(U.clamp(-5, 0, 3), 0, "clamp снизу")
	assert_equal(U.round(2.6), 3, "округление")
	assert_equal(U.plural(1, "год", "года", "лет"), "год")
	assert_equal(U.plural(3, "год", "года", "лет"), "года")
	assert_equal(U.plural(11, "год", "года", "лет"), "лет")
	assert_equal(U.plural(22, "год", "года", "лет"), "года")
	assert_equal(U.hash("abc"), U.hash("abc"), "хеш детерминирован")
	assert_true(U.hash("abc") ~= U.hash("abd"), "хеш различает строки")
	local lines = U.wrap("раз два три четыре пять шесть семь", 10)
	assert_true(#lines >= 2, "перенос строк работает")
	assert_equal(U.formspec_safe("a,b;c]d"), "a b c)d", "очистка formspec")
	assert_equal(U.vector_copy("не позиция"), nil, "некорректная позиция не копируется")
	assert_equal(U.distance("не позиция", { x = 0, y = 0, z = 0 }), math.huge,
		"расстояние до некорректной позиции бесконечно")
	assert_true(U.distance({ x = "0", y = "0", z = "0" },
		{ x = 3, y = 0, z = 4 }) == 5, "строковые координаты приводятся к числам")
end)

test("детерминированный случай", function()
	local b1 = new_brain(777)
	local b2 = new_brain(777)
	assert_equal(b1.full_name, b2.full_name, "одинаковый seed — одинаковое имя")
	assert_equal(b1.personality.occupation, b2.personality.occupation, "одинаковая профессия")
	local a1, a2 = {}, {}
	for i = 1, 10 do
		a1[i] = B.rand(b1, 1, 1000)
		a2[i] = B.rand(b2, 1, 1000)
	end
	assert_equal(table.concat(a1, ","), table.concat(a2, ","), "одинаковая последовательность")
	local rng1 = U.new_rng(5)
	local rng2 = U.new_rng(5)
	for i = 1, 5 do
		assert_equal(rng1(1, 100), rng2(1, 100), "new_rng воспроизводим")
	end
end)

test("характер и профессия", function()
	for seed = 1, 40 do
		local brain = new_brain(seed)
		local person = brain.personality
		assert_string(person.occupation, "профессия задана")
		assert_string(person.title, "архетип задан")
		assert_true(person.tone == "anxious" or person.tone == "grumpy"
			or person.tone == "warm" or person.tone == "curious" or person.tone == "calm",
			"тон характера известен")
		for _, trait in ipairs(P.trait_order) do
			assert_in_range(person.traits[trait], 0.05, 0.95, "черта " .. trait)
		end
		local weights = P.need_weights(person)
		local sum = 0
		for _, value in pairs(weights) do sum = sum + value end
		assert_true(sum > 0.5 and sum < 2, "веса настроения разумны")
		for _, need in ipairs(N.order) do
			assert_true(P.decay_mod(person, need) > 0, "скорость убывания положительна")
		end
		assert_string(P.describe(person))
	end
end)

test("имена и биография", function()
	local saw_female, saw_male = false, false
	for seed = 1, 30 do
		local brain = new_brain(seed)
		assert_string(brain.full_name)
		assert_true(brain.full_name:find(brain.name, 1, true) == 1, "полное имя начинается с имени")
		assert_in_range(brain.age, 18, 90, "возраст")
		assert_string(brain.backstory)
		assert_true(brain.backstory:find(brain.full_name, 1, true) ~= nil, "биография содержит имя")
		if brain.gender == "female" then saw_female = true else saw_male = true end
	end
	assert_true(saw_female and saw_male, "встречаются оба пола")
end)

test("создание с заданным именем и возрастом", function()
	local named = B.create({ name = "Мира", age = 44, seed = 999 })
	assert_equal(named.name, "Мира", "имя сохранено")
	assert_equal(named.age, 44, "возраст сохранён")
	assert_equal(named.full_name, "Мира", "полное имя заполнено")
	assert_string(named.backstory, "биография построена")
	assert_true(named.backstory:find("44", 1, true) ~= nil, "в биографии есть возраст")

	local aged = B.create({ age = 50, seed = 1000 })
	assert_equal(aged.age, 50, "возраст без имени сохранён")
	assert_string(aged.name, "имя сгенерировано")
end)

test("потребности убывают и восстанавливаются", function()
	local brain = new_brain(3)
	N.set(brain, "hunger", 100)
	local before = N.get(brain, "hunger")
	N.update(brain, 60, 60, { company = false })
	assert_true(N.get(brain, "hunger") < before, "голод растёт со временем")
	local hungry = N.get(brain, "hunger")

	brain.activity = "sleep"
	N.set(brain, "energy", 20)
	N.update(brain, 10, 70, {})
	assert_true(N.get(brain, "energy") > 20, "сон восстанавливает силы")

	brain.activity = "idle"
	N.set(brain, "social", 30)
	N.update(brain, 30, 100, { company = true })
	assert_true(N.get(brain, "social") > 30, "компания восстанавливает общение")

	N.set(brain, "safety", 80)
	N.update(brain, 20, 120, { danger = true })
	assert_true(N.get(brain, "safety") < 80, "опасность снижает спокойствие")

	N.set(brain, "hunger", 1)
	N.update(brain, 10000, 200, {})
	assert_equal(N.get(brain, "hunger"), 0, "значение не уходит ниже нуля")

	N.set(brain, "hunger", 99)
	assert_equal(N.get(brain, "hunger"), 99)
	N.set(brain, "hunger", 150)
	assert_equal(N.get(brain, "hunger"), 100, "значение не выше ста")
	assert_true(hungry < 100, "голод изменился")
end)

test("характер влияет на скорость потребностей", function()
	local introvert = new_brain(11, { seed = 11 })
	introvert.personality.traits.extraversion = 0.05
	local extravert = new_brain(12, { seed = 12 })
	extravert.personality.traits.extraversion = 0.95
	N.set(introvert, "social", 100)
	N.set(extravert, "social", 100)
	N.update(introvert, 120, 120, { company = false })
	N.update(extravert, 120, 120, { company = false })
	assert_true(N.get(extravert, "social") < N.get(introvert, "social"),
		"общительному нужно больше общения")
end)

test("память: события, сила и мысли", function()
	local brain = new_brain(20)
	local now = 100

	M.add(brain, { kind = "test", text = "Съел яблоко", valence = 20, importance = 4 }, now)
	M.add(brain, { kind = "test", text = "Ударился", valence = -40, importance = 8 }, now + 10)
	assert_equal(#brain.memory.events, 2, "события сохранены")

	local thoughts = M.thoughts(brain, now + 20, 5)
	assert_true(#thoughts >= 2, "мысли появляются")
	assert_true(thoughts[1].value < 0, "сильная отрицательная мысль идёт первой")

	local strength_before = brain.memory.events[1].strength
	M.decay(brain, now + 4000)
	assert_true(brain.memory.events[1].strength < strength_before, "след слабеет")
	assert_true(brain.memory.events[2].strength > brain.memory.events[1].strength,
		"важное помнится лучше")

	for i = 1, 400 do
		M.add(brain, { kind = "noise", text = "Событие " .. i, valence = 1, importance = 2 }, now + 5000 + i)
	end
	assert_true(#brain.memory.events <= M.max_events, "память не разрастается бесконечно")
end)

test("отношения и их влияние", function()
	local brain = new_brain(30)
	local now = 10

	local before = M.relationship(brain, "player:Вася", "Вася")
	assert_equal(before.affinity, 0, "знакомство начинается с нуля")

	M.gift(brain, "player:Вася", "Вася", "яблоко", now)
	local after_gift = M.relationship(brain, "player:Вася", "Вася")
	assert_true(after_gift.affinity > 0, "подарок улучшает отношение")
	assert_true(after_gift.trust > 0, "подарок повышает доверие")
	assert_equal(after_gift.gifts, 1)

	M.attack(brain, "player:Петя", "Петя", now + 10, 3)
	local after_attack = M.relationship(brain, "player:Петя", "Петя")
	assert_true(after_attack.affinity < 0, "удар ухудшает отношение")
	assert_true(after_attack.fear >= 30, "удар пугает")

	local rel_label = M.relation_label(after_attack)
	assert_true(rel_label:find("боит", 1, true) or rel_label:find("опаса", 1, true)
		or rel_label:find("ненавид", 1, true), "отношение описано словами")

	local recall = M.recall(brain, now + 20, { subjects = { "player:Петя" }, limit = 3 })
	assert_true(#recall >= 1, "воспоминание связано с обидчиком")
	assert_true(recall[1].event.kind == "attack", "вспоминается именно нападение")

	M.conversation(brain, "player:Вася", "Вася", now + 30)
	assert_true(M.relationship(brain, "player:Вася", "Вася").talks >= 1, "разговоры считаются")
	assert_string(M.summary(brain, now + 40, 3)[1].text)
end)

test("потребности рождают желания", function()
	local brain = new_brain(40)
	brain.desires = {}
	for _, need in ipairs(N.order) do N.set(brain, need, 95) end
	N.set(brain, "hunger", 5)
	local now = 1000
	D.refresh(brain, now, make_ctx(brain, now, 1))
	local desire = D.get_need_desire(brain, "hunger")
	assert_true(desire ~= nil, "голод создаёт желание поесть")
	assert_equal(desire.action, "eat")
	assert_true(desire.utility > 60, "желание поесть срочное")
	local picked = D.pick(brain, now)
	assert_equal(picked.action, "eat", "мозг хочет есть")

	B.apply_desire(brain, picked, now)
	B.tick(brain, make_ctx(brain, now + 1, 1))
	assert_equal(brain.goal.action, "eat")
end)

test("сытый житель не думает о еде", function()
	local brain = new_brain(41)
	brain.desires = {}
	for _, need in ipairs(N.order) do N.set(brain, need, 100) end
	D.refresh(brain, 500, make_ctx(brain, 500, 1))
	assert_true(D.get_need_desire(brain, "hunger") == nil, "нет желания есть при сытости")
end)

test("общительность рождает разговор с целью", function()
	local brain = new_brain(42)
	brain.desires = {}
	for _, need in ipairs(N.order) do N.set(brain, need, 95) end
	N.set(brain, "social", 10)
	brain.personality.traits.extraversion = 0.9
	local ctx = make_ctx(brain, 900, 1)
	D.refresh(brain, 900, ctx)
	local desire = D.get_need_desire(brain, "social")
	assert_true(desire ~= nil, "одиночество создаёт желание поговорить")
	assert_equal(desire.action, "talk")
	assert_true(desire.target ~= nil, "выбрана конкретная цель")
	assert_true(desire.target == "player:Вася" or desire.target == "npc:friend")
end)

test("память меняет желания: обида и благодарность", function()
	local brain = new_brain(43)
	local now = 5000
	B.attacked_by(brain, "player:Петя", "Петя", now, 4)
	local avoid
	for _, d in ipairs(brain.desires) do
		if d.action == "avoid" then avoid = d end
	end
	assert_true(avoid ~= nil, "нападение рождает желание избегать")
	assert_equal(avoid.target, "player:Петя")
	assert_true(avoid.utility >= 80, "страх сильный")
	assert_true(brain.stress > 0, "стресс вырос")

	local brain2 = new_brain(44)
	B.receive_gift(brain2, "player:Вася", "Вася", "яблоко", now)
	assert_equal(brain2.carry.food, 1, "подарок отложен в припасы")
	local rel = brain2.memory.relationships["player:Вася"]
	assert_true(rel.affinity > 0 and rel.trust > 0, "подарок улучшил отношения")

	local thank
	for attempt = 1, 8 do
		brain2.whim_timer = 0
		D.refresh(brain2, now + attempt, make_ctx(brain2, now + attempt, 1))
	end
	for _, d in ipairs(brain2.desires) do
		if d.action == "thank" then thank = d end
	end
	assert_true(thank ~= nil, "после подарка хочется поблагодарить")
end)

test("желания ограничены и истекают", function()
	local brain = new_brain(45)
	local now = 0
	for i = 1, 10 do
		D.add(brain, {
			id = "custom:" .. i,
			action = "play",
			title = "Желание " .. i,
			utility = 10,
			ttl = 1,
		}, now)
	end
	assert_equal(#brain.desires, 10)
	D.prune(brain, now + 5)
	assert_equal(#brain.desires, 0, "истёкшие желания удаляются")

	-- Повторное событие снимает старый кулдаун того же желания.
	local repeated = D.add(brain, {
		id = "reaction:test", action = "avoid", title = "Отойти", utility = 50, ttl = 60,
	}, now)
	repeated.cooldown_until = now + 300
	D.add(brain, {
		id = "reaction:test", action = "avoid", title = "Отойти", utility = 90, ttl = 60,
	}, now)
	assert_true(repeated.cooldown_until == nil, "повторное событие снимает кулдаун")
	assert_equal(repeated.utility, 90, "повторное событие обновляет желание")

	-- Желание с неизвестной потребностью не должно ронять prune.
	D.add(brain, { id = "need:unknown", action = "play", source = "need", need = "unknown" }, now)
	D.prune(brain, now)
	assert_true(true, "prune переживает неизвестную потребность")

	brain.desires = {}
	for _, need in ipairs(N.order) do N.set(brain, need, 100) end
	for _ = 1, 20 do
		D.refresh(brain, now + 500, make_ctx(brain, now + 500, 1))
	end
	assert_true(#brain.desires <= D.max_whims + #N.order,
		"количество желаний ограничено: " .. #brain.desires)
end)

test("настроение и стресс", function()
	local happy = new_brain(50)
	for _, need in ipairs(N.order) do N.set(happy, need, 95) end
	B.update_mood(happy, 0)
	assert_true(happy.mood > 70, "довольный житель счастлив")

	local sad = new_brain(51)
	for _, need in ipairs(N.order) do N.set(sad, need, 5) end
	B.update_mood(sad, 0)
	assert_true(sad.mood < 30, "неудовлетворённый житель несчастен")
	assert_true(sad.mood < happy.mood)

	B.update_stress(sad, 600)
	assert_true(sad.stress > 0, "стресс накапливается")
	local before = sad.stress
	B.update_stress(happy, 60)
	assert_true(happy.stress <= before, "у счастливого стресс не растёт")
end)

test("срыв и восстановление", function()
	local brain = new_brain(60)
	for _, need in ipairs(N.order) do N.set(brain, need, 0) end
	local now = 0
	local saw_tantrum = false
	for _ = 1, 4000 do
		now = now + 1
		B.tick(brain, make_ctx(brain, now, 1, { company = false, sheltered = false, light = 4 }))
		if brain.goal and brain.goal.action == "tantrum" then
			saw_tantrum = true
			break
		end
	end
	assert_true(saw_tantrum, "долгая нужда приводит к истерике")
	assert_true(brain.stats.tantrums >= 1, "истерика учтена в статистике")
	assert_true(brain.stress >= 85, "высокий стресс")
	-- Возвращаем жителя к жизни.
	brain.stress = 40
	for _, need in ipairs(N.order) do N.set(brain, need, 80) end
	B.update_mood(brain, now)
	B.tick(brain, make_ctx(brain, now + 1, 1))
	assert_true(brain.goal and brain.goal.action ~= "tantrum", "после успокоения истерика прекращается")
end)

test("разговор и реплики", function()
	local brain = new_brain(70)
	brain.memory.relationships["player:Вася"] = nil
	local greeting = T.greeting(brain, "Вася", 0)
	assert_string(greeting)

	local self_answer = T.answer(brain, "Вася", "self", 0)
	assert_true(self_answer:find(brain.full_name, 1, true) ~= nil, "житель называет себя")

	local mood_answer = T.answer(brain, "Вася", "mood", 0)
	assert_string(mood_answer)

	local memory_answer = T.answer(brain, "Вася", "memory", 0)
	assert_string(memory_answer)

	M.gift(brain, "player:Вася", "Вася", "яблоко", 0)
	local memory_after = T.answer(brain, "Вася", "memory", 1)
	assert_true(memory_after:find("яблок", 1, true) ~= nil or memory_after:find("Помню", 1, true) ~= nil,
		"житель помнит подарок")

	local reply = T.chat_reply(brain, "Вася", "привет", 2)
	assert_true(reply ~= nil and reply.text ~= nil, "на приветствие есть ответ")

	local rude = T.chat_reply(brain, "Вася", "ты дурак", 3)
	assert_true(rude ~= nil and rude.insult == true, "грубость распознана")

	local follow = T.chat_reply(brain, "Вася", "иди за мной", 4)
	assert_true(follow ~= nil and follow.follow == true, "просьба идти следом распознана")

	local unknown = T.chat_reply(brain, "Вася", "квантовая хромодинамика", 5)
	assert_true(unknown == nil, "на непонятное сообщение можно не отвечать")

	assert_string(T.ambient(brain, 6))
end)

test("дружба меняет тон", function()
	local brain = new_brain(71)
	local rel = M.relationship(brain, "player:Вася", "Вася")
	rel.interactions = 5
	rel.affinity = 60
	rel.fear = 0
	local friendly = T.greeting(brain, "Вася", 0)
	assert_string(friendly)

	rel.affinity = -70
	local hostile = T.greeting(brain, "Вася", 1)
	assert_string(hostile)
	assert_true(friendly ~= hostile, "отношение меняет приветствие")

	rel.fear = 90
	local scared = T.greeting(brain, "Вася", 2)
	assert_true(scared:find("страшн", 1, true) or scared:find("Не подходи", 1, true)
		or scared:find("отойду", 1, true) or scared:find("Тише", 1, true), "испуганный житель боится")
end)

test("знания о местах", function()
	local brain = new_brain(80)
	for i = 1, 30 do
		B.knowledge_add(brain, { x = i * 1.0, y = 0, z = 0 }, "место", "Точка " .. i, i, 5)
	end
	assert_true(#brain.knowledge.spots <= 16, "число известных мест ограничено")

	B.knowledge_add(brain, { x = 1, y = 0, z = 0 }, "место", "Точка 1", 100, 9)
	local found = false
	for _, spot in ipairs(brain.knowledge.spots) do
		if spot.note == "Точка 1" then
			found = true
			assert_true(spot.visits >= 2, "повторный визит учитывается")
		end
	end
	assert_true(found, "место не дублируется")
end)

test("миграция старых данных", function()
	local brain = B.migrate({})
	assert_true(brain ~= nil, "пустой мозг мигрирует")
	assert_true(brain.needs.hunger ~= nil, "потребности заполнены")
	assert_true(brain.memory.events ~= nil, "память создана")
	assert_true(brain.personality.traits.openness ~= nil, "черты характера заполнены")
	assert_string(B.describe(brain))
	assert_equal(B.migrate(nil), nil)

	-- Старое воспоминание без силы и важности не должно ломать recall.
	local old = B.migrate({ memory = {
		events = { { kind = "old", text = "Старое событие" } },
		relationships = { ["player:Старый"] = { name = "Старый" } },
	} })
	assert_true(old.memory.events[1].strength ~= nil, "сила старого воспоминания восстановлена")
	assert_true(old.memory.events[1].importance >= 1, "важность старого воспоминания восстановлена")
	assert_true(M.recall(old, 10, { limit = 3 })[1] ~= nil, "recall читает старое воспоминание")
	assert_equal(old.memory.relationships["player:Старый"].fear, 0, "поля старого отношения восстановлены")
	assert_equal(M.relationship(old, "player:Старый").interactions, 0, "счётчики старого отношения доступны")

	-- Повреждённые типы не должны ронять загрузку.
	local corrupt = B.migrate({
		id = 42,
		name = {},
		gender = 5,
		age = "старый",
		skin = "9",
		needs = "нет",
		mood = "плохо",
		stress = {},
		personality = { traits = { openness = "много", extraversion = 9 }, occupation = 5 },
		memory = {
			events = { "событие", { id = "7", kind = 5, importance = 99 } },
			relationships = { [5] = "нет", ["player:X"] = "нет",
				["player:Y"] = { name = 5, affinity = "2", fear = {} } },
		},
		knowledge = { home = "дом", spots = { "место", { pos = "нет" }, { pos = { x = 1, y = 2, z = 3 } } } },
		cache = { food_pos = "еда", food_at = "сейчас", interesting_pos = { x = 1 } },
		perceive_seen = { old = "давно", good = 3 },
		stats = { chats = "5", last_action = 5 },
		whim_cooldowns = { a = "скоро", b = 4 },
		carry = { food = "2" },
		last_hurt = "недавно",
		last_context = "старый",
		goal = "цель",
	})
	assert_equal(corrupt.id, "42", "числовой id стал строкой")
	assert_equal(corrupt.needs.hunger, 60, "нечисловые потребности заменены")
	assert_equal(corrupt.mood, 55, "нечисловое настроение заменено")
	assert_equal(corrupt.stress, 0, "нечисловой стресс заменён")
	assert_equal(corrupt.personality.traits.openness, 0.5, "нечисловая черта заменена")
	assert_equal(corrupt.personality.traits.extraversion, 0.95, "черта ограничена")
	assert_equal(corrupt.personality.occupation, "5", "профессия приведена к строке")
	assert_equal(#corrupt.memory.events, 1, "некорректное событие отброшено")
	assert_equal(corrupt.memory.events[1].id, 7, "id события приведён к числу")
	assert_equal(corrupt.memory.events[1].importance, 10, "важность ограничена")
	assert_equal(corrupt.memory.relationships["player:Y"].affinity, 2, "привязанность приведена к числу")
	assert_equal(corrupt.memory.relationships["player:X"], nil, "некорректное отношение отброшено")
	assert_equal(#corrupt.knowledge.spots, 1, "места без позиции отброшены")
	assert_equal(corrupt.stats.chats, 5, "счётчик разговоров приведён к числу")
	assert_equal(corrupt.stats.last_action, "5", "последнее действие приведено к строке")
	assert_equal(corrupt.whim_cooldowns.b, 4, "числовое время ожидания сохранено")
	assert_equal(corrupt.whim_cooldowns.a, nil, "нечисловое время ожидания отброшено")
	assert_equal(corrupt.carry.food, 2, "запас еды приведён к числу")
	assert_equal(corrupt.last_hurt, nil, "нечисловая отметка удара сброшена")
	assert_equal(corrupt.last_context, nil, "некорректный контекст сброшен")
	assert_equal(corrupt.goal, nil, "некорректная цель сброшена")
	assert_equal(corrupt.activity, "wander", "деятельность по умолчанию")
	assert_equal(corrupt.skin, 9, "кожа приведена к числу")
	assert_equal(corrupt.knowledge.home, nil, "некорректный дом сброшен")
	assert_equal(corrupt.cache.food_pos, nil, "некорректная цель еды сброшена")
	assert_equal(corrupt.cache.food_at, nil, "некорректная отметка поиска сброшена")
	assert_equal(corrupt.perceive_seen.old, nil, "некорректная отметка встречи сброшена")
	assert_equal(corrupt.perceive_seen.good, 3, "числовая отметка встречи сохранена")

	local bad_goal = B.migrate({ goal = { action = "talk", target_pos = "там", started = "сейчас" } })
	assert_equal(bad_goal.goal.action, "talk", "действие цели сохранено")
	assert_equal(bad_goal.goal.target_pos, nil, "некорректная позиция цели сброшена")
	assert_equal(bad_goal.goal.started, 0, "некорректное время цели заменено")
end)

test("сериализуемость состояния", function()
	local brain = new_brain(90)
	B.attacked_by(brain, "player:Петя", "Петя", 10, 2)
	B.receive_gift(brain, "player:Вася", "Вася", "яблоко", 20)
	B.converse(brain, "player:Вася", "Вася", 30, "погода")
	local visited, bad = {}, {}
	local function walk(value)
		local kind = type(value)
		if kind == "table" then
			if visited[value] then return end
			visited[value] = true
			for k, v in pairs(value) do
				if type(k) ~= "string" and type(k) ~= "number" then
					bad[#bad + 1] = "ключ типа " .. type(k)
				end
				walk(v)
			end
		elseif kind ~= "string" and kind ~= "number" and kind ~= "boolean" and kind ~= "nil" then
			bad[#bad + 1] = "значение типа " .. kind
		end
	end
	walk(brain)
	assert_equal(#bad, 0, "в состоянии только простые типы: " .. table.concat(bad, ", "))
end)

test("длительная симуляция 45 минут", function()
	local brain = new_brain(100)
	local now, goals = simulate(brain, 45 * 60, 3, { company = false })
	assert_true(now > 0)
	assert_true(goals.eat and goals.eat > 0, "житель ел")
	assert_true(goals.sleep and goals.sleep > 0, "житель спал")
	assert_true(goals.talk and goals.talk > 0, "житель общался")
	assert_in_range(brain.mood, 0, 100, "настроение в диапазоне")
	assert_in_range(brain.stress, 0, 100, "стресс в диапазоне")
	for _, need in ipairs(N.order) do
		assert_in_range(N.get(brain, need), 0, 100, "потребность " .. need)
	end
	assert_true(#brain.memory.events <= M.max_events, "память в пределах лимита")
	assert_true(#brain.desires < 20, "желания не копятся бесконечно")
	assert_true(brain.stats.ticks >= 900, "тики посчитаны")
	assert_true(brain.mood > 40, "в хорошем мире житель не в депрессии")
end)

test("симуляция одиночества", function()
	local brain = new_brain(101)
	local _, goals = simulate(brain, 20 * 60, 2, {
		targets = {},
		company = false,
		sheltered = false,
		light = 5,
		day = false,
	})
	assert_true(goals, "цели есть")
	assert_in_range(brain.mood, 0, 100)
	assert_true(#brain.desires <= D.max_whims + #N.order + 2, "желания ограничены")
end)

test("чат: намерения и прощание", function()
	local brain = new_brain(110)
	local reply = T.chat_reply(brain, "Тестер", "ты дурак", 5)
	assert_true(reply and reply.insult, "оскорбление распознано")
	reply = T.chat_reply(brain, "Тестер", "покажи дорогу", 10)
	assert_true(reply == nil, "«покажи» не считается прощанием")
	reply = T.chat_reply(brain, "Тестер", "пока", 15)
	assert_equal(reply and reply.topic, "прощание", "«пока» — прощание")
	reply = T.chat_reply(brain, "Тестер", "иди за мной", 20)
	assert_true(reply and reply.follow, "просьба идти следом")
	reply = T.chat_reply(brain, "Тестер", "как дела?", 25)
	assert_true(reply and reply.text and #reply.text > 0, "ответ про дела")
	reply = T.chat_reply(brain, "Тестер", "Привет, " .. brain.name, 30)
	assert_equal(reply and reply.topic, "приветствие", "упоминание имени — приветствие")
end)

test("биография согласована с полом", function()
	for seed = 1, 60 do
		local rng = U.new_rng(seed)
		local identity = smart_npc.names.identity(rng)
		local text = smart_npc.names.backstory(rng, nil, identity)
		if identity.gender == "female" then
			assert_false(text:find("Пришёл", 1, true) ~= nil, "женщина: «Пришёл»")
			assert_false(text:find("Остался", 1, true) ~= nil, "женщина: «Остался»")
			assert_false(text:find("Устал ", 1, true) ~= nil, "женщина: «Устал»")
		else
			assert_false(text:find("Пришла", 1, true) ~= nil, "мужчина: «Пришла»")
			assert_false(text:find("Осталась", 1, true) ~= nil, "мужчина: «Осталась»")
			assert_false(text:find("Устала", 1, true) ~= nil, "мужчина: «Устала»")
		end
		assert_true(text:find(identity.full_name, 1, true) ~= nil, "имя в биографии")
	end
end)

-- ===========================================================================
-- Запуск
-- ===========================================================================
for _, item in ipairs(tests) do
	local ok, err = pcall(item.fn)
	if ok then
		print(string.format("  ✓ %s", item.name))
	else
		print(string.format("  ✗ %s\n      %s", item.name, tostring(err)))
		failures[#failures + 1] = { name = item.name, err = err }
	end
end

print(string.format("\nПроверок: %d, тестов: %d, провалов: %d", checks, #tests, #failures))
if not ok_all then
	if os.getenv("SMART_NPC_EMBEDDED") then
		_G.SMART_NPC_FAILED = true
	else
		os.exit(1)
	end
end
