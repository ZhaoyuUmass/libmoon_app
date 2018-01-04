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
  while lm.running() do
    -- send a packet
    buf_sent:alloc(PKT_SIZE)
    for i,buf in ipairs(buf_sent) do
      print(i)
      buf:dump()    
    end
    buf_sent:offloadUdpChecksums()
    txQueue:send(buf_sent)
    print("packet ", j," has been sent")
    
    
    -- wait for packet: no time out until packet returns
    local rx = rxQueue:tryRecv(buf_rcvd, 100)
    for i = 1, rx do
      local pkt = buf_rcvd[i]:getUdpPacket()
      print("received",pkt)
    end  
    j = j+1  
  end
  
end