-- Запуск: lua tests/camera.lua (из корня репозитория).
vector = {
 add = function(a,b) return {x=a.x+b.x,y=a.y+b.y,z=a.z+b.z} end,
 subtract = function(a,b) return {x=a.x-b.x,y=a.y-b.y,z=a.z-b.z} end,
 multiply = function(a,n) return {x=a.x*n,y=a.y*n,z=a.z*n} end,
}
local cb, obstacles, mode, calls, kicked = {}, {}, nil, 0, false
local online = true
local protocol = 48
local last_offset = nil
local offset_history = {}
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
  last_offset = {x=third.x, y=third.y}
  table.insert(offset_history, {x=third.x, y=third.y})
  assert(third.x >= 0 and third.x <= 5 and third.y >= 0 and third.y <= 3, 'offset out of range: '..third.x..','..third.y)
  assert(first.x == 0 and first.y == 0 and first.z == 0, 'first offset must be zero')
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
assert(last_offset.x==5 and last_offset.y==3, 'Initial offset 5,3')
cb.step(1)
assert(calls==1, 'Do not resend unchanged mode')

-- 2. Низкий потолок (2 пустых блока) -> first
obstacles={function(p) return p.y > 2.3 end}
cb.step(0.1)
assert(mode=='first', 'Low ceiling (2 empty blocks) -> first')
obstacles={}
cb.step(0.4)
assert(mode=='first', 'Hysteresis: wait before returning')
assert(last_offset.x < 5 and last_offset.x >= 0, 'Smooth transition: interpolating')
cb.step(0.5)
assert(mode=='third', 'Return to third person after clear interval')
obstacles={}
cb.step(1)

-- 3. Высокий потолок 3 пустых блока -> third
obstacles={function(p) return p.y > 3.5 end}
cb.step(0.1)
assert(mode=='third', 'High ceiling (3 empty) stays third')
obstacles={}
cb.step(1)

-- 4. 2 пустых блока: потолок 3 -> first
obstacles={function(p) return p.y >= 3 and p.y < 4 end}
cb.step(0.1)
assert(mode=='first', '2 empty blocks -> first')
obstacles={}
cb.step(1)

-- 5. 3 пустых блока: потолок 4 -> third
obstacles={function(p) return p.y >= 4 and p.y < 5 end}
cb.step(0.1)
assert(mode=='third', '3 empty blocks -> third')
obstacles={}
cb.step(1)

-- 6. Проверка X>=2 с высотой >1: стена 2 блока высотой (y 1..3) -> first
obstacles={function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 3 end}
cb.step(0.1)
assert(mode=='first', 'Wall at x>=2 height>1 -> first')
obstacles={}
cb.step(1)

-- 7. Проверка Z>=2 с высотой >1: стена 2 блока высотой -> first
obstacles={function(p) return p.z >= 2 and p.z < 3 and p.y >= 1 and p.y < 3 end}
cb.step(0.1)
assert(mode=='first', 'Wall at z>=2 height>1 -> first')
obstacles={}
cb.step(1)

-- 8. Стена X>=2 но высотой 1 блок (только y 1..2) -> НЕ должна триггерить (важно: влияет только >1)
obstacles={function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 2 end}
cb.step(0.1)
assert(mode=='third', 'Wall at x>=2 height=1 -> third (no effect)')
obstacles={}
cb.step(1)

-- 9. Стена Z>=2 высотой 1 -> не триггерит
obstacles={function(p) return p.z >= 2 and p.z < 3 and p.y >= 1 and p.y < 2 end}
cb.step(0.1)
assert(mode=='third', 'Wall at z>=2 height=1 -> third (no effect)')
obstacles={}
cb.step(1)

-- 10. Узкий проход на 0.85 не триггерит (только x>=2)
obstacles={function(p) return math.abs(p.x) > 0.85 and math.abs(p.x) < 1.5 end}
cb.step(0.1)
assert(mode=='third', 'Narrow side walls at 0.85 alone no longer trigger')
obstacles={}
cb.step(1)

-- 11. Плавный переход
obstacles={function(p) return p.y >= 3 and p.y < 4 end}
cb.step(0.1)
assert(mode=='first', 'Trigger first for smooth test')
offset_history = {}
cb.step(0.05)
assert(#offset_history > 0, 'Smooth: set_eye_offset each frame')
local mid = offset_history[1]
assert(mid.x < 5 and mid.x > 0 or mid.y < 3 and mid.y > 0, 'Smooth: intermediate offset')
cb.step(0.1)
cb.step(0.1)
cb.step(0.1)
cb.step(0.1)
assert(last_offset.x == 0 and last_offset.y == 0, 'Smooth finish at 0,0')
obstacles={}
cb.step(0.4)
assert(mode=='first', 'Still first during hysteresis')
cb.step(0.5)
assert(mode=='third', 'Back to third after hysteresis')
offset_history = {}
cb.step(0.05)
assert(offset_history[1].x > 0 and offset_history[1].x < 5, 'Smooth back intermediate')
cb.step(0.4)
assert(last_offset.x == 5 and last_offset.y == 3, 'Smooth back finished at 5,3')

obstacles={}
cb.step(1)
local original=minetest.get_node_or_nil
minetest.get_node_or_nil=function() return nil end
cb.step(0.1)
assert(mode=='first', 'Unloaded area (ignore) -> first')
minetest.get_node_or_nil=original
cb.leave(player)
local before=calls
cb.step(1)
assert(calls==before, 'Forget disconnected player state')
protocol=47
cb.join(player)
assert(kicked, 'Reject clients without forced-camera support')
print('OK: camera offsets, modes, height x/z (height>1) checks, hysteresis, smooth transition, cleanup, compatibility')
