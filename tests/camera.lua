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

-- Низкий потолок (2 пустых) -> должен начать плавный въезд в голову, режим пока third
obstacles={function(p) return p.y > 2.3 end}
cb.step(0.1)
-- Камера плавно въезжает в голову, режим переключается В КОНЦЕ перехода (0.35с)
-- Первый шаг только ставит цель, интерполяция начнётся на следующем кадре
assert(mode=='third', 'Smooth entry: mode still third while camera drives into head (0.1s)')
-- Оффсет ещё на старте (5,3), следующий кадр начнёт движение
cb.step(0.1)
assert(mode=='third', 'Still third at 0.2s')
assert(last_offset.x < 5 and last_offset.y < 3, 'Smooth entry: offset interpolating (0.2s)')
cb.step(0.1)
assert(mode=='third', 'Still third at 0.3s')
cb.step(0.1) -- 0.4s, ещё не завершён (нужно 0.35 после старта, старт был на 0.1, итого 0.5)
assert(mode=='third', 'Still third at 0.4s (transition 0.3/0.35)')
cb.step(0.1) -- 0.5s, завершён
assert(mode=='first', 'After smooth entry (0.5s) -> first')
assert(last_offset.x == 0 and last_offset.y == 0, 'Offset reached 0,0 in head')
obstacles={}
-- Hysteresis + плавный выезд: сначала держит first 0.8с, затем мгновенно в third и плавно выезжает
cb.step(0.4)
assert(mode=='first', 'Hysteresis 0.4s still first')
cb.step(0.5) -- 0.9s >0.8, должен сразу переключиться в third и начать выезд
assert(mode=='third', 'After hysteresis -> third (instant mode switch)')
-- Оффсет ещё не вернулся в 5,3, а плавно выезжает
assert(last_offset.x == 0 and last_offset.y == 0, 'At switch moment offset still 0,0 (just switched to third)')
offset_history = {}
cb.step(0.05)
assert(offset_history[1].x > 0 and offset_history[1].x < 5, 'Smooth exit: intermediate after 0.05s')
cb.step(0.35)
assert(last_offset.x == 5 and last_offset.y == 3, 'Smooth exit finished at 5,3')
obstacles={}
cb.step(1)

-- Высокий потолок 3 пустых -> third
obstacles={function(p) return p.y > 3.5 end}
cb.step(0.1)
assert(mode=='third', 'High ceiling 3 empty -> third')
obstacles={}
cb.step(1)

-- 2 пустых -> плавный въезд в first
obstacles={function(p) return p.y >= 3 and p.y < 4 end}
cb.step(0.1)
assert(mode=='third', '2 empty: start smooth entry, still third')
cb.step(0.4)
assert(mode=='first', '2 empty: after smooth -> first')
obstacles={}
cb.step(0.4)
assert(mode=='first', 'Hysteresis still first')
cb.step(0.5)
assert(mode=='third', 'Back to third')
cb.step(0.4)
-- дождаться завершения выезда
cb.step(0.1)
obstacles={}
cb.step(1)

-- Замкнутое: 2 высокие стены X+2/X-2 -> плавный въезд
obstacles={
 function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 3 end,
 function(p) return p.x <= -2 and p.x > -3 and p.y >= 1 and p.y < 3 end,
}
cb.step(0.1)
assert(mode=='third', 'Enclosed 2 walls: start entry, still third')
cb.step(0.4)
assert(mode=='first', 'Enclosed -> first after smooth')
obstacles={}
cb.step(0.4)
assert(mode=='first', 'Hysteresis')
cb.step(0.5)
assert(mode=='third', 'Back')
cb.step(0.4)
obstacles={}
cb.step(1)

-- Угол X+2 & Z+2 -> first после плавности
obstacles={
 function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 3 end,
 function(p) return p.z >= 2 and p.z < 3 and p.y >= 1 and p.y < 3 end,
}
cb.step(0.1)
assert(mode=='third', 'Corner start entry')
cb.step(0.4)
assert(mode=='first', 'Corner -> first')
obstacles={}
cb.step(0.4)
assert(mode=='first')
cb.step(0.5)
assert(mode=='third')
cb.step(0.4)
obstacles={}
cb.step(1)

-- Одиночная высокая стена -> не замкнутое -> third
obstacles={function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 3 end}
cb.step(0.1)
assert(mode=='third', 'Single tall wall -> third (not enclosed)')
obstacles={}
cb.step(1)

-- Низкая стена высотой 1 (только y 1..2) даже 2 стены не триггерит
obstacles={
 function(p) return p.x >= 2 and p.x < 3 and p.y >= 1 and p.y < 2 end,
 function(p) return p.x <= -2 and p.x > -3 and p.y >= 1 and p.y < 2 end,
}
cb.step(0.1)
assert(mode=='third', 'Low walls h=1 even 2 walls -> third')
obstacles={}
cb.step(1)

-- Узкий коридор 0.85 с высокими стенами -> first после плавности
obstacles={
 function(p) return p.x > 0.85 and p.x < 1.5 and p.y >= 1 and p.y < 3 end,
 function(p) return p.x < -0.85 and p.x > -1.5 and p.y >= 1 and p.y < 3 end,
}
cb.step(0.1)
assert(mode=='third', 'Narrow corridor start entry')
cb.step(0.4)
assert(mode=='first', 'Narrow corridor -> first')
obstacles={}
cb.step(0.4)
assert(mode=='first')
cb.step(0.5)
assert(mode=='third')
cb.step(0.4)
obstacles={}
cb.step(1)

-- Плавный переход детально: проверяем интерполяцию каждый кадр
obstacles={function(p) return p.y >= 3 and p.y < 4 end}
cb.step(0.1)
assert(mode=='third', 'Smooth test start')
offset_history = {}
cb.step(0.05)
assert(#offset_history > 0, 'Smooth: set_eye_offset each frame')
local mid = offset_history[1]
assert(mid.x < 5 and mid.x > 0 or mid.y < 3 and mid.y > 0, 'Smooth intermediate')
cb.step(0.35)
assert(mode=='first', 'Smooth finish -> first')
assert(last_offset.x == 0 and last_offset.y == 0, 'Smooth finish 0,0')
obstacles={}
cb.step(0.4)
assert(mode=='first')
cb.step(0.5)
assert(mode=='third', 'Back')
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
-- ignore считается препятствием, но въезд плавный: сначала third, затем first
assert(mode=='third', 'Unloaded: start smooth entry, still third')
cb.step(0.4)
assert(mode=='first', 'Unloaded -> first after smooth')
minetest.get_node_or_nil=original
cb.leave(player)
local before=calls
cb.step(1)
assert(calls==before, 'Forget disconnected')
protocol=47
cb.join(player)
assert(kicked, 'Reject old client')
print('OK: enclosed room, height>1, hysteresis, smooth entry into head, cleanup')
