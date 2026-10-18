-- Запуск: lua tests/camera.lua (из корня репозитория).
vector={add=function(a,b) return {x=a.x+b.x,y=a.y+b.y,z=a.z+b.z} end, subtract=function(a,b) return {x=a.x-b.x,y=a.y-b.y,z=a.z-b.z} end, multiply=function(a,n) return {x=a.x*n,y=a.y*n,z=a.z*n} end}
local cb,obstacles,mode,calls,kicked={},{},nil,0,false
local online=true
local protocol=48
local last_offset=nil
local function node_at(p) for _,contains in ipairs(obstacles) do if contains(p) then return {name='stone'} end end return {name='air'} end
local player={get_player_name=function() return 'builder' end, get_pos=function() return {x=0,y=0,z=0} end, get_properties=function() return {eye_height=1.625} end, get_look_horizontal=function() return 0 end, get_look_dir=function() return {x=0,y=0,z=1} end,
 set_eye_offset=function(_,first,third) last_offset={x=third.x,y=third.y} assert(third.x>=0 and third.x<=5 and third.y>=0 and third.y<=2,'offset '..third.x..','..third.y) assert(first.x==0 and first.y==0 and first.z==0) end,
 set_camera=function(_,params) mode=params.mode; calls=calls+1 end}
minetest={registered_nodes={air={walkable=false},stone={walkable=true}}, get_node_or_nil=node_at,
 raycast=function(a,b) local hit for i=0,100 do local p=vector.add(a,vector.multiply(vector.subtract(b,a),i/100)) if node_at(p).name=='stone' then hit={type='node',under=p}; break end end return function() local r=hit; hit=nil; return r end end,
 register_on_joinplayer=function(f) cb.join=f end, register_on_leaveplayer=function(f) cb.leave=f end, register_globalstep=function(f) cb.step=f end,
 get_connected_players=function() return online and {player} or {} end, get_player_information=function() return {protocol_version=protocol} end, kick_player=function() kicked=true end}
dofile('mods/lun/camera.lua')

local function instant_first()
 cb.step(0.1)
 assert(mode=='first','Should be first instantly (0.1)')
 assert(last_offset.x==0 and last_offset.y==0,'Offset 0,0')
end
local function fast_back()
 -- быстрый возврат 0.25с: нужно 0.3 с запасом
 cb.step(0.2)
 assert(mode=='first','Still first at 0.2 (before 0.25)')
 cb.step(0.1)
 assert(mode=='third','Back to third fast at 0.3')
 assert(last_offset.x==5 and last_offset.y==2,'Back to 5,2')
end

cb.join(player)
assert(mode=='third','Open space third')
assert(last_offset.x==5 and last_offset.y==2,'Initial 5,2')
cb.step(1)
assert(calls==1,'No resend')

-- Низкий потолок 2 пустых -> мгновенно first
obstacles={function(p) return p.y>2.3 end}
instant_first()
obstacles={}
fast_back()
cb.step(0.5)

-- Высокий потолок 3 пустых -> third
obstacles={function(p) return p.y>3.5 end}
cb.step(0.1)
assert(mode=='third','High ceiling 3 empty -> third')
obstacles={}
cb.step(1)

-- 2 пустых -> first
obstacles={function(p) return p.y>=3 and p.y<4 end}
instant_first()
obstacles={}
fast_back()
cb.step(0.5)

-- Замкнутое 2 стены X
obstacles={function(p) return p.x>=2 and p.x<3 and p.y>=1 and p.y<3 end, function(p) return p.x<=-2 and p.x>-3 and p.y>=1 and p.y<3 end}
instant_first()
obstacles={}
fast_back()
cb.step(0.5)

-- Угол X+2 & Z+2
obstacles={function(p) return p.x>=2 and p.x<3 and p.y>=1 and p.y<3 end, function(p) return p.z>=2 and p.z<3 and p.y>=1 and p.y<3 end}
instant_first()
obstacles={}
fast_back()
cb.step(0.5)

-- Одиночная высокая стена -> third
obstacles={function(p) return p.x>=2 and p.x<3 and p.y>=1 and p.y<3 end}
cb.step(0.1)
assert(mode=='third','Single wall -> third')
obstacles={}
cb.step(1)

-- Низкая стена h=1 -> third
obstacles={function(p) return p.x>=2 and p.x<3 and p.y>=1 and p.y<2 end, function(p) return p.x<=-2 and p.x>-3 and p.y>=1 and p.y<2 end}
cb.step(0.1)
assert(mode=='third','Low h=1 even 2 walls -> third')
obstacles={}
cb.step(1)

-- Узкий коридор 0.85 высокие -> first
obstacles={function(p) return p.x>0.85 and p.x<1.5 and p.y>=1 and p.y<3 end, function(p) return p.x<-0.85 and p.x>-1.5 and p.y>=1 and p.y<3 end}
instant_first()
obstacles={}
fast_back()
cb.step(0.5)

-- Незагруженные участки = препятствие, но возврат быстрый
local orig=minetest.get_node_or_nil
minetest.get_node_or_nil=function() return nil end
cb.step(0.1)
assert(mode=='first','Unloaded -> first')
minetest.get_node_or_nil=orig
obstacles={}
fast_back()

cb.leave(player)
local before=calls
cb.step(1)
assert(calls==before,'Forget')
protocol=47
cb.join(player)
assert(kicked,'Reject old')
print('OK: instant cramped, fast return 0.25, x/z>=2, height>1, lower camera')
