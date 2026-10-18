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

-- Низкий потолок (2 пустых) -> first (замкнутое по вертикали)
obstacles={function(p) return p.y > 2.3 end}
cb.step(0.1)
assert(mode=='first', 'Low ceiling (2 empty) -> first (enclosed vertical)')
obstacles={}
cb.step(0.4)
assert(mode=='first', 'Hysteresis')
assert(last_offset.x < 5, 'Smooth interpolating')
cb.step(0.5)
assert(mode=='third', 'Return after clear')
obstacles={}
cb.step(1)

-- Высокий потолок 3 пустых -> third
obstacles={function(p) return p.y > 3.5 end}
cb.step(0.1)
assert(mode=='third', 'High ceiling 3 empty -> third')
obstacles={}
cb.step(1)

-- 2 пустых между полом и потолком -> first
obstacles={function(p) return p.y >= 3 and p.y < 4 end}
cb.step(0.1)
assert(mode=='first', '2 empty blocks -> first')
obstacles={}
cb.step(1)

-- 3 пустых -> third
obstacles={function(p) return p.y >= 4 and p.y < 5 end}
cb.step(0.1)
assert(mode=='third', '3 empty -> third')
obstacles={}
cb.step(1)

-- Замкнутое помещение: 2 высокие стены по X (коридор) -> first
obstacles={
 function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 3 end,
 function(p) return p.x <= -2 and p.x > -3 and p.y >= 1 and p.y < 3 end,
}
cb.step(0.1)
assert(mode=='first', 'Enclosed: 2 tall walls X+2/X-2 -> first (corridor)')
obstacles={}
cb.step(1)

-- Замкнутое: стены X+2 и Z+2 (угол комнаты) -> first
obstacles={
 function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 3 end,
 function(p) return p.z >= 2 and p.z < 3 and p.y >= 1 and p.y < 3 end,
}
cb.step(0.1)
assert(mode=='first', 'Enclosed: X+2 & Z+2 corner -> first')
obstacles={}
cb.step(1)

-- Одиночная высокая стена X+2 -> НЕ замкнутое -> third (не переключать в открытом поле)
obstacles={function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 3 end}
cb.step(0.1)
assert(mode=='third', 'Single tall wall X+2 alone -> third (not enclosed)')
obstacles={}
cb.step(1)

-- Одиночная высокая стена Z+2 -> third
obstacles={function(p) return p.z >= 2 and p.z < 3 and p.y >= 1 and p.y < 3 end}
cb.step(0.1)
assert(mode=='third', 'Single tall wall Z+2 alone -> third')
obstacles={}
cb.step(1)

-- Низкая стена высотой 1 блок (только y 1..2) даже 2 стены не должны триггерить
obstacles={
 function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 2 end,
 function(p) return p.x <= -2 and p.x > -3 and p.y >= 1 and p.y < 2 end,
}
cb.step(0.1)
assert(mode=='third', 'Low walls height=1 even with 2 walls -> third (height>1 required)')
obstacles={}
cb.step(1)

-- Широкая стена на 0.85 с двух сторон — узкий коридор, считается замкнутым, если высокие стены
obstacles={
 function(p) return p.x > 0.85 and p.x < 1.5 and p.y >= 1 and p.y < 3 end,
 function(p) return p.x < -0.85 and p.x > -1.5 and p.y >= 1 and p.y < 3 end,
}
cb.step(0.1)
assert(mode=='first', 'Narrow corridor 0.85 enclosed -> first')
obstacles={}
cb.step(1)

-- Плавный переход
obstacles={function(p) return p.y >= 3 and p.y < 4 end}
cb.step(0.1)
assert(mode=='first', 'Trigger first for smooth')
offset_history = {}
cb.step(0.05)
assert(#offset_history > 0, 'Smooth: set_eye_offset each frame')
local mid = offset_history[1]
assert(mid.x < 5 and mid.x > 0 or mid.y < 3 and mid.y > 0, 'Smooth intermediate')
cb.step(0.1)
cb.step(0.1)
cb.step(0.1)
cb.step(0.1)
assert(last_offset.x == 0 and last_offset.y == 0, 'Smooth finish 0,0')
obstacles={}
cb.step(0.4)
assert(mode=='first', 'Hysteresis')
cb.step(0.5)
assert(mode=='third', 'Back to third')
offset_history = {}
cb.step(0.05)
assert(offset_history[1].x > 0 and offset_history[1].x < 5, 'Smooth back intermediate')
cb.step(0.4)
assert(last_offset.x == 5 and last_offset.y == 3, 'Smooth back finished 5,3')

obstacles={}
cb.step(1)
local original=minetest.get_node_or_nil
minetest.get_node_or_nil=function() return nil end
cb.step(0.1)
assert(mode=='first', 'Unloaded -> first')
minetest.get_node_or_nil=original
cb.leave(player)
local before=calls
cb.step(1)
assert(calls==before, 'Forget disconnected')
protocol=47
cb.join(player)
assert(kicked, 'Reject old client')
print('OK: enclosed room algorithm, height>1, hysteresis, smooth, cleanup')
