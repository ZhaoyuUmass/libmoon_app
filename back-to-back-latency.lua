-- Send ethernet packet back to back in a sequential manner to measure latency

local lm      = require "libmoon"
local device  = require "device"
local memory  = require "memory"
local stats  = require "stats"

local PKT_SIZE = 60

function master(port, dstMac)
  print(port,dstMac)
  if dev == nil or dstMac == nil then
    print("Usage: ./Moongen path-to-libmoon_app/back-to-back-latency.lua dev dstMac")
  end
  local dev = device.config{
      port = tonumber(port),
      txQueues = 1,
      rxQueues = 1
  }
  lm.startTask("back_to_back_latency", dev, dstMac)  
end

function back_to_back_latency(dev, dstMac)
  
  local txQueue = dev.getTxQueue(0)
  local rxQueue = dev.getRxQueue(0)
  
  
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
    buf_sent:alloc(1)
    for i,buf in ipairs(buf_sent) do
      buf_sent:getUdpPacket()
    end 
    txQueue:send(buf_sent)
    
    -- wait for packet: no time out until packet returns
    local rx = rxQueue:tryRecv(buf_rcvd)
    for i = 1, rx do
      local pkt = buf_rcvd[i]:getUdpPacket()
      print("received",pkt)
    end  
    j = j+1  
  end
  
end