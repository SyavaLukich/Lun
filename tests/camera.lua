-- Run with: lua tests/camera.lua
local callbacks, nodes = {}, {}
local player = {mode = nil, changes = {}}
local function key(pos)
    return math.floor(pos.x + 0.5) .. "," .. math.floor(pos.y + 0.5) .. "," .. math.floor(pos.z + 0.5)
end
vector = {new = function(x, y, z) return {x = x, y = y, z = z} end,
    zero = function() return {x = 0, y = 0, z = 0} end}
minetest = {
    registered_nodes = {air = {walkable = false}, stone = {walkable = true}, glasslike = {walkable = false}},
    get_node_or_nil = function(pos)
        local name = nodes[key(pos)] or "air"
        if name == "unloaded" then return nil end
        return {name = name}
    end,
    raycast = function() return function() return nil end end,
    dir_to_yaw = function(dir) return math.atan2(-dir.x, dir.z) end,
    yaw_to_dir = function(yaw) return {x = -math.sin(yaw), y = 0, z = math.cos(yaw)} end,
    get_player_information = function() return {protocol_version = 48} end,
    get_connected_players = function() return {player} end,
    register_on_joinplayer = function(fn) callbacks.join = fn end,
    register_on_leaveplayer = function(fn) callbacks.leave = fn end,
    register_globalstep = function(fn) callbacks.step = fn end,
    kick_player = function() error("unexpected kick") end,
}
function player:get_player_name() return "tester" end
function player:get_pos() return {x = 0, y = 0, z = 0} end
function player:get_look_dir() return {x = 0, y = 0, z = 1} end
function player:get_properties() return {eye_height = 1.625, textures = self.textures or {"skin.png"}, use_texture_alpha = false} end
function player:set_properties(props)
    if props.textures then self.textures = props.textures end
end
function player:set_eye_offset(_, offset) self.offset = offset end
function player:set_camera(params) self.mode = params.mode; table.insert(self.changes, params.mode) end

dofile("mods/camera/init.lua")
callbacks.join(player)
assert(player.mode == "third")
assert(player.offset.z == 10, "start near the player")
callbacks.step(0.2)
assert(player.offset.z == 10, "must wait before returning to shoulder")
callbacks.step(0.16)
assert(player.offset.z < 10 and player.offset.z > 0, "return must be animated")
callbacks.step(1)
assert(math.abs(player.offset.z) < 0.001, "camera should return to shoulder")
assert(player.textures == nil, "camera must not alter the skin")
-- An unpointable solid block behind the player is still detected by sampling.
nodes["-1,2,-2"] = "stone"
player.textures = {"new_skin.png"}
callbacks.step(0.02)
assert(player.mode == "third" and player.offset.z > 0 and player.offset.z < 10,
    "blocked camera must move toward the player without changing mode")
assert(player.textures[1] == "new_skin.png", "camera must not make the skin transparent")
nodes["-1,2,-2"] = nil
callbacks.step(0.2)
nodes["-1,2,-2"] = "stone"
callbacks.step(0.01)
nodes["-1,2,-2"] = nil
callbacks.step(0.2)
assert(player.offset.z > 0, "intermittent obstruction must reset the timer")
callbacks.step(0.16)
assert(player.textures[1] == "new_skin.png", "camera must not restore an outdated skin")
-- A wall between the eyes and the shoulder must also be detected.
nodes["-1,2,0"] = "stone"
callbacks.step(0.01)
assert(player.offset.z > 0, "shoulder path must be checked")
nodes["-1,2,0"] = "unloaded"
callbacks.step(1)
assert(player.offset.z == 10, "unloaded nodes must be treated as solid")
nodes["-1,2,0"] = "glasslike"
callbacks.step(0.36)
assert(player.offset.z < 10, "non-walkable nodes must not block the camera")
for _, mode in ipairs(player.changes) do assert(mode == "third", "camera must always remain third person") end
callbacks.leave(player)
print("camera tests passed")
