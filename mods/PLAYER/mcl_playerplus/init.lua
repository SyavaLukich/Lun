--[[
mcl_playerplus - Player character controller part, standalone version.

Allowed dependencies: mcl_player, mcl_playerinfo, mcl_sprint, playerphysics.
Optional: mcl_hunger, mcl_enchanting, mcl_weather, mcl_shields, mcl_damage, mcl_portals.
]]

mcl_playerplus = {
	elytra = {},
	is_pressing_jump = {},
}

local get_connected_players = minetest.get_connected_players
local dir_to_yaw = minetest.dir_to_yaw
local get_item_group = minetest.get_item_group
local check_player_privs = minetest.check_player_privs
local get_name_from_content_id = minetest.get_name_from_content_id
local get_voxel_manip = minetest.get_voxel_manip
local add_particle = minetest.add_particle
local add_particlespawner = minetest.add_particlespawner
local get_us_time = minetest.get_us_time
local find_nodes_in_area = minetest.find_nodes_in_area

local is_sprinting = mcl_sprint.is_sprinting

-- Optional integrations
local exhaust               = mcl_hunger and mcl_hunger.exhaust
local EXHAUST_SPRINT_JUMP   = mcl_hunger and mcl_hunger.EXHAUST_SPRINT_JUMP
local EXHAUST_JUMP          = mcl_hunger and mcl_hunger.EXHAUST_JUMP
local EXHAUST_SWIM          = mcl_hunger and mcl_hunger.EXHAUST_SWIM

local get_enchantment       = mcl_enchanting and mcl_enchanting.get_enchantment
local update_sky_color      = mcl_weather and mcl_weather.skycolor and mcl_weather.skycolor.update_sky_color
local shields_is_blocking   = mcl_shields and mcl_shields.is_blocking
local portals_end_teleport  = mcl_portals and mcl_portals.end_teleport

local vector = vector
local math = math
local PI = math.pi
local TWOPI = math.pi * 2

-- Inline replacements for mcl_util helpers
local function set_bone_position(player, bonename, pos, rot, scale)
	return player:set_bone_position(bonename, pos, rot, scale)
end

local function set_properties(player, props)
	return player:set_properties(props)
end

local function deal_damage(player, damage)
	if player:get_hp() <= 0 then return end
	player:set_hp(player:get_hp() - damage)
end

-- Internal player state
local mcl_playerplus_internal = {}
local managed_crosshair = {}
local crosshair_textures = {
	ready = "crosshair.png",
	recovering = "crosshair.png^[colorize:#ff4040:180",
}

local function get_recovery_punch_interval(itemstack)
	local caps = itemstack:get_tool_capabilities()
	local interval = caps and caps.full_punch_interval
	if not interval or interval <= 0 then return end
	return interval
end

local function is_crosshair_hidden(state)
	for _, hidden in pairs(state.hidden_by) do
		if hidden then return true end
	end
	return false
end

local function get_managed_crosshair_texture(state)
	if is_crosshair_hidden(state) then return "blank.png" end
	return state.is_recovering and crosshair_textures.recovering or crosshair_textures.ready
end

local function update_managed_crosshair(player, state)
	local texture = get_managed_crosshair_texture(state)
	if state.texture ~= texture then
		state.texture = texture
		player:hud_change(state.hud_id, "text", texture)
	end
end

local function set_managed_crosshair_recovering(player, state, is_recovering)
	if state.is_recovering == is_recovering then return end
	state.is_recovering = is_recovering
	update_managed_crosshair(player, state)
end

local function create_managed_crosshair(player)
	local name = player:get_player_name()
	if managed_crosshair[name] then return end

	local state = {
		is_recovering = false,
		hidden_by = {},
	}
	state.texture = get_managed_crosshair_texture(state)
	state.hud_id = player:hud_add({
		type = "image",
		position = {x = 0.5, y = 0.5},
		scale = {x = 1, y = 1},
		text = state.texture,
		z_index = -100,
	})
	managed_crosshair[name] = state
	player:hud_set_flags({crosshair = false})
end

mcl_playerplus.crosshair = {}

function mcl_playerplus.crosshair.set_textures(ready_texture, recovering_texture)
	if ready_texture then crosshair_textures.ready = ready_texture end
	if recovering_texture then crosshair_textures.recovering = recovering_texture end
end

function mcl_playerplus.crosshair.get_textures()
	return table.copy(crosshair_textures)
end

function mcl_playerplus.crosshair.set_hidden(player, source, hidden)
	local state = managed_crosshair[player:get_player_name()]
	if not state then return end
	state.hidden_by[source] = hidden or nil
	update_managed_crosshair(player, state)
end

local function start_recovery_crosshair(player)
	local wielded = player:get_wielded_item()
	if not get_recovery_punch_interval(wielded) then return end

	local state = managed_crosshair[player:get_player_name()]
	if not state then return end
	state.last_swing = get_us_time()
	set_managed_crosshair_recovering(player, state, true)
end

-- Elytra tuning
local elytra_vars = {
	slowdown_mult = 0.0,
	fall_speed = 0.2,
	speedup_mult = 2,
	max_speed = tonumber(minetest.settings:get("mcl_elytra_max_speed")) or 4.0,
	pitch_penalty = 1.3,
	rocket_speed = tonumber(minetest.settings:get("mcl_elytra_rocket_speed")) or 3.5,
}

local time = 0

local function player_collision(player)
	local pos = player:get_pos()
	local x = 0
	local z = 0
	local width = .75

	for _, object in pairs(minetest.get_objects_inside_radius(pos, width)) do
		local ent = object:get_luaentity()
		if object:is_player() or (ent and ent.is_mob and object ~= player) then
			local pos2 = object:get_pos()
			local vec  = {x = pos.x - pos2.x, z = pos.z - pos2.z}
			local force = (width + 0.5) - vector.distance(
				{x = pos.x, y = 0, z = pos.z},
				{x = pos2.x, y = 0, z = pos2.z})
			x = x + (vec.x * force)
			z = z + (vec.z * force)
		end
	end
	return {x, z}
end

local function dir_to_pitch(dir)
	return -math.atan2(-dir.y, math.sqrt(dir.x * dir.x + dir.z * dir.z))
end

local player_vel_yaws = {}

function limit_vel_yaw(player_vel_yaw, yaw)
	player_vel_yaw = player_vel_yaw % TWOPI
	yaw = yaw % TWOPI

	if math.abs(player_vel_yaw - yaw) > 0.7 then
		local player_vel_yaw_nm, yaw_nm = player_vel_yaw, yaw
		if player_vel_yaw > yaw then
			player_vel_yaw_nm = player_vel_yaw - TWOPI
		else
			yaw_nm = yaw - TWOPI
		end
		if math.abs(player_vel_yaw_nm - yaw_nm) > 0.7 then
			local diff = math.abs(player_vel_yaw - yaw)
			if diff > PI and diff < 3.229 or diff < PI and diff > 3.054 then
				player_vel_yaw = yaw
			elseif diff < PI then
				if player_vel_yaw < yaw then
					player_vel_yaw = yaw - 0.7
				else
					player_vel_yaw = yaw + 0.7
				end
			else
				if player_vel_yaw < yaw then
					player_vel_yaw = yaw + 0.7
				else
					player_vel_yaw = yaw - 0.7
				end
			end
		end
	end
	return player_vel_yaw % TWOPI
end

local is_swimming

-- Bone rotation workaround for the b3d character model
local bone_workaround_scales = {
	Body_Control = vector.new(-1, 1, -1),
	Leg_Right = vector.new(1, -1, -1),
	Leg_Left = vector.new(1, -1, -1),
	Cape = vector.new(1, -1, 1),
	Arm_Right_Pitch_Control = vector.new(1, -1, -1),
	Arm_Left_Pitch_Control = vector.new(1, -1, -1),
}

local function set_bone_pos(player, bonename, pos, rot, scale, interpolation)
	if not player or not bonename then return end
	-- По умолчанию сглаживаем ~0.1 с (один серверный тик).
	-- Без этого set_bone_override щёлкает костью между тиками → рывки.
	interpolation = interpolation or 0.1
	if player.set_bone_override then
		local override = {}
		if pos then
			override.position = { vec = pos, absolute = true, interpolation = interpolation }
		end
		if rot then
			override.rotation = { vec = rot, absolute = true, interpolation = interpolation }
		end
		local s = scale or bone_workaround_scales[bonename]
		if s then
			override.scale = { vec = s, absolute = true, interpolation = interpolation }
		end
		player:set_bone_override(bonename, override)
	else
		player:set_bone_position(
			bonename,
			pos or vector.zero(),
			rot or vector.zero(),
			scale or bone_workaround_scales[bonename]
		)
	end
end

local function anglediff(a1, a2)
	local a = a1 - a2
	return math.abs((a + math.pi) % (math.pi * 2) - math.pi)
end

local function clamp(num, min, max)
	return math.min(max, math.max(num, min))
end

local player_props_elytra = {
	collisionbox = { -0.35, 0, -0.35, 0.35, 0.8, 0.35 },
	eye_height = 0.6,
	nametag_color = { r = 225, b = 225, a = 225, g = 225 }
}
local player_props_riding = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 1.8, 0.312 },
	eye_height = 1.6,
	nametag_color = { r = 225, b = 225, a = 225, g = 225 }
}
local player_props_sneaking = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 1.8, 0.312 },
	eye_height = 1.45,
	nametag_color = { r = 225, b = 225, a = 0, g = 225 }
}
local player_props_swimming = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 0.8, 0.312 },
	eye_height = 0.6,
	nametag_color = { r = 225, b = 225, a = 225, g = 225 }
}
local player_props_normal = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 1.8, 0.312 },
	eye_height = 1.6,
	nametag_color = { r = 225, b = 225, a = 225, g = 225 }
}

local function ensure_player_state(player)
	local name = player:get_player_name()
	if not mcl_playerplus_internal[name] then
		mcl_playerplus_internal[name] = {
			lastPos = nil,
			swimDistance = 0,
			jump_cooldown = -1,
			last_damage = 0,
			invul_timestamp = 0,
			lmb_pressed = false,
			rocket_particle_timer = 0,
		}
		mcl_playerplus.elytra[player] = {active = false, rocketing = 0, speed = 0}
		create_managed_crosshair(player)
	end
end

minetest.register_globalstep(function(dtime)

	time = time + dtime

	for _, player in pairs(get_connected_players()) do
		ensure_player_state(player)

		local name = player:get_player_name()
		local control = player:get_player_control()
		local parent = player:get_attach()
		local wielded = player:get_wielded_item()
		local player_velocity = player:get_velocity() or player:get_player_velocity()
		local wielded_def = wielded:get_definition() or {}

		-- LMB press detection (replaces controls.register_on_press)
		local internal = mcl_playerplus_internal[name]
		local was_lmb = internal.lmb_pressed
		internal.lmb_pressed = control.LMB
		if control.LMB and not was_lmb then
			start_recovery_crosshair(player)
		end

		local crosshair_state = managed_crosshair[name]
		if crosshair_state and crosshair_state.last_swing then
			local interval = get_recovery_punch_interval(wielded)
			if not interval then
				crosshair_state.last_swing = nil
				set_managed_crosshair_recovering(player, crosshair_state, false)
			else
				local elapsed = (get_us_time() - crosshair_state.last_swing) / 1000000
				local progress = elapsed / interval
				set_managed_crosshair_recovering(player, crosshair_state, progress < 1)
			end
		end

		local c_x, c_y = unpack(player_collision(player))

		if player_velocity.x + player_velocity.y < .5 and c_x + c_y > 0 then
			player:add_velocity({x = c_x, y = 0, z = c_y})
			player_velocity = player:get_velocity() or player:get_player_velocity()
		end

		local pitch = -player:get_look_vertical()
		local yaw = player:get_look_horizontal()

		local player_vel_yaw = dir_to_yaw(player_velocity)
		if player_vel_yaw == 0 then
			player_vel_yaw = player_vel_yaws[name] or yaw
		end
		player_vel_yaw = limit_vel_yaw(player_vel_yaw, yaw)
		player_vel_yaws[name] = player_vel_yaw

		local fly_pos = player:get_pos()
		local fly_node = minetest.get_node({x = fly_pos.x, y = fly_pos.y - 0.1, z = fly_pos.z}).name
		local elytra = mcl_playerplus.elytra[player]

		if not elytra.active then
			elytra.speed = 0
		end

		if not elytra.last_yaw then
			elytra.last_yaw = player:get_look_horizontal()
		end

		local is_just_jumped = control.jump and not mcl_playerplus.is_pressing_jump[name] and not elytra.active
		mcl_playerplus.is_pressing_jump[name] = control.jump
		if is_just_jumped and not elytra.active then
			local direction = player:get_look_dir()
			elytra.speed = 1 - (direction.y / 2 + 0.5)
		end

		local fly_node_walkable = minetest.registered_nodes[fly_node] and minetest.registered_nodes[fly_node].walkable
		local armor_elytra = minetest.get_item_group(player:get_inventory():get_stack("armor", 3):get_name(), "elytra")
		elytra.active = armor_elytra ~= 0
			and not parent
			and (elytra.active or (is_just_jumped and player_velocity.y < -0))
			and ((not fly_node_walkable) or fly_node == "ignore")

		if elytra.active then
			if is_just_jumped then
				player:set_pos(vector.offset(player:get_pos(), 0, 0.8, 0))
			end
			if mcl_player and mcl_player.player_set_animation then
				mcl_player.player_set_animation(player, "fly")
			end
			local direction = player:get_look_dir()
			local player_vel = player:get_velocity()
			local turn_amount = anglediff(minetest.dir_to_yaw(direction), minetest.dir_to_yaw(player_vel))
			local direction_mult = clamp(-(direction.y + 0.1), -1, 1)
			if direction_mult < 0 then direction_mult = direction_mult * elytra_vars.pitch_penalty end

			local speed_mult = elytra.speed
			local block_below = minetest.get_node(vector.offset(fly_pos, 0, -0.9, 0)).name
			local reg_node_below = minetest.registered_nodes[block_below]
			if reg_node_below and not reg_node_below.walkable and player_vel.y ~= 0 then
				speed_mult = speed_mult + direction_mult * elytra_vars.speedup_mult * dtime
			end
			speed_mult = speed_mult - elytra_vars.slowdown_mult * clamp(dtime, 0.09, 0.2)
			speed_mult = clamp(speed_mult, -elytra_vars.max_speed, elytra_vars.max_speed)
			if turn_amount > 0.3 and math.abs(direction.y) < 0.98 then
				speed_mult = speed_mult - (speed_mult * (turn_amount / (math.pi * 8)))
			end

			playerphysics.add_physics_factor(player, "gravity", "mcl_playerplus:elytra", elytra_vars.fall_speed)
			if elytra.rocketing > 0 then
				elytra.rocketing = elytra.rocketing - dtime
				if vector.length(player_velocity) < 40 then
					speed_mult = elytra_vars.rocket_speed

					internal.rocket_particle_timer = internal.rocket_particle_timer + dtime
					if internal.rocket_particle_timer >= 0.3 then
						internal.rocket_particle_timer = 0
						add_particle({
							pos = fly_pos,
							velocity = vector.zero(),
							acceleration = vector.zero(),
							expirationtime = 0.3 + math.random() * 0.2,
							size = math.random(1, 2),
							collisiondetection = false,
							vertical = false,
							texture = "mcl_particles_bonemeal.png^[colorize:#bc7a57:127",
							glow = 5,
						})
					end
				end
			end

			elytra.speed = speed_mult

			local new_vel = vector.multiply(direction, speed_mult * dtime * 30)
			player_vel = vector.multiply(player_vel, -0.1)
			new_vel = vector.add(new_vel, player_vel)

			player:add_velocity(new_vel)
		else
			elytra.rocketing = 0
			playerphysics.remove_physics_factor(player, "gravity", "mcl_playerplus:elytra")
		end

		-- Wield item / spear / bow / crossbow poses
		local wname = wielded:get_name()
		if control.RMB and get_item_group(wname, "spear") > 0 then
			set_bone_pos(player, "Wield_Item", vector.new(0, 5.2, 1.2), vector.new(-1.57, 5.7, 1.57))
		elseif wielded_def and wielded_def._mcl_toollike_wield then
			set_bone_pos(player, "Wield_Item", vector.new(0, 4.7, 3.1), vector.new(-1.57, 3.93, 1.57))
		elseif string.find(wname, "mcl_bows:bow") then
			set_bone_pos(player, "Wield_Item", vector.new(1, 4, 0), vector.new(1.57, 2.27, 2.01))
		elseif string.find(wname, "mcl_bows:crossbow_loaded") then
			set_bone_pos(player, "Wield_Item", vector.new(0, 5.2, 1.2), vector.new(0, 3.1415, 1.27))
		elseif string.find(wname, "mcl_bows:crossbow") then
			set_bone_pos(player, "Wield_Item", vector.new(0, 5.2, 1.2), vector.new(0, 3.1415, 0.78))
		elseif wielded_def.inventory_image == "" then
			set_bone_pos(player, "Wield_Item", vector.new(0, 6, 2), vector.new(3.1415, -0.785, 0))
		else
			set_bone_pos(player, "Wield_Item", vector.new(0, 5.3, 2), vector.new(1.57, 0, 0))
		end

		local blocking = shields_is_blocking and shields_is_blocking(player)
		if blocking == 2 then
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(0.35, -0.35, 0))
		elseif blocking == 1 then
			set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.new(0.35, 0.35, 0))
		elseif string.find(wname, "mcl_bows:bow") and control.RMB then
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(pitch + 1.57, -0.524, pitch * -1 * .35))
			set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.new(pitch + 1.57, 0.75, pitch * .35))
		elseif string.find(wname, "mcl_bows:crossbow_loaded") then
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(pitch + 1.57, -0.524, pitch * -1 * .35))
			set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.new(pitch + 1.57, 0.75, pitch * .35))
		elseif get_item_group(wname, "spear") > 0 and control.RMB then
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(pitch + 1.8, 0, pitch * -1 * .35))
		elseif string.find(wname, "mcl_bows:crossbow_") then
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(0.786, -0.35, 0.47))
			set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.new(0.96, 0.35, -0.786))
		elseif control.LMB and not parent then
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(pitch, 0, 0))
			set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.zero())
		elseif wname ~= "" then
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(0.35, 0, 0))
			set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.zero())
		else
			set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.zero())
			set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.zero())
		end

		-- Head / body poses based on state
		local playerinfo = mcl_playerinfo[name]
		if playerinfo then
			local head_node = playerinfo.node_head
			local head_top_node = playerinfo.node_head_top

			if elytra.active then
				set_bone_pos(player, "Head_Control", nil,
					vector.new(pitch - dir_to_pitch(player_velocity) + 0.87, player_vel_yaw - yaw, 0))
				set_properties(player, player_props_elytra)
				set_bone_pos(player, "Body_Control", nil,
					vector.new(dir_to_pitch(player_velocity) + 1.92, -player_vel_yaw + yaw, 3.1415),
					vector.new(-1, 1, 1))
			elseif parent then
				set_properties(player, player_props_riding)
				local parent_yaw = parent:get_yaw()
				set_bone_pos(player, "Head_Control", nil,
					vector.new(pitch, -limit_vel_yaw(yaw, parent_yaw) + parent_yaw, 0))
				set_bone_pos(player, "Body_Control", nil, vector.zero())
			elseif control.sneak then
				set_bone_pos(player, "Head_Control", nil,
					vector.new(pitch, player_vel_yaw - yaw, player_vel_yaw - yaw))
				set_properties(player, player_props_sneaking)
				set_bone_pos(player, "Body_Control", nil,
					vector.new(0, -player_vel_yaw + yaw, 0))
			elseif head_node and get_item_group(head_node, "water") ~= 0 and is_sprinting(name) == true then
				is_swimming = true
				set_bone_pos(player, "Head_Control", nil,
					vector.new(pitch - dir_to_pitch(player_velocity) + 0.35, player_vel_yaw - yaw, 0))
				set_properties(player, player_props_swimming)
				set_bone_pos(player, "Body_Control", nil,
					vector.new(1.3 + dir_to_pitch(player_velocity), player_vel_yaw - yaw, 3.1415),
					vector.new(-1, 1, 1))
			elseif head_node and head_top_node
				and get_item_group(head_node, "solid") == 0
				and get_item_group(head_top_node, "solid") == 0 then
				is_swimming = false
				set_properties(player, player_props_normal)
				set_bone_pos(player, "Head_Control", nil,
					vector.new(pitch, player_vel_yaw - yaw, 0))
				set_bone_pos(player, "Body_Control", nil,
					vector.new(0, -player_vel_yaw + yaw, 0))
			end

			local plusinfo = playerinfo.mcl_playerplus
			if not plusinfo then
				plusinfo = {}
				playerinfo.mcl_playerplus = plusinfo
			end

			if plusinfo.old_node_head ~= playerinfo.node_head then
				local new_head = playerinfo.node_head or ""
				local old_head = plusinfo.old_node_head or ""
				plusinfo.old_node_head = playerinfo.node_head

				if update_sky_color
					and (get_item_group(new_head, "water") == 0) ~= (get_item_group(old_head, "water") == 0) then
					update_sky_color()
				end
			end
		end

		elytra.last_yaw = player:get_look_horizontal()

		-- Jump exhaustion
		if internal.jump_cooldown > 0 then
			internal.jump_cooldown = internal.jump_cooldown - dtime
		end

		if control.jump and internal.jump_cooldown <= 0 and playerinfo then
			local node_stand       = playerinfo.node_stand
			local node_stand_below = playerinfo.node_stand_below
			local node_head        = playerinfo.node_head
			local node_feet        = playerinfo.node_feet
			local node_head_top    = playerinfo.node_head_top

			if node_stand and node_stand_below and node_head and node_feet
				and minetest.registered_nodes[node_stand]
				and minetest.registered_nodes[node_stand_below]
				and minetest.registered_nodes[node_head]
				and minetest.registered_nodes[node_feet]
				and minetest.registered_nodes[node_head_top]
				and get_item_group(node_feet, "liquid") == 0
				and get_item_group(node_stand, "liquid") == 0
				and not minetest.registered_nodes[node_feet].climbable
				and not minetest.registered_nodes[node_stand].climbable
				and (minetest.registered_nodes[node_stand].walkable
					or minetest.registered_nodes[node_stand_below].walkable)
				and get_item_group(node_stand, "disable_jump") == 0
				and get_item_group(node_stand_below, "disable_jump") == 0 then

				if exhaust then
					if is_sprinting(name) then
						exhaust(name, EXHAUST_SPRINT_JUMP)
					else
						exhaust(name, EXHAUST_JUMP)
					end
				end
				internal.jump_cooldown = 0.45
			end
		end
	end

	-- Slower tick (0.5 s)
	if time < 0.5 then
		return
	end
	time = 0

	for _, player in pairs(get_connected_players()) do
		local name = player:get_player_name()
		local pos = player:get_pos()

		local playerinfo = mcl_playerinfo[name]
		if not playerinfo then
			-- skip
		else
			local node_stand       = playerinfo.node_stand
			local node_stand_below = playerinfo.node_stand_below
			local node_head        = playerinfo.node_head
			local node_feet        = playerinfo.node_feet
			local node_head_top    = playerinfo.node_head_top

			if not node_stand or not node_stand_below or not node_head or not node_feet or not node_head_top then
				-- skip
			else
				-- Optional enchantment bonuses
				local soul_speed, depth_strider, swift_sneak = 0, 0, 0
				if get_enchantment then
					local boots = player:get_inventory():get_stack("armor", 5)
					soul_speed = get_enchantment(boots, "soul_speed") or 0
					depth_strider = get_enchantment(boots, "depth_strider") or 0
					local leggings = player:get_inventory():get_stack("armor", 4)
					swift_sneak = get_enchantment(leggings, "swift_sneak") or 0
				end

				-- Soul sand / soul speed
				if get_item_group(node_stand, "soul_block") ~= 0 then
					if node_stand == "mcl_nether:soul_sand" then
						if soul_speed > 0 then
							playerphysics.add_physics_factor(player, "speed", "mcl_playerplus:soul_speed", soul_speed * 0.105 + 1.3)
						else
							if node_stand_below == "mcl_core:ice"
								or node_stand_below == "mcl_core:packed_ice"
								or node_stand_below == "mcl_core:slimeblock"
								or node_stand_below == "mcl_core:water_source" then
								playerphysics.add_physics_factor(player, "speed", "mcl_playerplus:soul_speed", 0.1)
							else
								playerphysics.add_physics_factor(player, "speed", "mcl_playerplus:soul_speed", 0.4)
							end
						end
					elseif soul_speed > 0 then
						playerphysics.add_physics_factor(player, "speed", "mcl_playerplus:soul_speed", soul_speed * 0.105 + 1.3)
					end
				else
					playerphysics.remove_physics_factor(player, "speed", "mcl_playerplus:soul_speed")
				end

				-- Depth strider
				if get_item_group(node_feet, "liquid") ~= 0 and depth_strider > 0 then
					playerphysics.add_physics_factor(player, "speed", "mcl_playerplus:depth_strider", (depth_strider / 3) + 0.75)
				else
					playerphysics.remove_physics_factor(player, "speed", "mcl_playerplus:depth_strider")
				end

				-- Swift sneak
				if swift_sneak > 0 then
					playerphysics.add_physics_factor(player, "speed_crouch", "mcl_playerplus:swift_sneak", (swift_sneak / 2) + 1)
				else
					playerphysics.remove_physics_factor(player, "speed_crouch", "mcl_playerplus:swift_sneak")
				end

				-- Suffocation
				local ndef = minetest.registered_nodes[node_head]
				if is_swimming then
					ndef = minetest.registered_nodes[node_feet]
				end
				if ndef
					and (ndef.walkable == nil or ndef.walkable == true)
					and (ndef.collision_box == nil or ndef.collision_box.type == "regular")
					and (ndef.node_box == nil or ndef.node_box.type == "regular")
					and ndef.groups and ndef.groups.disable_suffocation ~= 1
					and ndef.groups.opaque == 1
					and node_head ~= "ignore"
					and not check_player_privs(name, {noclip = true}) then
					deal_damage(player, 1)
				end

				-- Cactus damage
				if node_stand == "mcl_core:cactus" or node_feet == "mcl_core:cactus" or node_head == "mcl_core:cactus" then
					deal_damage(player, 1)
				else
					local ncw = 1 - 0.75
					if find_nodes_in_area(
						vector.offset(pos, ncw, 0, ncw),
						vector.offset(pos, -ncw, 0, -ncw),
						"mcl_core:cactus")[1] then
						deal_damage(player, 1)
					end
				end

				-- Swimming exhaustion
				if not player:get_attach()
					and (get_item_group(node_feet, "liquid") ~= 0
						or get_item_group(node_stand, "liquid") ~= 0) then
					local lastPos = mcl_playerplus_internal[name].lastPos
					if lastPos and exhaust then
						local dist = vector.distance(lastPos, pos)
						local internal = mcl_playerplus_internal[name]
						internal.swimDistance = internal.swimDistance + dist
						if internal.swimDistance >= 1 then
							local superficial = math.floor(internal.swimDistance)
							exhaust(name, EXHAUST_SWIM * superficial)
							internal.swimDistance = internal.swimDistance - superficial
						end
					end
				end

				-- Underwater bubbles
				if get_item_group(node_head, "water") ~= 0 then
					add_particlespawner({
						amount = 10,
						time = 0.15,
						minpos = { x = -0.25, y = 0.3, z = -0.25 },
						maxpos = { x = 0.25, y = 0.7, z = 0.75 },
						attached = player,
						minvel = {x = -0.2, y = 0, z = -0.2},
						maxvel = {x = 0.5, y = 0, z = 0.5},
						minacc = {x = -0.4, y = 4, z = -0.4},
						maxacc = {x = 0.5, y = 1, z = 0.5},
						minexptime = 0.3,
						maxexptime = 0.8,
						minsize = 0.7,
						maxsize = 2.4,
						texture = "mcl_particles_bubble.png"
					})
				end

				-- Barrier / light block preview
				local wi = player:get_wielded_item():get_name()
				if wi == "mcl_core:barrier" or wi == "mcl_core:realm_barrier"
					or minetest.get_item_group(wi, "light_block") ~= 0 then
					local rpos = vector.round(pos)
					local r = 8
					local vm = get_voxel_manip()
					local emin, emax = vm:read_from_map(
						{x = rpos.x-r, y = rpos.y-r, z = rpos.z-r},
						{x = rpos.x+r, y = rpos.y+r, z = rpos.z+r})
					local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
					local data = vm:get_data()
					for x = rpos.x-r, rpos.x+r do
					for y = rpos.y-r, rpos.y+r do
					for z = rpos.z-r, rpos.z+r do
						local vi = area:indexp({x=x, y=y, z=z})
						local nodename = get_name_from_content_id(data[vi])
						local lbg = minetest.get_item_group(nodename, "light_block")
						local tex
						if nodename == "mcl_core:barrier" then
							tex = "mcl_core_barrier.png"
						elseif nodename == "mcl_core:realm_barrier" then
							tex = "mcl_core_barrier.png^[colorize:#FF00FF:127^[transformFX"
						elseif lbg ~= 0 then
							tex = "mcl_core_light_" .. (lbg - 1) .. ".png"
						end
						if tex then
							add_particle({
								pos = {x=x, y=y, z=z},
								expirationtime = 1,
								size = 8,
								texture = tex,
								glow = 14,
								playername = name
							})
						end
					end
					end
					end
				end

				mcl_playerplus_internal[name].lastPos = pos
			end
		end
	end
end)

minetest.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local hp = player:get_hp()

	mcl_playerplus_internal[name] = {
		lastPos = nil,
		swimDistance = 0,
		jump_cooldown = -1,
		last_damage = 0,
		invul_timestamp = 0,
		lmb_pressed = false,
		rocket_particle_timer = 0,
	}
	mcl_playerplus.elytra[player] = {active = false, rocketing = 0, speed = 0}
	create_managed_crosshair(player)

	-- Warm-up pose (Luanti bone position limitation workaround)
	set_bone_pos(player, "Head_Control", vector.new(0, 6.75, 0))
	set_bone_pos(player, "Arm_Right_Pitch_Control", vector.new(-3, 5.785, 0))
	set_bone_pos(player, "Arm_Left_Pitch_Control", vector.new(3, 5.785, 0))
	set_bone_pos(player, "Body_Control", vector.new(0, 6.75, 0))

	if hp <= 0 then
		player:respawn()
		minetest.log("warning", name .. " joined the game with 0 hp and has been forced to respawn")
	end

	playerphysics.remove_physics_factor(player, "speed", "mcl_playerplus:surface")
end)

minetest.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	mcl_playerplus_internal[name] = nil
	mcl_playerplus.elytra[player] = nil
	managed_crosshair[name] = nil
end)

-- Fall damage modifier (only if mcl_damage is available)
if mcl_damage and mcl_damage.register_modifier then
	mcl_damage.register_modifier(function(obj, damage, reason)
		if reason.type ~= "fall" then return end
		local pos = obj:get_pos()
		local node = minetest.get_node(pos)
		local velocity = obj:get_velocity() or obj:get_player_velocity() or {x=0,y=-10,z=0}
		local v_axis_max = math.max(math.abs(velocity.x), math.abs(velocity.y), math.abs(velocity.z))
		if v_axis_max == 0 then return end
		local step = {
			x = velocity.x / v_axis_max,
			y = velocity.y / v_axis_max,
			z = velocity.z / v_axis_max,
		}
		for _ = 1, math.ceil(v_axis_max / 5) + 1 do
			if not node or node.name == "ignore" then
				minetest.get_voxel_manip():read_from_map(pos, pos)
				node = minetest.get_node(pos)
			end
			if node then
				local def = minetest.registered_nodes[node.name]
				if not def or def.walkable then return end
				if get_item_group(node.name, "water") ~= 0 then return 0 end
				if node.name == "mcl_portals:portal_end" then
					if portals_end_teleport then portals_end_teleport(obj) end
					return 0
				end
				if node.name == "mcl_core:cobweb" then return 0 end
				if node.name == "mcl_core:vine" then return 0 end
			end
			pos = vector.add(pos, step)
			node = minetest.get_node(pos)
		end
	end, -200)
end

minetest.register_on_punchplayer(function(player, hitter, time_from_last_punch, tool_capabilities, dir, damage)
	if hitter and hitter:is_player() then
		local weapon = hitter:get_wielded_item()
		local player_pos = player:get_pos()
		local hitter_pos = hitter:get_pos()
		if (vector.distance(player_pos, hitter_pos) - 0.6) > (weapon:get_definition().range or 3) then
			return 0
		end
	end
	if hitter then
		local name = player:get_player_name()
		local internal = mcl_playerplus_internal[name]
		if not internal then return end
		local time_now = get_us_time()
		local time_diff = time_now - internal.invul_timestamp
		if time_diff <= 500000 and time_diff >= 0 then
			player:get_meta():set_int("mcl_damage:invulnerable", 1)
			minetest.after(0.5, function()
				local p = minetest.get_player_by_name(name)
				if not p then return end
				p:get_meta():set_int("mcl_damage:invulnerable", 0)
			end)
			damage = damage - internal.last_damage
			if damage < 0 then damage = 0 end
			return damage
		else
			internal.last_damage = damage
			internal.invul_timestamp = time_now
			player:get_meta():set_int("mcl_damage:damage_animation", 1)
			minetest.after(0.5, function()
				local p = minetest.get_player_by_name(name)
				if not p then return end
				p:get_meta():set_int("mcl_damage:damage_animation", 0)
			end)
		end
	end
end)

minetest.register_on_respawnplayer(function(player)
	local pos = player:get_pos()
	minetest.add_particlespawner({
		amount = 50,
		time = 0.001,
		minpos = pos,
		maxpos = pos,
		minvel = vector.new(-5, -5, -5),
		maxvel = vector.new(5, 5, 5),
		minexptime = 1.1,
		maxexptime = 1.5,
		minsize = 1,
		maxsize = 2,
		collisiondetection = false,
		vertical = false,
		texture = "mcl_particles_mob_death.png^[colorize:#000000:255",
	})
	minetest.sound_play("mcl_mobs_mob_poof", {
		pos = pos,
		gain = 1.0,
		max_hear_distance = 8,
	}, true)
end)