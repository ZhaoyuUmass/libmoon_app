-- Send ethernet packet back to back in a sequential manner to measure latency

local lm      = require "libmoon"
local device  = require "device"
local memory  = require "memory"
local stats  = require "stats"

local PKT_SIZE = 60

function master(port, dstMac)
  print(port,dstMac)
  if port == nil or dstMac == nil then
    print("Usage: ./Moongen path-to-libmoon_app/back-to-back-latency.lua port dstMac")
  end
  local dev = device.config{
      port = tonumber(port),
      txQueues = 1,
      rxQueues = 1
  }
  print("Ready to start subtask...")
  lm.startTask("back2backLatency", dev, dstMac)
  
  lm.waitForTasks()
end

function back2backLatency(dev, dstMac)
   
  local txQueue = dev:getTxQueue(0)
  local rxQueue = dev:getRxQueue(0)
  
  print("Start sub task with txQueue",txQueue,",rxQueue",rxQueue," and mac ",dstMac)
  -- memory pool with default values for all packets, this is our archetype
  local mempool = memory.createMemPool(function(buf)
    buf:getUdpPacket():fill{
      -- fields not explicitly set here are initialized to reasonable defaults
      ethSrc = queue, -- MAC of the tx device
      ethDst = dstMac,
      pktLength = PKT_SIZE
    }
  end)
  print("initialize memory pool")
  
  local buf_sent = mempool:bufArray()
  local buf_rcvd = memory.bufArray()
  local ctr = stats:newDevTxCounter("Load Traffic", dev, "plain")
  
  local j = 0
  while lm.running() do
    -- send a packet
    buf_sent:alloc(100)
    for i,buf in ipairs(buf_sent) do
      print(i)
      buf:getUdpPacket()
    end
    txQueue:send(buf_sent)
    print("packet ",j," has been sent")
    
    -- wait for packet: no time out until packet returns
    local rx = rxQueue:tryRecv(buf_rcvd)
    for i = 1, rx do
      local pkt = buf_rcvd[i]:getUdpPacket()
      print("received",pkt)
    end  
    j = j+1  
  end
  
end