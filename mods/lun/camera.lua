-- Luanti 5.12+: сервер фиксирует режим, стандартная клавиша камеры его не меняет.
local engine = minetest
local states = {}
local interval = 0.1
local return_delay = 0.8
local transition_duration = 0.35 -- плавный въезд камеры в голову
local offset_third = {x = 5, y = 3, z = 0} -- десятые доли блока: вправо и вверх (камера пониже)
local offset_first = {x = 0, y = 0, z = 0}

local function blocked(pos)
	local node = engine.get_node_or_nil(pos)
	if not node or node.name == "ignore" then
		return true
	end
	local def = engine.registered_nodes[node.name]
	return not def or def.walkable ~= false
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

local function lerp_offset(a, b, t)
	return {
		x = lerp(a.x, b.x, t),
		y = lerp(a.y, b.y, t),
		z = lerp(a.z, b.z, t),
	}
end

local function tall_wall_at(pos, dx, dz)
	local p1 = {x = pos.x + dx, y = pos.y + 1, z = pos.z + dz}
	local p2 = {x = pos.x + dx, y = pos.y + 2, z = pos.z + dz}
	return blocked(p1) and blocked(p2)
end

local function has_tall_wall_dir(pos, dx, dz)
	for d = 1, 2 do
		if tall_wall_at(pos, dx * d, dz * d) then
			return true
		end
	end
	return false
end

local function cramped(player)
	local pos = player:get_pos()
	local empty = 0
	for dy = 1, 4 do
		local p = {x = pos.x, y = pos.y + dy, z = pos.z}
		if blocked(p) then break end
		empty = empty + 1
	end
	if empty <= 2 then return true end
	local walls = 0
	if has_tall_wall_dir(pos, 1, 0) then walls = walls + 1 end
	if has_tall_wall_dir(pos, -1, 0) then walls = walls + 1 end
	if has_tall_wall_dir(pos, 0, 1) then walls = walls + 1 end
	if has_tall_wall_dir(pos, 0, -1) then walls = walls + 1 end
	if walls >= 2 then return true end
	return false
end

local function set_mode(player, state, mode)
	if state.mode ~= mode then
		player:set_camera({mode = mode})
		state.mode = mode
	end
end

local function apply_eye_offset(player, state)
	player:set_eye_offset({x = 0, y = 0, z = 0}, state.current, state.current)
end

engine.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local info = engine.get_player_information(name)
	if not player.set_camera or not info or info.protocol_version < 48 then
		engine.kick_player(name, "Для камеры Lun нужен клиент и сервер Luanti 5.12 или новее.")
		return
	end
	local init_first = cramped(player)
	local target = init_first and offset_first or offset_third
	local state = {
		clear_time = 0,
		mode = nil,
		current = {x = target.x, y = target.y, z = target.z},
		target = {x = target.x, y = target.y, z = target.z},
		transition = 1,
		transition_elapsed = 0,
		pending_mode = nil,
	}
	states[name] = state
	player:set_eye_offset({x = 0, y = 0, z = 0}, target, target)
	set_mode(player, state, init_first and "first" or "third")
end)

engine.register_on_leaveplayer(function(player)
	states[player:get_player_name()] = nil
end)

local elapsed = 0
engine.register_globalstep(function(dtime)
	elapsed = elapsed + dtime

	-- Плавная интерполяция каждый кадр
	for _, player in ipairs(engine.get_connected_players()) do
		local state = states[player:get_player_name()]
		if state and state.transition < 1 then
			state.transition_elapsed = state.transition_elapsed + dtime
			local t = math.min(state.transition_elapsed / transition_duration, 1)
			local eased = 1 - (1 - t) * (1 - t) * (1 - t) -- ease-out cubic
			if state.start then
				state.current = lerp_offset(state.start, state.target, eased)
			else
				state.current = lerp_offset(state.current, state.target, eased)
			end
			apply_eye_offset(player, state)
			if t >= 1 then
				state.transition = 1
				state.current = {x = state.target.x, y = state.target.y, z = state.target.z}
				state.start = nil
				apply_eye_offset(player, state)
				-- Если был отложенный переход в первое лицо (камера въехала в голову), переключаем режим сейчас
				if state.pending_mode then
					set_mode(player, state, state.pending_mode)
					state.pending_mode = nil
				end
			else
				state.transition = t
			end
		end
	end

	if elapsed < interval then return end
	local delta = elapsed
	elapsed = 0

	for _, player in ipairs(engine.get_connected_players()) do
		local state = states[player:get_player_name()]
		if state then
			-- Если уже идёт плавный въезд в голову, не начинаем новый переход
			if state.transition < 1 then
				-- Но если цель изменилась во время перехода, можно переопределить?
				-- Для простоты пропускаем проверку cramped до завершения перехода
			else
				local should_cramped = cramped(player)
				local desired_mode = should_cramped and "first" or "third"
				local desired_offset = should_cramped and offset_first or offset_third

				if should_cramped then
					state.clear_time = 0
					if state.mode ~= desired_mode then
						-- Третье -> первое: камера плавно въезжает в голову, переход режима В КОНЦЕ
						state.start = {x = state.current.x, y = state.current.y, z = state.current.z}
						state.target = desired_offset
						state.transition = 0
						state.transition_elapsed = 0
						state.pending_mode = desired_mode -- отложенный set_camera
						-- mode остаётся "third" пока камера едет, переключится в конце интерполяции
					end
				else
					state.clear_time = state.clear_time + delta
					if state.clear_time >= return_delay then
						if state.mode ~= desired_mode then
							-- Первое -> третье: сразу переключаем в третье, затем плавно выезжаем
							set_mode(player, state, desired_mode)
							state.start = {x = state.current.x, y = state.current.y, z = state.current.z}
							state.target = desired_offset
							state.transition = 0
							state.transition_elapsed = 0
							state.pending_mode = nil
						end
					end
				end
			end
		end
	end
end)
