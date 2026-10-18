-- Luanti 5.12+: сервер фиксирует режим, стандартная клавиша камеры его не меняет.
local engine = minetest
local states = {}
local interval = 0.1
local return_delay = 0.8
local offset = {x = 5, y = 8, z = 0} -- десятые доли блока: вправо и вверх

local function blocked(pos)
	local node = engine.get_node_or_nil(pos)
	if not node or node.name == "ignore" then
		return true -- не показываем камеру внутри ещё не загруженной области
	end
	local def = engine.registered_nodes[node.name]
	return not def or def.walkable ~= false
end

local function obstructed(from, to)
	-- Несколько лучей учитывают не только центр, но и края камеры.
	for _, shift in ipairs({
		{x = 0, y = 0, z = 0},
		{x = 0.2, y = 0, z = 0}, {x = -0.2, y = 0, z = 0},
		{x = 0, y = 0.2, z = 0},
		{x = 0, y = 0, z = 0.2}, {x = 0, y = 0, z = -0.2},
	}) do
		local start = vector.add(from, shift)
		local finish = vector.add(to, shift)
		if blocked(finish) then
			return true
		end
		for hit in engine.raycast(start, finish, false, false) do
			if hit.type == "node" and blocked(hit.under) then
				return true
			end
		end
	end
	return false
end

local function cramped(player)
	local pos = player:get_pos()
	local props = player:get_properties()
	local eye = vector.add(pos, {x = 0, y = props.eye_height or 1.625, z = 0})
	local yaw = player:get_look_horizontal()
	local right = {x = math.cos(yaw), y = 0, z = math.sin(yaw)}
	local pivot = vector.add(eye, vector.add(vector.multiply(right, offset.x / 10),
		{x = 0, y = offset.y / 10, z = 0}))
	local camera = vector.subtract(pivot, vector.multiply(player:get_look_dir(), 2.75))
	if obstructed(eye, pivot) or obstructed(pivot, camera) then
		return true
	end
	-- Низкий потолок или стены с обеих сторон: первый вид даже при взгляде к выходу.
	if obstructed(eye, vector.add(eye, {x = 0, y = 1, z = 0})) then
		return true
	end
	return obstructed(eye, vector.add(eye, vector.multiply(right, 1)))
		and obstructed(eye, vector.subtract(eye, right))
end

local function set_mode(player, state, mode)
	if state.mode ~= mode then
		player:set_camera({mode = mode})
		state.mode = mode
	end
end

engine.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local info = engine.get_player_information(name)
	if not player.set_camera or not info or info.protocol_version < 48 then
		engine.kick_player(name, "Для камеры Lun нужен клиент и сервер Luanti 5.12 или новее.")
		return
	end
	local state = {clear_time = 0}
	states[name] = state
	player:set_eye_offset({x = 0, y = 0, z = 0}, offset, offset)
	-- Вход безопасен даже в закрытом помещении или до загрузки чанков.
	set_mode(player, state, cramped(player) and "first" or "third")
end)

engine.register_on_leaveplayer(function(player)
	states[player:get_player_name()] = nil
end)

local elapsed = 0
engine.register_globalstep(function(dtime)
	elapsed = elapsed + dtime
	if elapsed < interval then
		return
	end
	local delta = elapsed
	elapsed = 0
	for _, player in ipairs(engine.get_connected_players()) do
		local state = states[player:get_player_name()]
		if state then
			if cramped(player) then
				state.clear_time = 0
				set_mode(player, state, "first")
			else
				state.clear_time = state.clear_time + delta
				if state.clear_time >= return_delay then
					set_mode(player, state, "third")
				end
			end
		end
	end
end)
