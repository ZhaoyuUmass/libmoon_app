--- Software timestamping precision test.
--- (Used for an evaluation for a paper)
local mg     = require "moongen"
local device = require "device"
local memory = require "memory"
local stats  = require "stats"
local timer  = require "timer"
local pf     = require "pf"
local limiter = require "software-ratecontrol"


local PKT_SIZE = 60
local NUM_FLOWS = 1000
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT      = 1234

local NUM_PKTS = 10^4



function master(txPort, rxPort, load)
	if not txPort or not rxPort or type(load)~="number" then
		errorf("usage: txPort rxPort load")
	end
	local txDev = device.config{port = txPort, rxQueues = 1, txQueues = 1}
	local rateLimiter = limiter:new(txDev:getTxQueue(0), "cbr", 1 / load * 1000)
	
	device.waitForLinks()
	mg.startTask("txTimestamper", txDev:getTxQueue(0), rateLimiter)
	mg.startTask("rxTimestamper", txDev:getRxQueue(0))
	mg.waitForTasks()
end

function txTimestamper(queue, rateLimiter)
	print("start sending task")
	local mem = memory.createMemPool(function(buf)
		-- just to use the default filter here
		-- you can use whatever packet type you want
		buf:getUdpPacket():fill{
		  -- this is a right setting for server and client on different hosts
		  ethSrc = queue, -- MAC of the tx device
      ethDst = "02:dc:71:13:e9:56",
      ip4Src = "10.0.1.5",
      ip4Dst = "10.0.1.4",
  		pktLength = PKT_SIZE
  		--  		
		}
	end)
	print("queue",queue)
	mg.sleepMillis(1000) -- ensure that the load task is running
	local bufs = mem:bufArray()
	local j = 0
	local ctr = stats:newDevTxCounter("Load Traffic", queue.dev, "plain")
	local tm_sent = {}
	
	while j < NUM_PKTS and mg.running() do
		bufs:alloc(PKT_SIZE)
		for i, buf in ipairs(bufs) do
      -- packet framework allows simple access to fields in complex protocol stacks
      local pkt = buf:getUdpPacket()
      pkt.udp:setSrcPort(SRC_PORT_BASE + math.random(0, NUM_FLOWS - 1))
      local tm = j*NUM_PKTS+i -- mg:getCycles()
      -- print("current cycle:",tm)
      pkt.payload.uint64[0] = tm
      tm_sent[#tm_sent+1] = tm
      -- print("payload:",tonumber(pkt.payload.uint64[0]))
    end
    bufs:offloadUdpChecksums()
		-- queue:sendWithTimestamp(bufs)
		-- queue:send(bufs)
		rateLimiter:send(bufs)
		--rateLimiter:wait()
		--rateLimiter:reset()
		j = j + 1
		ctr:update()
	end
	
	local f = io.open("sent.txt", "w+")
  for i, v in ipairs(tm_sent) do
    f:write(tostring(v) .. "\n")
  end
  f:close()
  ctr:finalize()
  mg.sleepMillis(5000)
  mg.stop()
end

function rxTimestamper(rxQueue)
	print("start statistic job")
	
	local tscFreq = mg.getCyclesFrequency()
	print("tscFreq",tscFreq)
	
	local tm_rcvd = {}
	
	-- use whatever filter appropriate for your packet type
	-- queue:filterUdpTimestamps()
	local ctr = stats:newDevRxCounter("Received Traffic", rxQueue.dev, "plain")
	local bufs = memory.bufArray()
	while mg.running() do
	  local rx = rxQueue:tryRecv(bufs, 1000)
    for i = 1, rx do
      local pkt = bufs[i]:getUdpPacket()
      -- local dst = pkt.eth:getDst()
      -- local src = pkt.eth:getSrc()
      -- local rxTs = bufs[i].udata64
      -- local txTs = bufs[i]:getSoftwareTxTimestamp()
      -- print("received a packet with payload", tonumber(pkt.payload.uint64[0]))
      
      local rxTs = pkt.payload.uint64[0]
      tm_rcvd[#tm_rcvd+1] = tonumber(rxTs)
      
      -- print("received a packet", rxTs, txTs, tonumber(rxTs - txTs) / tscFreq * 10^9)      
      ctr:update()
    end
    --[[
		local numPkts = queue:recvWithTimestamps(bufs)
		for i = 1, numPkts do
			local rxTs = bufs[i].udata64
			local txTs = bufs[i]:getSoftwareTxTimestamp()
			print("received a packet",rxTs, txTs, tonumber(rxTs - txTs) / tscFreq * 10^9)
			results[#results + 1] = tonumber(rxTs - txTs) / tscFreq * 10^9 -- to nanoseconds
			ctr:update()
		end
		bufs:free(numPkts)
		]]--
	end
	ctr:finalize()
	
	local f = io.open("rcvd.txt", "w+")
	for i, v in ipairs(tm_rcvd) do
		f:write(tostring(v) .. "\n")
	end
	f:close()	
end

