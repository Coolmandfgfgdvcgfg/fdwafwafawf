-- CFSocket.lua
-- Chunked, polling-based "socket" over ONE CFrame-like property on Players.
-- Folder = game.Players
-- Local endpoint = game.Players.LocalPlayer
--
-- Uses gethiddenproperty/sethiddenproperty for reads/writes (clean).
-- Supports ALL characters (raw bytes), chunking, reassembly, and optional ACK confirms.
--
-- Receive callback signature:
--   callback(fromPlayer, messageString)
--
-- Usage (client):
--   local sock = CFSocket.new(game.Players, "CloudEditCameraCoordinateFrame", 0)
--   sock:OnMessage(function(fromPlr, msg) print("FROM", fromPlr.Name, msg) end)
--   sock:Start()
--   sock:Send("hello 👋", { reliable=true, requireAcks=1, ackTimeout=0.4, resendInterval=0.1 })

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local CFSocket = {}
CFSocket.__index = CFSocket

-- ========= Packet format (9 bytes in Position => 72 bits => 3x24-bit ints) =========
-- DATA packet:
--   [1] kind = 0
--   [2] msgId (0..255)
--   [3] chunkIndex (1..255)
--   [4] totalChunks (1..255)
--   [5] payloadLen (0..4)
--   [6..9] payload bytes (0..4 bytes)
--
-- ACK packet:
--   [1] kind = 1
--   [2] msgId (0..255)
--   [3] senderHashHi
--   [4] senderHashLo
--   [5] ackFromHashHi
--   [6] ackFromHashLo
--   [7..9] unused (0)

local KIND_DATA = 0
local KIND_ACK  = 1
local CHUNK_PAYLOAD = 4

-- ========= helpers =========
local function clampInt(n, lo, hi)
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end

local function pack24(b1, b2, b3)
	return (b1 * 65536) + (b2 * 256) + b3
end

local function unpack24(n)
	n = math.floor(n + 0.5)
	local b1 = math.floor(n / 65536) % 256
	local b2 = math.floor(n / 256) % 256
	local b3 = n % 256
	return b1, b2, b3
end

local function bytesToABC(bytes9)
	local a = pack24(bytes9[1], bytes9[2], bytes9[3])
	local b = pack24(bytes9[4], bytes9[5], bytes9[6])
	local c = pack24(bytes9[7], bytes9[8], bytes9[9])
	return a, b, c
end

local function abcToBytes(a, b, c)
	local b1,b2,b3 = unpack24(a)
	local b4,b5,b6 = unpack24(b)
	local b7,b8,b9 = unpack24(c)
	return { b1,b2,b3,b4,b5,b6,b7,b8,b9 }
end

local function cfToABC(cf)
	local p = cf.Position
	local a = clampInt(math.floor(p.X + 0.5), 0, 16777215)
	local b = clampInt(math.floor(p.Y + 0.5), 0, 16777215)
	local c = clampInt(math.floor(p.Z + 0.5), 0, 16777215)
	return a,b,c
end

local function abcToCFrame(a,b,c)
	return CFrame.new(a, b, c) -- identity rotation
end

local function keyFromABC(a,b,c)
	return tostring(a) .. "," .. tostring(b) .. "," .. tostring(c)
end

local function stringToByteArray(s)
	local n = #s
	local out = table.create(n)
	for i = 1, n do
		out[i] = string.byte(s, i)
	end
	return out
end

local function byteArrayToString(bytes)
	local n = #bytes
	if n == 0 then return "" end
	local chars = table.create(n)
	for i = 1, n do
		chars[i] = string.char(bytes[i])
	end
	return table.concat(chars)
end

local function hash16(str)
	-- stable 16-bit hash
	local h = 2166136261
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * 16777619) % 4294967296
	end
	return bit32.band(h, 0xFFFF)
end

local function hi8(x) return bit32.rshift(x, 8) end
local function lo8(x) return bit32.band(x, 0xFF) end

local function fireCallbacks(callbacks, fromPlayer, message)
	for _, cb in ipairs(callbacks) do
		local ok, err = pcall(cb, fromPlayer, message)
		if not ok then
			warn("[CFSocket] callback error:", err)
		end
	end
end

-- ========= constructor =========
function CFSocket.new(folder: Instance, propName: string, pollRate: number?)
	assert(folder == Players, "CFSocket.new: folder must be game.Players")
	assert(type(propName) == "string" and #propName > 0, "CFSocket.new: propName must be a string")

	return setmetatable({
		Folder = folder,
		Prop = propName,

		LocalPlayer = Players.LocalPlayer,

		PollRate = pollRate or 0, -- 0 = every Heartbeat
		_callbacks = {},

		_lastKey = {}, -- [Player] = "a,b,c"

		-- _rx[fromPlayer][msgId] = { total, got, chunks, last }
		_rx = {},

		-- _acks[msgId] = { gotFrom = { [peerHash16]=true }, firstTime }
		_acks = {},

		_nextId = 0,

		_conn = nil,
		_accum = 0,
	}, CFSocket)
end

function CFSocket:OnMessage(callback)
	assert(typeof(callback) == "function", "OnMessage expects a function")
	table.insert(self._callbacks, callback)
end

-- ========= packet handlers =========
function CFSocket:_sendAck(msgId: number, originalSender: Player)
	-- ACK is broadcast by writing to OUR LocalPlayer property.
	local senderHash = hash16(originalSender.Name)
	local meHash = hash16(self.LocalPlayer.Name)

	local bytes9 = {
		KIND_ACK,
		msgId,
		hi8(senderHash), lo8(senderHash),
		hi8(meHash), lo8(meHash),
		0, 0, 0
	}

	local a,b,c = bytesToABC(bytes9)
	sethiddenproperty(self.LocalPlayer, self.Prop, abcToCFrame(a,b,c))
end

function CFSocket:_handleAck(fromPlayer: Player, bytes9)
	local msgId = bytes9[2]
	local senderHash = (bytes9[3] * 256) + bytes9[4]
	local ackFromHash = (bytes9[5] * 256) + bytes9[6]

	local myHash = hash16(self.LocalPlayer.Name)
	if senderHash ~= myHash then
		return -- not for us
	end

	local st = self._acks[msgId]
	if not st then return end
	st.gotFrom[ackFromHash] = true
end

function CFSocket:_handleData(fromPlayer: Player, bytes9)
	local msgId      = bytes9[2]
	local chunkIndex = bytes9[3]
	local total      = bytes9[4]
	local payLen     = bytes9[5]

	if total < 1 or chunkIndex < 1 or chunkIndex > total then
		return
	end
	if payLen < 0 or payLen > CHUNK_PAYLOAD then
		return
	end

	local payload = {}
	for i = 1, payLen do
		payload[i] = bytes9[5 + i]
	end

	local bySender = self._rx[fromPlayer]
	if not bySender then
		bySender = {}
		self._rx[fromPlayer] = bySender
	end

	local st = bySender[msgId]
	if not st then
		st = { total = total, got = 0, chunks = {}, last = os.clock() }
		bySender[msgId] = st
	end

	-- reset if total changed (new msg reused id etc.)
	if st.total ~= total then
		st.total = total
		st.got = 0
		st.chunks = {}
	end

	if not st.chunks[chunkIndex] then
		st.chunks[chunkIndex] = payload
		st.got += 1
	end
	st.last = os.clock()

	if st.got >= st.total then
		local allBytes = {}
		for i = 1, st.total do
			local ch = st.chunks[i]
			if not ch then
				return
			end
			for j = 1, #ch do
				table.insert(allBytes, ch[j])
			end
		end

		bySender[msgId] = nil

		local msg = byteArrayToString(allBytes)
		fireCallbacks(self._callbacks, fromPlayer, msg)

		-- confirm receipt back to sender (best-effort)
		self:_sendAck(msgId, fromPlayer)
	end
end

-- ========= polling =========
function CFSocket:_poll()
	-- cleanup stale partials
	local now = os.clock()
	for fromPlayer, byId in pairs(self._rx) do
		if (not fromPlayer) or (fromPlayer.Parent ~= Players) then
			self._rx[fromPlayer] = nil
		else
			for msgId, st in pairs(byId) do
				if now - st.last > 2.0 then
					byId[msgId] = nil
				end
			end
		end
	end

	for _, plr in ipairs(self.Folder:GetPlayers()) do
		if plr ~= self.LocalPlayer then
			local cf = gethiddenproperty(plr, self.Prop)
			if typeof(cf) == "CFrame" then
				local a,b,c = cfToABC(cf)
				local key = keyFromABC(a,b,c)

				if self._lastKey[plr] ~= key then
					self._lastKey[plr] = key

					local bytes9 = abcToBytes(a,b,c)
					local kind = bytes9[1]

					if kind == KIND_DATA then
						self:_handleData(plr, bytes9)
					elseif kind == KIND_ACK then
						self:_handleAck(plr, bytes9)
					end
				end
			end
		end
	end

	-- cleanup lastKey
	for plr in pairs(self._lastKey) do
		if not plr or plr.Parent ~= Players then
			self._lastKey[plr] = nil
		end
	end
end

function CFSocket:Start()
	if self._conn then return end

	-- init last keys so we don't trigger old data
	for _, plr in ipairs(self.Folder:GetPlayers()) do
		local cf = gethiddenproperty(plr, self.Prop)
		if typeof(cf) == "CFrame" then
			local a,b,c = cfToABC(cf)
			self._lastKey[plr] = keyFromABC(a,b,c)
		end
	end

	self._conn = RunService.Heartbeat:Connect(function(dt)
		if self.PollRate == 0 then
			self:_poll()
			return
		end
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

-- ========= send =========
function CFSocket:_makeDataPacket(msgId, chunkIndex, totalChunks, payloadBytes, payloadLen)
	local bytes9 = {
		KIND_DATA,
		msgId,
		chunkIndex,
		totalChunks,
		payloadLen,
		0,0,0,0
	}
	for i = 1, payloadLen do
		bytes9[5 + i] = payloadBytes[i]
	end
	return bytes9
end

function CFSocket:_writePacket(bytes9)
	local a,b,c = bytesToABC(bytes9)
	sethiddenproperty(self.LocalPlayer, self.Prop, abcToCFrame(a,b,c))
end

-- Send string (all chars)
-- options:
--   reliable (boolean)      resend until enough acks or timeout
--   requireAcks (number)   how many unique peers must ack (default 1 if reliable)
--   ackTimeout (number)
--   resendInterval (number)
function CFSocket:Send(message: any, options: table?)
	options = options or {}
	assert(typeof(message) == "string", "CFSocket:Send only supports string (all characters)")

	local reliable = options.reliable == true
	local ackTimeout = options.ackTimeout or 0.35
	local resendInterval = options.resendInterval or 0.10
	local requireAcks = options.requireAcks or (reliable and 1 or 0)

	local bytes = stringToByteArray(message)
	local totalChunks = math.max(1, math.ceil(#bytes / CHUNK_PAYLOAD))

	self._nextId = (self._nextId + 1) % 256
	local msgId = self._nextId

	-- build packets
	local packets = table.create(totalChunks)
	local idx = 1
	for chunkIndex = 1, totalChunks do
		local payload = {}
		local payLen = 0
		for j = 1, CHUNK_PAYLOAD do
			if idx <= #bytes then
				payLen += 1
				payload[payLen] = bytes[idx]
				idx += 1
			else
				break
			end
		end
		packets[chunkIndex] = self:_makeDataPacket(msgId, chunkIndex, totalChunks, payload, payLen)
	end

	-- blast once if not reliable
	if not reliable then
		for i = 1, totalChunks do
			self:_writePacket(packets[i])
		end
		return msgId
	end

	-- reliable tracking
	self._acks[msgId] = {
		gotFrom = {},
		firstTime = os.clock(),
	}

	-- initial send
	for i = 1, totalChunks do
		self:_writePacket(packets[i])
	end

	local start = os.clock()
	local lastResend = start

	-- blocking wait (wrap in task.spawn if you want non-blocking)
	while true do
		RunService.Heartbeat:Wait()

		local st = self._acks[msgId]
		if not st then
			return msgId
		end

		local count = 0
		for _ in pairs(st.gotFrom) do
			count += 1
		end

		if count >= requireAcks then
			self._acks[msgId] = nil
			return msgId
		end

		local now = os.clock()
		if now - start >= ackTimeout then
			self._acks[msgId] = nil
			return msgId
		end

		if now - lastResend >= resendInterval then
			lastResend = now
			for i = 1, totalChunks do
				self:_writePacket(packets[i])
			end
		end
	end
end

CFSocket.KIND_DATA = KIND_DATA
CFSocket.KIND_ACK = KIND_ACK
CFSocket.CHUNK_PAYLOAD = CHUNK_PAYLOAD

return CFSocket
