-- CFSocket.lua
-- Polling-based "socket" system that uses ONE CFrame per message on Parts inside a Folder.
--
-- Message types supported:
--   - string  -> encoded into CFrame.Position (X/Y/Z), rotation = identity
--   - Vector3 -> stored as CFrame.new(v) with a special rotation tag, decoded back to Vector3
--   - CFrame  -> stored raw, passed through raw (not encoded/decoded)
--
-- Receive callback signature:
--   callback(part, message)  -- message is string | Vector3 | CFrame

local RunService = game:GetService("RunService")

local CFSocket = {}
CFSocket.__index = CFSocket

local ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
local MAP = {}
for i = 1, #ALPHABET do
	MAP[ALPHABET:sub(i, i)] = i - 1 -- 0..63
end

-- 72 bits total (24 bits per axis)
-- 4 bits length + 6 bits per char => up to 11 chars (66 bits) + 4 = 70 bits
local MAX_LEN = 11

local VECTOR3_TAG = CFrame.Angles(0, 0, math.rad(90))

local function writeBits(st, v, bits)
	for i = bits - 1, 0, -1 do
		local bit = (math.floor(v / (2 ^ i)) % 2)
		local idx = st.bitPos

		if idx < 24 then
			st.a = st.a * 2 + bit
		elseif idx < 48 then
			st.b = st.b * 2 + bit
		else
			st.c = st.c * 2 + bit
		end

		st.bitPos += 1
	end
end

local function encodeToCFrame(str)
	local len = string.len(str)
	assert(len <= MAX_LEN, ("Message too long (max %d chars)"):format(MAX_LEN))

	local st = { a = 0, b = 0, c = 0, bitPos = 0 }

	-- length (4 bits)
	writeBits(st, len, 4)

	-- characters (6 bits each)
	for i = 1, len do
		local ch = str:sub(i, i)
		local v = MAP[ch]
		assert(v ~= nil, ("Unsupported char: %q (allowed: %s)"):format(ch, ALPHABET))
		writeBits(st, v, 6)
	end

	-- pad remaining bits to 72
	while st.bitPos < 72 do
		writeBits(st, 0, 1)
	end

	-- Identity rotation marks it as a string packet.
	return CFrame.new(st.a, st.b, st.c)
end

-- Bit Unpacking (decode CFrame -> string)
local function readBit(a, b, c, idx)
	if idx < 24 then
		return math.floor(a / (2 ^ (23 - idx))) % 2
	elseif idx < 48 then
		local j = idx - 24
		return math.floor(b / (2 ^ (23 - j))) % 2
	else
		local j = idx - 48
		return math.floor(c / (2 ^ (23 - j))) % 2
	end
end

local function decodeFromCFrame(cf)
	local p = cf.Position
	local a = math.floor(p.X + 0.5)
	local b = math.floor(p.Y + 0.5)
	local c = math.floor(p.Z + 0.5)

	local bitPos = 0
	local function readBits(bits)
		local v = 0
		for _ = 1, bits do
			v = v * 2 + readBit(a, b, c, bitPos)
			bitPos += 1
		end
		return v
	end

	local len = readBits(4)
	if len < 0 or len > MAX_LEN then
		return nil
	end

	local out = table.create(len)
	for i = 1, len do
		local sym = readBits(6) -- 0..63
		out[i] = ALPHABET:sub(sym + 1, sym + 1)
	end

	return table.concat(out)
end

local function posKey(cf)
	local p = cf.Position
	return ("%d,%d,%d"):format(
		math.floor(p.X + 0.5),
		math.floor(p.Y + 0.5),
		math.floor(p.Z + 0.5)
	)
end

function CFSocket.new(folder: Instance, pollRate: number?)
	assert(folder and folder:IsA("Folder"), "CFSocket.new(folder): folder must be a Folder")

	return setmetatable({
		Folder = folder,
		PollRate = pollRate or 1 / 30, -- seconds
		_callbacks = {},              -- array of callbacks(part, msg)
		_last = {},                   -- [Player] = "x,y,z"
		_conn = nil,
		_accum = 0,
	}, CFSocket)
end

function CFSocket:OnMessage(callback: (Player, any) -> ())
	assert(typeof(callback) == "function", "OnMessage expects a function")
	table.insert(self._callbacks, callback)
end

local function fireCallbacks(callbacks, part, msg)
	for _, cb in ipairs(callbacks) do
		local ok, err = pcall(cb, part, msg)
		if not ok then
			warn("[CFSocket] callback error:", err)
		end
	end
end

function CFSocket:_poll()
	for _, inst in ipairs(self.Folder:GetChildren()) do
		if inst:IsA("Player") then
			local cf = gethiddenproperty(inst,"CloudEditCameraCoordinateFrame")
			local key = posKey(cf)

			if self._last[inst] ~= key then
				self._last[inst] = key

				-- Determine packet type by rotation
				local rot = cf - cf.Position

				-- Vector3 packet
				if rot == VECTOR3_TAG then
					fireCallbacks(self._callbacks, inst, cf.Position)

					-- String packet
				elseif rot == CFrame.identity then
					local msg = decodeFromCFrame(cf)
					if msg then
						fireCallbacks(self._callbacks, inst, msg)
					end

					-- Raw CFrame packet
				else
					fireCallbacks(self._callbacks, inst, cf)
				end
			end
		end
	end

	-- cleanup removed parts
	for part in pairs(self._last) do
		if not part or part.Parent ~= self.Folder then
			self._last[part] = nil
		end
	end
end

function CFSocket:Start()
	if self._conn then return end

	-- init keys
	for _, inst in ipairs(self.Folder:GetChildren()) do
		if inst:IsA("Player") then
			self._last[inst] = posKey(inst.CFrame)
		end
	end

	self._conn = RunService.Heartbeat:Connect(function(dt)
		self._accum += dt
		if self._accum >= self.PollRate then
			self._accum = 0
			self:_poll()
		end
	end)
end

function CFSocket:Stop()
	if self._conn then
		self._conn:Disconnect()
		self._conn = nil
	end
end

-- Send:
--   string  -> encoded packet (identity rotation)
--   Vector3 -> CFrame.new(v) * VECTOR3_TAG
--   CFrame  -> raw passthrough
function CFSocket:Send(message: any)
	local part = game.Players.LocalPlayer
	assert(part and part:IsA("Player"), "Send expects a Player")

	local t = typeof(message)
	if t == "string" then
		sethiddenproperty(part, "CloudEditCameraCoordinateFrame", encodeToCFrame(message))
	elseif t == "Vector3" then
		sethiddenproperty(part, "CloudEditCameraCoordinateFrame", CFrame.new(message) * VECTOR3_TAG)
	elseif t == "CFrame" then
		sethiddenproperty(part, "CloudEditCameraCoordinateFrame", message)
	else
		error("CFSocket:Send message must be string, Vector3, or CFrame")
	end
end

CFSocket.MAX_LEN = MAX_LEN
CFSocket.ALPHABET = ALPHABET
CFSocket.VECTOR3_TAG = VECTOR3_TAG

return CFSocket
