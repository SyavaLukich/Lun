--[[
mcl_death_drop - Drop player inventory on death, standalone version.

No hard dependencies. Optional compatibility with:
  - vl_tuning (gamerule:keepInventory)
  - mcl_worlds (void detection)
]]

local random = math.random
local ipairs = ipairs

mcl_death_drop = {}

mcl_death_drop.registered_dropped_lists = {}
mcl_death_drop.on_death_drop_per_stack = {}
mcl_death_drop.ORDER = {
	VOID = -1000,
	SELECTIVE = 0,
	CATCH_ALL = 1000,
}

local callback_sequence = 0
local callbacks_dirty = false

--[[
Optional vl_tuning integration:
If vl_tuning is loaded, use its gamerule:keepInventory setting.
Otherwise fall back to a plain minetest.conf setting.
]]
local keep_inventory
local vl_tuning = rawget(_G, "vl_tuning")
if vl_tuning and vl_tuning.setting then
	local ok, setting = pcall(vl_tuning.setting, "gamerule:keepInventory")
	if ok and setting then
		keep_inventory = setting
	end
end

if not keep_inventory then
	local setting_value = minetest.settings:get_bool("mcl_death_drop_keep_inventory", false)
	keep_inventory = {
		getter = function() return setting_value end,
	}
end

--[[
Optional mcl_worlds integration for void detection.
If mcl_worlds is loaded, use mcl_worlds.is_in_void().
Otherwise use a simple Y-threshold, configurable via mcl_death_drop_void_level
(default -1000).
]]
local void_level = tonumber(minetest.settings:get("mcl_death_drop_void_level")) or -1000
local mcl_worlds = rawget(_G, "mcl_worlds")

local function is_in_void(pos)
	if mcl_worlds and mcl_worlds.is_in_void then
		local _, void_deadly = mcl_worlds.is_in_void(pos)
		return void_deadly
	end
	return pos.y <= void_level
end

function mcl_death_drop.register_dropped_list(inv, listname, drop)
	table.insert(mcl_death_drop.registered_dropped_lists, {
		inv = inv,
		listname = listname,
		drop = drop,
	})
end

function mcl_death_drop.register_on_death_drop_per_stack(func, priority)
	callback_sequence = callback_sequence + 1
	table.insert(mcl_death_drop.on_death_drop_per_stack, {
		func = func,
		priority = priority or mcl_death_drop.ORDER.SELECTIVE,
		sequence = callback_sequence,
	})
	callbacks_dirty = true
end

local function sort_callbacks()
	if not callbacks_dirty then
		return
	end

	table.sort(mcl_death_drop.on_death_drop_per_stack, function(a, b)
		if a.priority == b.priority then
			return a.sequence < b.sequence
		end
		return a.priority < b.priority
	end)
	callbacks_dirty = false
end

mcl_death_drop.register_dropped_list("PLAYER", "main", true)
mcl_death_drop.register_dropped_list("PLAYER", "craft", true)
mcl_death_drop.register_dropped_list("PLAYER", "craftresult", true)
mcl_death_drop.register_dropped_list("PLAYER", "armor", true)
mcl_death_drop.register_dropped_list("PLAYER", "offhand", true)
mcl_death_drop.register_dropped_list("PLAYER", "distr", true)

minetest.register_on_dieplayer(function(player)
	if keep_inventory.getter() then
		return
	end

	sort_callbacks()

	local playerinv = player:get_inventory()
	local pos = player:get_pos()
	local void_deadly = is_in_void(pos)

	for l = 1, #mcl_death_drop.registered_dropped_lists do
		local entry = mcl_death_drop.registered_dropped_lists[l]

		local inv = entry.inv
		if inv == "PLAYER" then
			inv = playerinv
		elseif type(inv) == "function" then
			inv = inv(player)
		end

		local listname = entry.listname
		local drop = entry.drop

		-- Пропускаем списки, которых нет в этом инвентаре.
		-- Например, "armor" появляется только с mcl_armor, "craft" —
		-- с mcl_inventory и т.п. Без них get_list() возвращает nil,
		-- и ipairs(nil) падает.
		local list = inv and inv:get_list(listname)
		if not list then
			goto continue_outer
		end

		local dropspots = minetest.find_nodes_in_area(
			vector.offset(pos, -3, 0, -3),
			vector.offset(pos, 3, 0, 3),
			{"air"}
		)
		if #dropspots == 0 then
			table.insert(dropspots, pos)
		end

		for i, stack in ipairs(list) do
			if not stack:is_empty() then
				local was_handled = false
				for _, on_death_drop in ipairs(mcl_death_drop.on_death_drop_per_stack) do
					if on_death_drop.func
						and on_death_drop.func(player, inv, listname, i, stack) then
						was_handled = true
						break
					end
				end

				if not was_handled then
					local p = vector.offset(
						dropspots[random(#dropspots)],
						random() - 0.5,
						random() - 0.5,
						random() - 0.5
					)

					if not void_deadly and drop then
						local def = minetest.registered_items[stack:get_name()]
						if def and def.on_drop then
							stack = def.on_drop(stack, player, p)
						end
						minetest.add_item(p, stack)
					end

					inv:set_stack(listname, i, nil)
				end
			end
		end

		::continue_outer::
	end
end)