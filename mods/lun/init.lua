local engine = minetest
local spawn = {x = 0, y = 2, z = 0}
local platform_min = {x = -4, y = 0, z = -4}

-- Не зависим от default, creative или других модов из Minetest Game.
engine.register_alias("mapgen_singlenode", "air")
engine.register_on_mapgen_init(function()
	engine.set_mapgen_setting("mg_name", "singlenode", true)
end)

local blocks = {
	{"stone", "Камень", "lun_stone.png"},
	{"grass", "Трава", "lun_grass.png"},
	{"wood", "Дерево", "lun_wood.png"},
	{"white", "Белый блок", "lun_white.png"},
	{"blue", "Синий блок", "lun_blue.png"},
	{"light", "Светящийся блок", "lun_light.png"},
}

for _, block in ipairs(blocks) do
	engine.register_node("lun:" .. block[1], {
		description = block[2],
		tiles = {block[3]},
		groups = {dig_immediate = 3},
		light_source = block[1] == "light" and 14 or 0,
		is_ground_content = false,
	})
end

local function give_blocks(player)
	local inventory = player:get_inventory()
	for _, block in ipairs(blocks) do
		local name = "lun:" .. block[1]
		if not inventory:contains_item("main", name) then
			inventory:add_item("main", name .. " 99")
		end
	end
end

-- Загружаем область перед созданием платформы. Не перезаписываем постройки.
local function return_to_spawn(name)
	engine.emerge_area(platform_min, {x = 4, y = 3, z = 4}, function(_, _, remaining)
		if remaining ~= 0 then
			return
		end
		for x = -4, 4 do
			for z = -4, 4 do
				local pos = {x = x, y = 0, z = z}
				if engine.get_node(pos).name == "air" then
					engine.set_node(pos, {name = "lun:stone"})
				end
			end
		end
		local player = engine.get_player_by_name(name)
		if player then
			player:set_pos(spawn)
			player:set_velocity({x = 0, y = 0, z = 0})
		end
	end)
end

engine.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local inventory = player:get_inventory()
	inventory:set_size("main", 32)
	player:set_inventory_formspec(
		"formspec_version[4]size[10.5,6]"
		.. "label[0.4,0.5;Lun — блоки для строительства]"
		.. "list[current_player;main;0.4,1;8,4;]"
		.. "listring[current_player;main]"
	)
	player:hud_set_hotbar_itemcount(8)
	local privileges = engine.get_player_privs(name)
	privileges.fly = true
	privileges.fast = true
	engine.set_player_privs(name, privileges)
	give_blocks(player)
	local meta = player:get_meta()
	if meta:get_int("lun_joined") == 0 then
		meta:set_int("lun_joined", 1)
		return_to_spawn(name)
	end
	engine.chat_send_player(name,
		"Добро пожаловать в Lun! I — инвентарь, K — полёт, J — скорость. "
		.. "/spawn — на платформу, /blocks — получить блоки.")
end)

engine.register_on_respawnplayer(function(player)
	return_to_spawn(player:get_player_name())
	return true
end)

engine.register_chatcommand("spawn", {
	description = "Вернуться на стартовую платформу",
	func = function(name)
		if not engine.get_player_by_name(name) then
			return false, "Команда доступна только в игре."
		end
		return_to_spawn(name)
		return true, "Возвращаемся на платформу…"
	end,
})

engine.register_chatcommand("blocks", {
	description = "Получить недостающие строительные блоки",
	func = function(name)
		local player = engine.get_player_by_name(name)
		if not player then
			return false, "Команда доступна только в игре."
		end
		give_blocks(player)
		return true, "Блоки добавлены (если в инвентаре есть место)."
	end,
})

local elapsed = 0
engine.register_globalstep(function(dtime)
	elapsed = elapsed + dtime
	if elapsed < 1 then
		return
	end
	elapsed = 0
	for _, player in ipairs(engine.get_connected_players()) do
		if player:get_pos().y < -30 then
			-- Мгновенно останавливаем падение, пока загружается платформа.
			player:set_pos(spawn)
			player:set_velocity({x = 0, y = 0, z = 0})
			return_to_spawn(player:get_player_name())
		end
	end
end)

-- Независимый контроллер принудительной камеры.
dofile(engine.get_modpath("lun") .. "/camera.lua")
