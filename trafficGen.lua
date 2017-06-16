-- Generate TCP or UDP traffic at a fixed rate
-- NOTE: to run this test, you must make sure that you have at least 2 ports (no requirement for number of queues supported by each port, we assume there is only one queue in each port)
-- Usage: sudo ./MoonGen path-to-this-script/trafficGen

local mg     = require "moongen"
local lm     = require "libmoon"
local device = require "device"
local log    = require "log"
local stats  = require "stats"
local memory = require "memory"
local limiter = require "software-ratecontrol"


-- set addresses here
local DST_MAC       = nil -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local PKT_LEN       = 60
local SRC_IP        = "10.0.1.5"
local DST_IP        = "10.0.1.4"
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT      = 1234
local NUM_FLOWS     = 1000
local pattern       = "cbr" -- traffic pattern, default is cbr, another option is poisson

local PKT_SIZE = 60
local NUM_PKTS = 10^5

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
  parser:description("Edit the source to modify constants like IPs and ports.")
  parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
  parser:option("-f --flows", "Number of flows per device."):args(1):convert(tonumber):default(1)
  parser:option("-r --rate", "Transmit rate in Mbit/s per device."):args(1):convert(tonumber):default(1)
  parser:option("-m --mac", "destination MAC"):args(1)
  -- parser:flag("-t --tcp", "Use TCP.")
  parser:flag("-l --latency", "Measure latency")
  return parser:parse()
end

function master(args, ...)
  for k,v in pairs(args) do
    print(k,v)
  end
  for k,v in pairs(args.dev) do
    print(k,v)
  end
  print("SRC_IP",SRC_IP)
  print("DST_IP",DST_IP)
  print("DST_MAC",DST_MAC)
  
  -- configure devices, we only need a single txQueue to send traffic and another port to send latency traffic
  -- Note: VF only supports 1 tx and rx queue on agave machines, that's why we hard code the number to 1 here
  local arpQueues = {}
  for i,dev in pairs(args.dev) do
    local dev = device.config{
      port = dev,
      txQueues = 1,
      rxQueues = 1
    }
    args.dev[i] = dev
  end

  device.waitForLinks()
  
  -- print statistics for both tx and rx queues
  stats.startStatsTask{txDevices = args.dev}
  
  -- start tx tasks
  for i,dev in pairs(args.dev) do
    -- initialize a local queue: local is very important here
    local queue = dev:getTxQueue(0)    
    -- the software rate limiter always works, but it can only scale up to 5.55Mpps (64b packet) with Intel 82599 NIC on EC2
    local rateLimiter = limiter:new(queue, pattern, 1 / args.rate * 1000)
    if DST_MAC then
      lm.startTask("txSlave", queue, DST_MAC, rateLimiter) 
    elseif args.mac then
      lm.startTask("txSlave", queue, args.mac, rateLimiter)
    else
      print("no mac specified")
    end
    
    lm.startTask("rxLatency", dev:getRxQueue(0))
  end
  
  
  lm.waitForTasks()
  
  for i,dev in pairs(args.dev) do
    dev:stop()
  end
end

function txSlave(queue, dstMac, rateLimiter)
  -- memory pool with default values for all packets, this is our archetype
  local mempool = memory.createMemPool(function(buf)
    buf:getUdpPacket():fill{
      -- fields not explicitly set here are initialized to reasonable defaults
      ethSrc = queue, -- MAC of the tx device
      ethDst = dstMac,
      ip4Src = SRC_IP,
      ip4Dst = DST_IP,
      udpSrc = SRC_PORT,
      udpDst = DST_PORT,
      pktLength = PKT_LEN
    }
  end)
  -- a bufArray is just a list of buffers from a mempool that is processed as a single batch
  local bufs = mempool:bufArray()
  while lm.running() do -- check if Ctrl+c was pressed
    -- this actually allocates some buffers from the mempool the array is associated with
    -- this has to be repeated for each send because sending is asynchronous, we cannot reuse the old buffers here
    bufs:alloc(PKT_LEN)
    for i, buf in ipairs(bufs) do
      -- packet framework allows simple access to fields in complex protocol stacks
      local pkt = buf:getUdpPacket()
      pkt.udp:setSrcPort(SRC_PORT_BASE + math.random(0, NUM_FLOWS - 1))
      pkt.payload.uint64[0] = lm:getCycles()
    end
    -- UDP checksums are optional, so using just IPv4 checksums would be sufficient here
    -- UDP checksum offloading is comparatively slow: NICs typically do not support calculating the pseudo-header checksum so this is done in SW
    bufs:offloadUdpChecksums()
    -- send out all packets and frees old bufs that have been sent
    -- queue:send(bufs)
    rateLimiter:send(bufs)
  end
end

function txLatency(queue, dstMac, limiter)
  local mem = memory.createMemPool(function(buf)
    -- just to use the default filter here
    -- you can use whatever packet type you want
    buf:getUdpPacket():fill{
      -- this is a right setting for server and client on different hosts
      ethSrc = queue, -- MAC of the tx device
      ethDst = dstMac,
      ip4Src = SRC_IP,
      ip4Dst = DST_IP,
      udpSrc = SRC_PORT,
      udpDst = DST_PORT,
      pktLength = PKT_LEN  
    }
  end)
  mg.sleepMillis(1000) -- ensure that the load task is running
  local bufs = mem:bufArray()
  local ctr = stats:newDevTxCounter("Load Traffic", queue.dev, "plain")
  local tm_sent = {}
  
  local j = 0
  while mg.running() and j < NUM_PKTS do
    bufs:alloc(1)
    for i, buf in ipairs(bufs) do
      -- packet framework allows simple access to fields in complex protocol stacks
      local pkt = buf:getUdpPacket()
      pkt.udp:setSrcPort(SRC_PORT_BASE)
      local tm = mg:getCycles()
      pkt.payload.uint64[0] = tm
      tm_sent[#tm_sent+1] = tm
      -- print("payload:",tonumber(pkt.payload.uint64[0]))
    end
    bufs:offloadUdpChecksums()
    limiter:send(bufs)
    ctr:update()
    j = j+1
  end
  
  local f = io.open("sent.txt", "w+")
  for i, v in ipairs(tm_sent) do
    f:write(tostring(v) .. "\n")
  end
  f:close()
  ctr:finalize()
  
  mg.sleepMillis(500)
  mg.stop()
end

function rxLatency(rxQueue)
  local tscFreq = mg.getCyclesFrequency()
  print("tscFreq",tscFreq)
  
  -- local tm_rcvd = {}
  
  -- use whatever filter appropriate for your packet type
  -- queue:filterUdpTimestamps()
  local ctr = stats:newDevRxCounter("Received Traffic", rxQueue.dev, "plain")
  local bufs = memory.bufArray()
  while mg.running() do
    local rx = rxQueue:tryRecv(bufs, 1000)
    for i = 1, rx do
      local buf = bufs[i]
      local pkt = buf:getUdpPacket()

      local rxTs = pkt.payload.uint64[0]
      
      -- tm_rcvd[#tm_rcvd+1] = rxTs
      -- print("received", rxTs)
      -- print("received a packet", rxTs, txTs, tonumber(rxTs - txTs) / tscFreq * 10^9)      
      -- ctr:update()
      ctr:countPacket(buf)
    end
    ctr:update()
    bufs:freeAll()
  end
  ctr:finalize()
  --[[
  local f = io.open("rcvd.txt", "w+")
  for i, v in ipairs(tm_rcvd) do
    f:write(tostring(v) .. "\n")
  end
  f:close() 
  ]]--
end

--[[
-- Helper functions --
function integer(a,b)
  if a == nil and b == nil then
    return math.random(0, 100)
  end
  if b == nil then
    return math.random(a)
  end
  return math.random(a, b)
end

function random_ipv4()
  local str = ''
  for i=1, 4 do
    str = str .. integer(0, 255)
    if i ~= 4 then str = str .. '.' end
  end
  return str
end
]]--