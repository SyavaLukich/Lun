-- Общие математические и текстовые помощники.
-- Модуль не зависит от движка и используется как на сервере, так и в тестах.

local U = {}
smart_npc.util = U

local floor, sqrt, min, max, abs = math.floor, math.sqrt, math.min, math.max, math.abs

function U.clamp(value, low, high)
	value = tonumber(value)
	if not value or value ~= value then return low end
	if value < low then return low end
	if value > high then return high end
	return value
end

function U.round(value)
	if value < 0 then return -floor(-value + 0.5) end
	return floor(value + 0.5)
end

function U.approach(value, target, step)
	if step <= 0 then return value end
	if value < target then return min(value + step, target) end
	if value > target then return max(value - step, target) end
	return value
end

function U.lerp(a, b, t)
	return a + (b - a) * U.clamp(t, 0, 1)
end

function U.sign(value)
	if value > 0 then return 1 end
	if value < 0 then return -1 end
	return 0
end

-- Устойчивый 32-битный хеш (djb2). Нужен для детерминированного «случая»:
-- поведение NPC воспроизводимо по сохранённому seed и счётчику бросков.
function U.hash(text)
	text = tostring(text or "")
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + text:byte(i)) % 4294967296
	end
	return h
end

function U.new_rng(seed)
	local counter = 0
	local seed_text = tostring(seed or 1)
	return function(low, high)
		counter = counter + 1
		local h = U.hash(seed_text .. ":" .. counter)
		if low == nil then
			return h / 4294967296
		end
		return low + (h % (high - low + 1))
	end
end

-- Детерминированный «случай» для сохранённого мозга: последовательность
-- зависит только от seed и счётчика, поэтому переживает сохранение мира.
function U.rand_int(brain, low, high)
	brain.rng_counter = (brain.rng_counter or 0) + 1
	local h = U.hash(tostring(brain.rng_seed or 1) .. ":" .. tostring(brain.rng_counter))
	if low == nil or high == nil then
		return h / 4294967296
	end
	return low + (h % (high - low + 1))
end

function U.rand_float(brain)
	return U.rand_int(brain, nil, nil)
end

function U.chance(rng, probability)
	return rng() < probability
end

function U.pick(rng, list)
	if not list or #list == 0 then return nil end
	return list[rng(1, #list)]
end

function U.shuffle(rng, list)
	local out = {}
	for i = 1, #list do out[i] = list[i] end
	for i = #out, 2, -1 do
		local j = rng(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function U.deepcopy(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for k, v in pairs(value) do
		out[k] = U.deepcopy(v, seen)
	end
	return out
end

function U.count(list)
	local n = 0
	for _ in pairs(list) do n = n + 1 end
	return n
end

function U.array_contains(list, value)
	for i = 1, #list do
		if list[i] == value then return true, i end
	end
	return false
end

function U.array_remove(list, value)
	for i = #list, 1, -1 do
		if list[i] == value then
			table.remove(list, i)
			return true
		end
	end
	return false
end

function U.copy_array(list)
	local out = {}
	for i = 1, #list do out[i] = list[i] end
	return out
end

local function coords(pos)
	if type(pos) ~= "table" then return nil end
	local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
	if not x or not y or not z or x ~= x or y ~= y or z ~= z then return nil end
	return x, y, z
end

function U.vector_copy(pos)
	local x, y, z = coords(pos)
	if not x then return nil end
	return {x = x, y = y, z = z}
end

function U.distance(a, b)
	local ax, ay, az = coords(a)
	local bx, by, bz = coords(b)
	if not ax or not bx then return math.huge end
	local dx, dy, dz = ax - bx, ay - by, az - bz
	return sqrt(dx * dx + dy * dy + dz * dz)
end

function U.horizontal_distance(a, b)
	local ax, _, az = coords(a)
	local bx, _, bz = coords(b)
	if not ax or not bx then return math.huge end
	local dx, dz = ax - bx, az - bz
	return sqrt(dx * dx + dz * dz)
end

function U.split(text, separator)
	local out = {}
	if not text then return out end
	separator = separator or "%s"
	local pattern = "([^" .. separator .. "]+)"
	for piece in tostring(text):gmatch(pattern) do
		out[#out + 1] = piece
	end
	return out
end

function U.trim(text)
	if not text then return "" end
	return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.lower(text)
	return tostring(text or ""):lower()
end

-- Русские окончания для возраста и отрезков времени.
function U.plural(number, one, few, many)
	local n = abs(number) % 100
	local n1 = n % 10
	if n > 10 and n < 20 then return many end
	if n1 > 1 and n1 < 5 then return few end
	if n1 == 1 then return one end
	return many
end

function U.format_age(seconds)
	if not seconds or seconds < 0 then seconds = 0 end
	if seconds < 45 then return "только что" end
	local minutes = floor(seconds / 60)
	if minutes < 60 then
		return minutes .. " " .. U.plural(minutes, "минуту", "минуты", "минут") .. " назад"
	end
	local hours = floor(minutes / 60)
	if hours < 24 then
		return hours .. " " .. U.plural(hours, "час", "часа", "часов") .. " назад"
	end
	local days = floor(hours / 24)
	return days .. " " .. U.plural(days, "день", "дня", "дней") .. " назад"
end

function U.format_duration(seconds)
	local minutes = floor((seconds or 0) / 60)
	if minutes < 1 then
		return floor(seconds or 0) .. " с"
	end
	return minutes .. " мин"
end

-- Перенос длинного текста под ширину formspec (по словам).
function U.wrap(text, width)
	width = width or 60
	local lines = {}
	local line = ""
	for word in tostring(text):gmatch("%S+") do
		if #line == 0 then
			line = word
		elseif #line + 1 + #word <= width then
			line = line .. " " .. word
		else
			lines[#lines + 1] = line
			line = word
		end
	end
	if #line > 0 then lines[#lines + 1] = line end
	if #lines == 0 then lines[1] = "" end
	return lines
end

-- Символы , и ; ломают table[] в formspec, а ] — почти все элементы.
function U.formspec_safe(text)
	local s = tostring(text or "")
	s = s:gsub(",", " ")
	s = s:gsub(";", " ")
	s = s:gsub("%[", "(")
	s = s:gsub("%]", ")")
	s = s:gsub("[\r\n]+", " ")
	return s
end

function U.color_for_value(value)
	if value >= 60 then return "#5cb85c" end
	if value >= 30 then return "#d9a441" end
	return "#c8553d"
end

function U.mood_color(mood, stress)
	if (stress or 0) >= 80 then return "#b06cd9" end
	if mood >= 70 then return "#5cb85c" end
	if mood >= 50 then return "#8fbf5a" end
	if mood >= 35 then return "#d9a441" end
	if mood >= 20 then return "#cf7c3a" end
	return "#c8553d"
end

function U.time_of_day_label(day)
	return day and "день" or "ночь"
end
