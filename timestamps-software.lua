--- Software timestamping precision test.
--- (Used for an evaluation for a paper)
local mg     = require "moongen"
local device = require "device"
local memory = require "memory"
local stats  = require "stats"
local timer  = require "timer"
local pf     = require "pf"


local PKT_SIZE = 60
local NUM_FLOWS = 1000
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT      = 1234

local NUM_PKTS = 10^6



function master(txPort, rxPort)
	if not txPort or not rxPort then
		errorf("usage: txPort rxPort")
	end
	local txDev = device.config{port = txPort, rxQueues = 1, txQueues = 1}
	-- local rxDev = device.config{port = rxPort, rxQueues = 1, txQueues = 1}
	device.waitForLinks()
	mg.startTask("txTimestamper", txDev:getTxQueue(0))
	-- mg.startTask("rxTimestamper", rxDev:getRxQueue(0))
	mg.waitForTasks()
end

function loadSlave(queue)
	local mem = memory.createMemPool(function(buf)
		buf:getEthPacket():fill{
		}
	end)
	local bufs = mem:bufArray()
	-- local ctr = stats:newDevTxCounter("Load Traffic", queue.dev, "plain")
	while mg.running() do
		bufs:alloc(PKT_SIZE)
		queue:send(bufs)
		-- ctr:update()
	end
	--ctr:finalize()
end

function txTimestamper(queue)
	print("start sending task")
	local mem = memory.createMemPool(function(buf)
		-- just to use the default filter here
		-- you can use whatever packet type you want
		buf:getUdpPacket():fill{
		  --[[ this is a right setting for server and client on different hosts
		  ethSrc = queue, -- MAC of the tx device
      ethDst = "02:dc:71:13:e9:56",
      ip4Src = "10.0.1.5",
      ip4Dst = "10.0.1.4",
      udpSrc = SRC_PORT,
      udpDst = DST_PORT,
  		pktLength = PKT_SIZE
  		]]--
  		
  		--this is test setting for server and client on a same host
  		ethSrc = queue, -- MAC of the tx device
      ethDst = "02:e5:5e:ee:d0:34",
      ip4Src = "10.0.1.5",
      ip4Dst = "10.0.2.5",
      udpSrc = SRC_PORT,
      udpDst = DST_PORT,
      pktLength = PKT_SIZE
      --
		}
	end)
	print("queue",queue)
	mg.sleepMillis(1000) -- ensure that the load task is running
	local bufs = mem:bufArray()
	local rateLimiter = timer:new(0.0001) -- 10kpps timestamped packets
	local j = 0
	local ctr = stats:newDevTxCounter("Load Traffic", queue.dev, "plain")
	while j < NUM_PKTS and mg.running() do
		bufs:alloc(PKT_SIZE)
		for i, buf in ipairs(bufs) do
      -- packet framework allows simple access to fields in complex protocol stacks
      local pkt = buf:getUdpPacket()
      pkt.udp:setSrcPort(SRC_PORT_BASE + math.random(0, NUM_FLOWS - 1))
    end
    bufs:offloadUdpChecksums()
		--queue:send(bufs)
		queue:sendWithTimestamp(bufs)
		-- rateLimiter:send(bufs)
		rateLimiter:wait()
		rateLimiter:reset()
		j = j + 1
		ctr:update()
	end
	ctr:finalize()
	mg.sleepMillis(500)
	mg.stop()
end

function rxTimestamper(queue)
	print("start statistic job")
	
	local tscFreq = mg.getCyclesFrequency()
	print("tscFreq",tscFreq)
	
	-- use whatever filter appropriate for your packet type
	-- queue:filterUdpTimestamps()
	local results = {}
	local rxts = {}
	local ctr = stats:newDevRxCounter("Received Traffic", queue.dev, "plain")
	local bufs = memory.bufArray()
	while mg.running() do
		local numPkts = queue:recvWithTimestamps(bufs)
		for i = 1, numPkts do
			local rxTs = bufs[i].udata64
			local txTs = bufs[i]:getSoftwareTxTimestamp()
			print("received a packet",rxTs, txTs, tonumber(rxTs - txTs) / tscFreq * 10^9)
			results[#results + 1] = tonumber(rxTs - txTs) / tscFreq * 10^9 -- to nanoseconds
			rxts[#rxts + 1] = tonumber(rxTs)
			ctr:update()
		end
		bufs:free(numPkts)
		--[[
		local rx = queue:tryRecv(bufs)
		print(">>>>> rx",rx)
		for i=1, rx do
		  local buf = bufs[i]
		  ctr:update()
		end
		bufs:free(rx)
		]]--
	end
	ctr:finalize()
	print(table.getn(results))
	print(table.getn(rxts))
	--[[
	local f = io.open("pings.txt", "w+")
	for i, v in ipairs(results) do
		f:write(v .. "\n")
		print(i,vi)
	end
	f:close()
	]]--
end

