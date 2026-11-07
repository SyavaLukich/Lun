-- Минимальная заглушка Luanti для тестов мода smart_npc.
-- Не претендует на полное повторение движка: нужна, чтобы прогнать
-- регистрацию, сущность, панель, команды и сохранение без клиента.

local stub = {}
_G.STUB = stub

stub.time = 0
stub.nodes = {}
stub.players = {}
stub.entities = {}
stub.objects = {}
stub.particles = 0
stub.sounds = 0
stub.logs = {}
stub.messages = {}
stub.timers = {}
stub.formspecs = {}
stub.settings_values = {
	["smart_npc.need_decay_scale"] = "3",
}
stub.modpath = "mods/smart_npc"

-- ===========================================================================
-- Мир
-- ===========================================================================
local function key(x, y, z)
	return x .. "," .. y .. "," .. z
end

function stub.set_node(x, y, z, name)
	stub.nodes[key(x, y, z)] = name
end

function stub.get_node_name(x, y, z)
	return stub.nodes[key(x, y, z)] or "air"
end

for x = -24, 24 do
	for z = -24, 24 do
		stub.set_node(x, 0, z, "default:stone")
	end
end

local NODE_DEFS = {
	air = { name = "air", walkable = false, groups = {} },
	ignore = { name = "ignore", walkable = false, groups = {} },
	["default:stone"] = { name = "default:stone", walkable = true, description = "Stone",
		groups = { stone = 1, cracky = 3, not_in_creative_inventory = 0 } },
	["default:apple"] = { name = "default:apple", walkable = false, description = "Apple",
		groups = { food_apple = 1, fleshy = 3, dig_immediate = 3 }, on_use = function() end },
	["default:tree"] = { name = "default:tree", walkable = true, description = "Tree",
		groups = { tree = 1, wood = 1, choppy = 2 } },
	["default:water_source"] = { name = "default:water_source", walkable = false, description = "Water",
		groups = { water = 1, liquid = 1 } },
	["default:torch"] = { name = "default:torch", walkable = false, description = "Torch",
		groups = { torch = 1 } },
}

local ITEM_DEFS = {
	["default:apple"] = { name = "default:apple", description = "Apple", groups = { food_apple = 1 } },
	["default:blueberries"] = { name = "default:blueberries", description = "Blueberries",
		groups = { food_berry = 1, food_blueberries = 1 } },
	["default:dirt"] = { name = "default:dirt", description = "Dirt", groups = { soil = 3 } },
}

-- ===========================================================================
-- Утилиты
-- ===========================================================================
local function copy_pos(pos)
	if not pos then return nil end
	return { x = pos.x, y = pos.y, z = pos.z }
end
stub.copy_pos = copy_pos

local function fmt_number(value)
	if value == math.floor(value) and math.abs(value) < 1e15 then
		return string.format("%d", value)
	end
	return string.format("%.17g", value)
end

local function serialize_value(value, seen, parts)
	local kind = type(value)
	if kind == "nil" then
		parts[#parts + 1] = "nil"
	elseif kind == "boolean" or kind == "number" then
		parts[#parts + 1] = kind == "number" and fmt_number(value) or tostring(value)
	elseif kind == "string" then
		parts[#parts + 1] = string.format("%q", value)
	elseif kind == "table" then
		if seen[value] then
			parts[#parts + 1] = "nil"
			return
		end
		seen[value] = true
		parts[#parts + 1] = "{"
		for k, v in pairs(value) do
			parts[#parts + 1] = "["
			serialize_value(k, seen, parts)
			parts[#parts + 1] = "]="
			serialize_value(v, seen, parts)
			parts[#parts + 1] = ","
		end
		parts[#parts + 1] = "}"
	else
		parts[#parts + 1] = "nil"
	end
end

-- ===========================================================================
-- ItemStack
-- ===========================================================================
local function new_stack(item, count)
	local stack = {
		item = item or "",
		count = count or (item and #item > 0 and 1 or 0),
	}
	function stack:get_name() return self.item end
	function stack:get_count() return self.count end
	function stack:is_empty() return self.item == "" or self.count <= 0 end
	function stack:take_item(n)
		n = math.min(n or 1, self.count)
		self.count = self.count - n
		if self.count <= 0 then
			self.item = ""
			self.count = 0
		end
		return self
	end
	return stack
end
stub.new_stack = new_stack

-- ===========================================================================
-- Объекты и игроки
-- ===========================================================================
local function make_object(luaentity)
	local object = {
		lua = luaentity,
		pos = { x = 0, y = 0, z = 0 },
		velocity = { x = 0, y = 0, z = 0 },
		yaw = 0,
		hp = 100,
		removed = false,
		props = {},
		animation = nil,
		armor_groups = {},
	}
	function object:get_pos() return self.removed and nil or copy_pos(self.pos) end
	function object:set_pos(pos) self.pos = copy_pos(pos) end
	function object:getvelocity() return copy_pos(self.velocity) end
	function object:setvelocity(vel) self.velocity = copy_pos(vel) end
	function object:get_yaw() return self.yaw end
	function object:set_yaw(yaw) self.yaw = yaw end
	function object:set_animation(frames, speed, blend)
		self.animation = { frames = frames, speed = speed, blend = blend }
	end
	function object:set_properties(props) self.props = props end
	function object:get_properties() return self.props end
	function object:set_armor_groups(groups) self.armor_groups = groups end
	function object:get_hp() return self.hp end
	function object:set_hp(hp)
		self.hp = hp
		if hp <= 0 then
			local def = self.lua and _G.STUB.registered_entities[self.lua_name]
			if def and def.on_death and self.lua then def.on_death(self.lua, nil) end
		end
	end
	function object:get_luaentity() return self.lua end
	function object:remove()
		self.removed = true
		local def = self.lua and _G.STUB.registered_entities[self.lua_name]
		if def and def.on_deactivate and self.lua then def.on_deactivate(self.lua, true) end
	end
	return object
end
stub.make_object = make_object

function stub.add_player(name, pos, opts)
	opts = opts or {}
	local player = {
		name = name,
		pos = copy_pos(pos) or { x = 0.5, y = 1, z = 0.5 },
		wielded = new_stack(opts.wielded or "", opts.count or 1),
		privs = opts.privs or { server = true, interact = true, shout = true },
		formspec = nil,
	}
	function player:get_player_name() return self.name end
	function player:get_pos() return copy_pos(self.pos) end
	function player:set_pos(pos) self.pos = copy_pos(pos) end
	function player:is_player() return true end
	function player:get_wielded_item() return new_stack(self.wielded.item, self.wielded.count) end
	function player:set_wielded_item(stack) self.wielded = stack end
	function player:get_look_dir() return { x = 0, y = 0, z = 1 } end
	function player:get_player_control() return {} end
	stub.players[name] = player
	return player
end

-- Точки, где живут игроки и другие объекты, для get_objects_inside_radius.
function stub.set_item_entity(pos, itemstring)
	local obj = make_object({ itemstring = itemstring })
	obj.itemstring = itemstring
	obj.pos = copy_pos(pos)
	obj.is_item = true
	stub.objects[#stub.objects + 1] = obj
	return obj
end

-- ===========================================================================
-- Регистрация
-- ===========================================================================
stub.registered_entities = {}
stub.registered_items = {}
stub.registered_nodes = NODE_DEFS
stub.registered_craftitems = {}
stub.chatcommands = {}
stub.on_joinplayer = {}
stub.on_leaveplayer = {}
stub.on_receive_fields = {}
stub.on_chat_message = {}
stub.on_mods_loaded = {}
stub.on_shutdown = {}

stub.registered_items["default:apple"] = ITEM_DEFS["default:apple"]
stub.registered_items["default:stone"] = NODE_DEFS["default:stone"]
stub.registered_items["default:tree"] = NODE_DEFS["default:tree"]
stub.registered_items["default:torch"] = NODE_DEFS["default:torch"]
stub.registered_items["default:water_source"] = NODE_DEFS["default:water_source"]
for name, def in pairs(ITEM_DEFS) do stub.registered_items[name] = def end

local mt = {}
mt.registered_nodes = stub.registered_nodes
mt.registered_items = stub.registered_items

function mt.log(level, message)
	stub.logs[#stub.logs + 1] = { level = level, message = message }
end

function mt.colorize(color, text) return tostring(text) end
function mt.chat_send_player(name, message)
	stub.messages[#stub.messages + 1] = { to = name, message = message }
end

function mt.serialize(value)
	local parts = { "return " }
	serialize_value(value, {}, parts)
	return table.concat(parts)
end

function mt.deserialize(text)
	local loader = loadstring or load
	local chunk = loader and loader(text)
	if not chunk then return nil end
	local ok, result = pcall(chunk)
	if not ok then return nil end
	return result
end

function mt.formspec_escape(text)
	local escaped = tostring(text or "")
	escaped = escaped:gsub("%]", "\\]")
	escaped = escaped:gsub(";", "\\;")
	return escaped
end

function mt.get_gametime() return stub.time end
function mt.get_us_time() return stub.time * 1000000 end
function mt.get_timeofday() return 0.5 end
function mt.get_modpath(name)
	if name == "smart_npc" then return stub.modpath end
	return nil
end

stub.settings = {}
function stub.settings:get(name) return stub.settings_values[name] end
function stub.settings:get_bool(name)
	local value = stub.settings_values[name]
	if value == nil then return nil end
	return value == "true" or value == "1" or value == true
end
function stub.settings:get_float(name)
	local value = stub.settings_values[name]
	return value and tonumber(value) or nil
end
mt.settings = stub.settings

function mt.get_node(pos)
	if not pos then return { name = "ignore" } end
	return { name = stub.get_node_name(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)) }
end

function mt.get_node_light(pos)
	return 15
end

function mt.find_node_near(pos, radius, names, search_center)
	radius = math.floor(radius or 1)
	local wanted = {}
	for _, name in ipairs(names or {}) do wanted[name] = true end
	local cx, cy, cz = math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)
	local best, best_distance
	for x = cx - radius, cx + radius do
		for y = cy - radius, cy + radius do
			for z = cz - radius, cz + radius do
				local name = stub.get_node_name(x, y, z)
				if wanted[name] then
					local distance = (x - pos.x) ^ 2 + (y - pos.y) ^ 2 + (z - pos.z) ^ 2
					if not best_distance or distance < best_distance then
						best = { x = x, y = y, z = z }
						best_distance = distance
					end
				end
			end
		end
	end
	return best
end

function mt.find_path(from, to, search_distance, max_jump, max_drop)
	return { copy_pos(from), copy_pos(to) }
end

function mt.get_objects_inside_radius(pos, radius)
	local result = {}
	for _, obj in ipairs(stub.objects) do
		if not obj.removed and obj.pos then
			local dx, dy, dz = obj.pos.x - pos.x, obj.pos.y - pos.y, obj.pos.z - pos.z
			if dx * dx + dy * dy + dz * dz <= radius * radius then
				result[#result + 1] = obj
			end
		end
	end
	return result
end

function mt.add_particlespawner(spec)
	stub.particles = stub.particles + 1
	return stub.particles
end

function mt.sound_play(name, spec, ephemeral)
	stub.sounds = stub.sounds + 1
end

function mt.is_protected(pos, name) return false end
function mt.remove_node(pos)
	stub.nodes[key(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z))] = "air"
end
function mt.set_node(pos, node)
	stub.set_node(math.floor(pos.x), math.floor(pos.y), math.floor(pos.z), node.name)
end

function mt.get_item_group(name, group)
	local def = stub.registered_items[name] or stub.registered_nodes[name]
	return def and def.groups and def.groups[group] or 0
end

function mt.register_entity(name, def)
	stub.registered_entities[name] = def
end

function mt.register_craftitem(name, def)
	stub.registered_craftitems[name] = def
	stub.registered_items[name] = def
end

function mt.register_craft(def)
	stub.crafts = stub.crafts or {}
	stub.crafts[#stub.crafts + 1] = def
end

function mt.register_chatcommand(name, def)
	stub.chatcommands[name] = def
end

function mt.register_on_joinplayer(func) stub.on_joinplayer[#stub.on_joinplayer + 1] = func end
function mt.register_on_leaveplayer(func) stub.on_leaveplayer[#stub.on_leaveplayer + 1] = func end
function mt.register_on_player_receive_fields(func) stub.on_receive_fields[#stub.on_receive_fields + 1] = func end
function mt.register_on_chat_message(func) stub.on_chat_message[#stub.on_chat_message + 1] = func end
function mt.register_on_mods_loaded(func) stub.on_mods_loaded[#stub.on_mods_loaded + 1] = func end
function mt.register_on_shutdown(func) stub.on_shutdown[#stub.on_shutdown + 1] = func end

function mt.after(seconds, func)
	stub.timers[#stub.timers + 1] = { at = stub.time + (seconds or 0), func = func }
end

function mt.show_formspec(name, formname, formspec)
	stub.formspecs[#stub.formspecs + 1] = { to = name, formname = formname, formspec = formspec }
	local player = stub.players[name]
	if player then
		player.formspec = formspec
		player.formname = formname
	end
end

function mt.close_formspec(name, formname)
	local player = stub.players[name]
	if player then player.formspec = nil end
end

function mt.get_connected_players()
	local list = {}
	for _, player in pairs(stub.players) do
		if not player.offline then list[#list + 1] = player end
	end
	return list
end

function mt.get_player_by_name(name)
	local player = stub.players[name]
	if player and not player.offline then return player end
	return nil
end

function mt.get_player_privs(name)
	local player = stub.players[name]
	return player and player.privs or {}
end

function mt.check_player_privs(name, privs)
	local player_privs = mt.get_player_privs(name)
	for priv in pairs(privs or {}) do
		if not player_privs[priv] then return false, { missing = { priv } } end
	end
	return true
end

function mt.is_creative_enabled(name) return true end
function mt.dir_to_yaw(dir)
	if not dir then return 0 end
	return math.atan2 and math.atan2(dir.x, dir.z) or math.atan(dir.x, dir.z)
end

function mt.add_entity(pos, name, staticdata)
	local def = stub.registered_entities[name]
	if not def then return nil end
	local luaentity = { object = nil }
	local object = make_object(luaentity)
	object.lua_name = name
	luaentity.object = object
	object.pos = copy_pos(pos)
	local properties = def.initial_properties or {}
	object.props = properties
	object.hp = properties.hp_max or 100
	if def.on_activate then
		def.on_activate(luaentity, staticdata or "", 0)
	end
	return object
end

function mt.get_us_time_seconds() return stub.time end

_G.minetest = mt
_G.core = mt

-- ===========================================================================
-- Управление временем и вызовы
-- ===========================================================================
function stub.advance(seconds)
	stub.time = stub.time + (seconds or 0)
	local due = {}
	for i = #stub.timers, 1, -1 do
		if stub.timers[i].at <= stub.time then
			table.insert(due, 1, table.remove(stub.timers, i))
		end
	end
	for _, timer in ipairs(due) do timer.func() end
end

function stub.run_mods_loaded()
	for _, func in ipairs(stub.on_mods_loaded) do func() end
end

function stub.join_player(player)
	for _, func in ipairs(stub.on_joinplayer) do func(player) end
end

-- Список всех созданных через add_entity объектов.
stub.spawned_entities = {}
local original_add_entity = mt.add_entity
function mt.add_entity(pos, name, staticdata)
	local object = original_add_entity(pos, name, staticdata)
	if object then
		stub.spawned_entities[#stub.spawned_entities + 1] = object
	end
	return object
end

-- Простая физика: движок обычно сам двигает объект по velocity,
-- а для теста достаточно горизонтального перемещения по платформе.
function stub.step_all(dtime)
	for _, object in ipairs(stub.spawned_entities) do
		if not object.removed and object.lua then
			local def = stub.registered_entities[object.lua_name]
			if def and def.on_step then def.on_step(object.lua, dtime) end
			if not object.removed then
				local velocity = object.velocity or { x = 0, y = 0, z = 0 }
				object.pos.x = object.pos.x + (velocity.x or 0) * dtime
				object.pos.z = object.pos.z + (velocity.z or 0) * dtime
			end
		end
	end
end

function stub.receive_fields(player, formname, fields)
	for _, func in ipairs(stub.on_receive_fields) do func(player, formname, fields) end
end

function stub.chat(player_name, message)
	local handled = false
	for _, func in ipairs(stub.on_chat_message) do
		local result = func(player_name, message)
		if result == true then handled = true end
	end
	return handled
end

function stub.command(player_name, command_line)
	local command, param = command_line:match("^(%S+)%s*(.*)$")
	local def = stub.chatcommands[command]
	if not def then return false, "нет команды" end
	return def.func(player_name, param or "")
end

function stub.find_entity_by_brain(id)
	for _, object in ipairs(stub.spawned_entities) do
		if object.lua and object.lua._brain and object.lua._brain.id == id then
			return object.lua
		end
	end
	return nil
end

return stub
