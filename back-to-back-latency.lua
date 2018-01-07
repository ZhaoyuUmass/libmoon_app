-- Send ethernet packet back to back in a sequential manner to measure latency

local lm      = require "libmoon"
local device  = require "device"
local memory  = require "memory"
local stats   = require "stats"

local SRC_IP        = "10.0.0.1"
local DST_IP        = "10.0.1.1"
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT_BASE = 2345
local PKT_SIZE      = 60

function master(port1, port2, dstMac, numReqs, random )
  
  print(port1, port2, dstMac)
  if port1 == nil or port2 == nil or dstMac == nil then
    print("Usage: ./Moongen path-to-libmoon_app/back-to-back-latency.lua port1 port2 dstMac")
  end
  
  if port1 == port2 then
    -- This is used for bare-metal setup
    local dev = device.config{
      port = tonumber(port1),
      txQueues = 1,
      rxQueues = 1
    }
    lm.startTask("back2backLatency", dev, dev, dstMac, tonumber(numReqs), tonumber(random) )
  else
    -- If 2 ports are different, use 2 different devices. This is used for SR-IOV setup
    local txDev = device.config{
        port = tonumber(port1),
        txQueues = 1
    }
    local rxDev = device.config{
        port = tonumber(port2),
        rxQueue = 1
    }
    print("Ready to start subtask...")
    lm.startTask("back2backLatency", txDev, rxDev, dstMac, tonumber(numReqs), tonumber(random) )
  end
  
  lm.waitForTasks()
end

function back2backLatency(txDev, rxDev, dstMac, numReqs, random)
  local tscFreq = lm.getCyclesFrequency()
  print("tscFreq",tscFreq)
  
  local txQueue = txDev:getTxQueue(0)
  local rxQueue = rxDev:getRxQueue(0)
  
  print("Start sub task with txQueue",txQueue,",rxQueue",rxQueue," and mac ",dstMac)
  -- memory pool with default values for all packets, this is our archetype
  local mempool = memory.createMemPool(function(buf)
    buf:getUdpPacket():fill{
      -- fields not explicitly set here are initialized to reasonable defaults
      ethSrc = txQueue, -- MAC of the tx device
      ethDst = dstMac,
      ip4Src = SRC_IP,
      ip4Dst = DST_IP,
      udpSrc = SRC_PORT_BASE,
      udpDst = DST_PORT_BASE,
      pktLength = PKT_SIZE
    }
  end)
  print("initialize memory pool")
  
  local buf_sent = mempool:bufArray(1)
  local buf_rcvd = memory.bufArray()
  -- local ctr = stats:newDevTxCounter("Load Traffic", dev, "plain")
  
  p1 = 0
  p2 = 0
  
  local j = 0
  local begin = 0
  local tk = 0
  while lm.running() and j < numReqs do
    -- send a packet
    buf_sent:alloc(PKT_SIZE)
    for i,buf in ipairs(buf_sent) do
      if random == 0 then
        pkt = buf:getUdpPacket()
        pkt.udp:setSrcPort(SRC_PORT_BASE+p1)
        pkt.udp:setDstPort(DST_PORT_BASE+p2)        
      end
      -- buf:dump()    
    end
    buf_sent:offloadUdpChecksums()
    
    tk = lm:getTime()
    begin = lm:getCycles()
    txQueue:send(buf_sent)
    -- print("packet ", j," has been sent")
    
    -- wait for packet: no time out until packet returns
    local rx = rxQueue:tryRecv(buf_rcvd)
    local elapsed = lm:getCycles() - begin 
    print("latency:", elapsed, (lm:getTime() - tk) )
    buf_rcvd:free(rx)
    j = j+1
    if random == 0 then
      p1 = p1+1    
      if p1 == 1000 then 
        p1 = 0
        p2 = p2+1
      end
    end
  end  
end