-- Send ethernet packet back to back in a sequential manner to measure latency

local lm      = require "libmoon"
local device  = require "device"
local memory  = require "memory"
local stats   = require "stats"

local SRC_IP        = "10.0.0.1"
local DST_IP        = "10.0.1.1"
local SRC_PORT      = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT      = 2345
local PKT_SIZE      = 60

function master(port1, port2, dstMac)
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
    lm.startTask("back2backLatency", dev, dev, dstMac)
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
    lm.startTask("back2backLatency", txDev, rxDev, dstMac)
  end
  
  lm.waitForTasks()
end

function back2backLatency(txDev, rxDev, dstMac)
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
      udpSrc = SRC_PORT,
      udpDst = DST_PORT,
      pktLength = PKT_SIZE
    }
  end)
  print("initialize memory pool")
  
  local buf_sent = mempool:bufArray(1)
  local buf_rcvd = memory.bufArray()
  -- local ctr = stats:newDevTxCounter("Load Traffic", dev, "plain")
  
  local j = 0
  local begin = 0
  local tk = 0
  while lm.running() and j < 10000 do
    -- send a packet
    buf_sent:alloc(PKT_SIZE)
    for i,buf in ipairs(buf_sent) do
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
  end
  
end