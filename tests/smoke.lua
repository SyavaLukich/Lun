-- Запуск: lua tests/smoke.lua (из корня репозитория).
local callbacks, nodes, commands, world = {}, {}, {}, {}
minetest = {
 register_alias = function(a, b) assert(a == 'mapgen_singlenode' and b == 'air') end,
 register_on_mapgen_init = function(f) callbacks.mapgen = f end,
 set_mapgen_setting = function(k, v) assert(k == 'mg_name' and v == 'singlenode') end,
 register_node = function(name, def) nodes[name] = def end,
 register_on_joinplayer = function(f) callbacks.join = f end,
 register_on_respawnplayer = function(f) callbacks.respawn = f end,
 register_chatcommand = function(name, def) commands[name] = def end,
 register_globalstep = function(f) callbacks.step = f end,
 emerge_area = function(_, _, f) f({}, 0, 0) end,
 get_node = function(p) return {name = world[p.x .. ':' .. p.z] or 'air'} end,
 set_node = function(p, node) world[p.x .. ':' .. p.z] = node.name end,
 get_player_by_name = function() return nil end,
 get_connected_players = function() return {} end,
}
dofile('mods/lun/init.lua')
callbacks.mapgen()
local count = 0
for _ in pairs(nodes) do count = count + 1 end
assert(count == 6)
assert(nodes['lun:light'].light_source == 14)
assert(commands.spawn.func('offline') == false)
assert(commands.blocks.func('offline') == false)
local player = {
 get_player_name = function() return 'test' end,
 set_pos = function(_, pos) assert(pos.y == 2) end,
 set_velocity = function() end,
}
minetest.get_player_by_name = function() return player end
world['0:0'] = 'lun:wood'
assert(commands.spawn.func('test') == true)
count = 0
for _ in pairs(world) do count = count + 1 end
assert(count == 81)
assert(world['0:0'] == 'lun:wood', 'Existing builds must survive')
assert(callbacks.respawn(player) == true)
callbacks.step(1)
print('OK: registration, mapgen, commands, platform, respawn')
