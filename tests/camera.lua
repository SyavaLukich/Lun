-- Запуск: lua tests/camera.lua (из корня репозитория).
vector = {
 add = function(a,b) return {x=a.x+b.x,y=a.y+b.y,z=a.z+b.z} end,
 subtract = function(a,b) return {x=a.x-b.x,y=a.y-b.y,z=a.z-b.z} end,
 multiply = function(a,n) return {x=a.x*n,y=a.y*n,z=a.z*n} end,
}
local cb, obstacles, mode, calls, kicked = {}, {}, nil, 0, false
local online = true
local protocol = 48
local function node_at(p)
 for _, contains in ipairs(obstacles) do
  if contains(p) then return {name='stone'} end
 end
 return {name='air'}
end
local player = {
 get_player_name = function() return 'builder' end,
 get_pos = function() return {x=0,y=0,z=0} end,
 get_properties = function() return {eye_height=1.625} end,
 get_look_horizontal = function() return 0 end,
 get_look_dir = function() return {x=0,y=0,z=1} end,
 set_eye_offset = function(_,first,third)
  assert(first.y == 0 and third.y == 8 and third.x == 5)
 end,
 set_camera = function(_, params) mode=params.mode; calls=calls+1 end,
}
minetest = {
 registered_nodes = {air={walkable=false},stone={walkable=true}},
 get_node_or_nil = node_at,
 raycast = function(a,b)
  local hit
  for i=0,100 do
   local p=vector.add(a,vector.multiply(vector.subtract(b,a),i/100))
   if node_at(p).name=='stone' then hit={type='node',under=p}; break end
  end
  return function() local result=hit; hit=nil; return result end
 end,
 register_on_joinplayer = function(f) cb.join=f end,
 register_on_leaveplayer = function(f) cb.leave=f end,
 register_globalstep = function(f) cb.step=f end,
 get_connected_players = function() return online and {player} or {} end,
 get_player_information = function() return {protocol_version=protocol} end,
 kick_player = function() kicked=true end,
}
dofile('mods/lun/camera.lua')
cb.join(player)
assert(mode=='third', 'Open space: third person')
cb.step(1)
assert(calls==1, 'Do not resend unchanged mode')
obstacles={function(p) return p.z < -1.2 end}
cb.step(0.1)
assert(mode=='first', 'Wall behind camera')
obstacles={}
cb.step(0.4)
assert(mode=='first', 'Hysteresis: wait before returning')
cb.step(0.5)
assert(mode=='third', 'Return to third person after clear interval')
obstacles={function(p) return p.y > 2.3 end}
cb.step(0.1)
assert(mode=='first', 'Low ceiling')
obstacles={}
cb.step(1)
obstacles={function(p) return math.abs(p.x) > 0.85 end}
cb.step(0.1)
assert(mode=='first', 'Narrow passage, even looking toward exit')
obstacles={}
cb.step(1)
local original=minetest.get_node_or_nil
minetest.get_node_or_nil=function() return nil end
cb.step(0.1)
assert(mode=='first', 'Unloaded camera position')
minetest.get_node_or_nil=original
cb.leave(player)
local before=calls
cb.step(1)
assert(calls==before, 'Forget disconnected player state')
protocol=47
cb.join(player)
assert(kicked, 'Reject clients without forced-camera support')
print('OK: camera offsets, modes, obstacles, hysteresis, cleanup, compatibility')
