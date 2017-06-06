-- Generate TCP or UDP traffic at a fixed rate
-- NOTE: to run this test, you must make sure that you have at least 2 ports
-- Usage: sudo ./MoonGen 

local mg     = require "moongen"
local lm     = require "libmoon"
local device = require "device"
local log    = require "log"
local stats  = require "stats"
local memory = require "memory"
local limiter = require "software-ratecontrol"


-- set addresses here
local DST_MAC       = "96:76:c5:40:66:21" -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local PKT_LEN       = 60
local SRC_IP        = "10.0.1.5"
local DST_IP        = "10.0.1.4"
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT      = 1234
local NUM_FLOWS     = 1000
local pattern       = "cbr" -- traffic pattern, default is cbr, another option is poisson

local PKT_SIZE = 60
local NUM_PKTS = 10^4

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
  parser:description("Edit the source to modify constants like IPs and ports.")
  parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
  parser:option("-f --flows", "Number of flows per device."):args(1):convert(tonumber):default(1)
  parser:option("-r --rate", "Transmit rate in Mbit/s per device."):args(1):convert(tonumber):default(1)
  parser:option("-s --source", "source IP"):args(1)
  parser:option("-d --dest", "destination IP"):args(1)
  parser:option("-m --mac", "destination MAC"):args(1)
  parser:flag("-t --tcp", "Use TCP.")
  return parser:parse()
end

function master(args,...)
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
  stats.startStatsTask{devices = args.dev}
  
  -- start tx tasks
  for i,dev in pairs(args.dev) do
    if i == 1 then
      -- the first port is used for a latency task
      -- initalize local queues
      local rxQueue = dev:getRxQueue(0)
      local txQueue = dev:getTxQueue(0)
      -- use 1/100 traffic rate for latency task
      local rateLimiter = limiter:new(txQueue, pattern, 1/0.01*1000)
      lm.startTask("txLatency", txQueue, DST_MAC, rateLimiter)
      lm.startTask("rxLatency", rxQueue)
    else
      -- the rest of the queue is used for sending traffic
      
      -- initialize a local queue: local is very important here
      local queue = dev:getTxQueue(0)    
      -- the software rate limiter always works, but it can only scale up to 5.55Mpps (64b packet) with Intel 82599 NIC on EC2
      local rateLimiter = limiter:new(queue, pattern, 1 / args.rate * 1000)
      --[[ this method does not work with VF
       set rate on each device
       queue:setRate(args.rate)
      ]]--
      lm.startTask("txSlave", queue, DST_MAC, rateLimiter)   
    end
  end
  lm.waitForTasks()
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
      pktLength = PKT_SIZE   
    }
  end)
  mg.sleepMillis(1000) -- ensure that the load task is running
  local bufs = mem:bufArray()
  local j = 0
  local ctr = stats:newDevTxCounter("Load Traffic", queue.dev, "plain")
  local tm_sent = {}
  
  while j < 100 and mg.running() do
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
    limiter:send(bufs)
    --rateLimiter:wait()
    --rateLimiter:reset()
    j = j + 1
    ctr:update()
  end
end

function rxLatency(rxQueue)
  local tscFreq = mg.getCyclesFrequency()
  print("tscFreq",tscFreq)
  
  local tm_rcvd = {}
  
  -- use whatever filter appropriate for your packet type
  -- queue:filterUdpTimestamps()
  local ctr = stats:newDevRxCounter("Received Traffic", rxQueue.dev, "plain")
  local bufs = memory.bufArray()
  while mg.running() do
    local rx = rxQueue:tryRecv(bufs, 100)
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



