-- Generate TCP or UDP traffic at a fixed rate, this can be used with a single port send and receive packets
-- NOTE: to run this test, you must make sure that you have at least 1 port available (no requirement for number of queues supported by each port, we assume there is only one queue in each port)
-- Usage: sudo ./MoonGen path-to-this-script/gen1

local mg     = require "moongen"
local lm     = require "libmoon"
local device = require "device"
local log    = require "log"
local stats  = require "stats"
local memory = require "memory"
local limiter = require "software-ratecontrol"


-- set addresses here
local PKT_LEN       = 60  -- max size: 1496
local SRC_IP        = "10.0.0.1"
local DST_IP        = "10.0.1.1"
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT_BASE = 2345

local PATTERN       = "cbr" -- traffic pattern, default is cbr, another option is poisson

local NUM_FLOWS     = 1024
local FLOWS_PER_SRC_IP = NUM_FLOWS*NUM_FLOWS
 
local SAMPLE_RATE = 10000 -- sample latency every 10,000 response

-- local TRAFFIC_GEN_PATTERN = "random" -- other option: "round-robin"
local TRAFFIC_GEN_PATTERN = "round-robin"

local SRC_IP_PREFIX = "10.0.0."

-- Helper functions --
local function integer(a,b)
  if a == nil and b == nil then
    return math.random(0, 100)
  end
  if b == nil then
    return math.random(a)
  end
  return math.random(a, b)
end

local function random_ipv4()
  local str = ''
  for i=1, 4 do
    str = str .. integer(0, 255)
    if i ~= 4 then str = str .. '.' end
  end
  return str
end

local function convert_ip_2_int(ip)
  local o1,o2,o3,o4 = ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
  return 2^24*o1 + 2^16*o2 + 2^8*o3 + o4
end

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
  parser:description("Edit the source to modify constants like IPs and ports.")
  parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
  parser:option("-f --flows", "Number of flows per device."):args(1):convert(tonumber):default(1)
  parser:option("-l --load", "Transmit rate in Mbit/s per device."):args(1):convert(tonumber):default(1)
  parser:option("-m --mac", "Destination MAC"):args(1)
  -- lesson learned: increase number of queues will not increase tx throughput
  -- parser:option("-q --queues", "Number of queues"):args(1):convert(tonumber):default(1)
  -- default is without rate limiter
  parser:option("-w --withRateLimiter", "with software rate limiter"):args(1):convert(tonumber):default(0)
  return parser:parse()
end

function master(args, ...)
  for k,v in pairs(args) do
    print(k,v)
  end
  for k,v in pairs(args.dev) do
    print(k,v)
  end
  print("With rate limiter", args.withRateLimiter)
  
  if args.withRateLimiter == 0 then
    args.withRateLimiter = false
  else
    args.withRateLimiter = true
  end
  print("DST MAC is:",args.mac)
  
  -- configure devices, we only need a single txQueue to send traffic and another port to send latency traffic
  -- Note: VF only supports 1 tx and rx queue on agave machines, that's why we hard code the number to 1 here
  for i,dev in pairs(args.dev) do
    local dev = device.config{
      port = dev,
      rxQueue = 1,
      txQueue = 1
    }
    args.dev[i] = dev
  end

  device.waitForLinks() 
  
  for i,dev in pairs(args.dev) do      
    -- initialize a local queue: local is very important here
    local queue = dev:getTxQueue(0)    
    -- the software rate limiter always works, but it can only scale up to 5.55Mpps (64b packet) with Intel 82599 NIC on EC2
    local rateLimiter = nil
    if args.withRateLimiter then
      rateLimiter = limiter:new(queue, PATTERN, 1 / args.load * 1000)
    end
     
    if args.mac then
      lm.startTask("txSlave", queue, args.mac, rateLimiter, args.flows, i)
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

function txSlave(queue, dstMac, rateLimiter, numFlows, idx)
  -- memory pool with default values for all packets, this is our archetype
  local mempool = memory.createMemPool(function(buf)
    buf:getUdpPacket():fill{
      -- fields not explicitly set here are initialized to reasonable defaults
      ethSrc = queue, -- MAC of the tx device
      -- ethSrc = "11:22:33:44:55:66", -- a fake mac address
      ethDst = dstMac,
      ip4Src = SRC_IP,
      ip4Dst = DST_IP,
      -- udpSrc = SRC_PORT,
      -- udpDst = DST_PORT,
      pktLength = PKT_LEN
    }
  end)
  -- a bufArray is just a list of buffers from a mempool that is processed as a single batch
  local bufs = mempool:bufArray()
  
  local SRC_IP_SET = {}
  local TOTAL_IPS = 1
  if TRAFFIC_GEN_PATTERN == "round-robin" then
    TOTAL_IPS = math.ceil(numFlows/FLOWS_PER_SRC_IP)
  elseif TRAFFIC_GEN_PATTERN == "random" then
    TOTAL_IPS = math.ceil(numFlows/NUM_FLOWS)
  end
  
  for i = 1, TOTAL_IPS do
    SRC_IP_SET[#SRC_IP_SET+1] = convert_ip_2_int(SRC_IP_PREFIX..i)
  end

  print("SRC_IP_SET:")
  for i,v in ipairs(SRC_IP_SET) do
    print(i,v)
  end
  
  local currentIp = SRC_IP_SET[1]
  local pktCtr = stats:newPktTxCounter("Packets sent"..idx, "plain")
  if TRAFFIC_GEN_PATTERN == "round-robin" then
    while lm.running() do -- check if Ctrl+c was pressed
      -- this actually allocates some buffers from the mempool the array is associated with
      -- this has to be repeated for each send because sending is asynchronous, we cannot reuse the old buffers here
      bufs:alloc(PKT_LEN)
      for i, buf in ipairs(bufs) do
        -- packet framework allows simple access to fields in complex protocol stacks      
        pktCtr:countPacket(buf)
        local cnt, _ = pktCtr:getThroughput()
        if cnt % FLOWS_PER_SRC_IP == 0 then
          currentIp = SRC_IP_SET[math.ceil(cnt/FLOWS_PER_SRC_IP)%TOTAL_IPS+1]
        end
        local pkt = buf:getUdpPacket()
        pkt.ip4:setSrc(currentIp)      
        --[[
        TODO: put the math here
        ]]--
        if numFlows< NUM_FLOWS then
          pkt.udp:setDstPort(DST_PORT_BASE)
          pkt.udp:setSrcPort(SRC_PORT_BASE + cnt%numFlows)
        elseif numFlows < FLOWS_PER_SRC_IP then
          pkt.udp:setDstPort(DST_PORT_BASE + math.floor((cnt%numFlows)/NUM_FLOWS))
          pkt.udp:setSrcPort(SRC_PORT_BASE + cnt%numFlows%NUM_FLOWS )
        else
          pkt.udp:setDstPort(DST_PORT_BASE + math.floor(cnt/NUM_FLOWS)%NUM_FLOWS )
          pkt.udp:setSrcPort(SRC_PORT_BASE + cnt%NUM_FLOWS )
        end
        pkt.payload.uint64[0] = lm:getCycles()
        
      end
      -- UDP checksums are optional, so using just IPv4 checksums would be sufficient here
      -- UDP checksum offloading is comparatively slow: NICs typically do not support calculating the pseudo-header checksum so this is done in SW
      bufs:offloadUdpChecksums()
      -- send out all packets and frees old bufs that have been sent
      -- queue:send(bufs)
      if rateLimiter then
        rateLimiter:send(bufs)
      else
        queue:send(bufs)
      end
      pktCtr:update()
    end
  elseif TRAFFIC_GEN_PATTERN == "random" then
    while lm.running() do -- check if Ctrl+c was pressed
      -- this actually allocates some buffers from the mempool the array is associated with
      -- this has to be repeated for each send because sending is asynchronous, we cannot reuse the old buffers here
      bufs:alloc(PKT_LEN)
      for i, buf in ipairs(bufs) do
        -- packet framework allows simple access to fields in complex protocol stacks      
        pktCtr:countPacket(buf)
        local cnt, _ = pktCtr:getThroughput()
        if cnt % FLOWS_PER_SRC_IP == 0 then
          currentIp = convert_ip_2_int(random_ipv4())
        end
        local pkt = buf:getUdpPacket()
        pkt.ip4:setSrc(currentIp)      
        pkt.udp:setDstPort( integer(0,65535) )
        pkt.udp:setSrcPort( integer(0,65535) )
        pkt.payload.uint64[0] = lm:getCycles()        
      end
      -- UDP checksums are optional, so using just IPv4 checksums would be sufficient here
      -- UDP checksum offloading is comparatively slow: NICs typically do not support calculating the pseudo-header checksum so this is done in SW
      bufs:offloadUdpChecksums()
      -- send out all packets and frees old bufs that have been sent
      -- queue:send(bufs)
      if rateLimiter then
        rateLimiter:send(bufs)
      else
        queue:send(bufs)
      end
      pktCtr:update()
    end    
  end
  pktCtr:finalize()  
  
  lm.sleepMillis(500)
  lm.stop()
end


function rxLatency(rxQueue)
  local tscFreq = mg.getCyclesFrequency()
  print("tscFreq",tscFreq)
  
  -- use whatever filter appropriate for your packet type
  -- queue:filterUdpTimestamps()
  local pktCtr = stats:newPktRxCounter("Packets received", "plain")
  local bufs = memory.bufArray()
  -- Dump the rxTs and txTs to a local file 
  local f = io.open("rcvd.txt", "w+")
  
  while mg.running() do
    local rx = rxQueue:tryRecv(bufs)
    for i = 1, rx do
      local buf = bufs[i]
      pktCtr:countPacket(buf)
      local ctr,_ = pktCtr:getThroughput() 
      -- sample packet to calculate latency
      if ctr % SAMPLE_RATE == 0 then
        local rxTs = mg:getCycles()
        local pkt = buf:getUdpPacket()
        local txTs = pkt.payload.uint64[0]
        f:write(tostring(tonumber(rxTs - txTs) / tscFreq * 10^9) .. " " .. tostring(tonumber(rxTs)) .. "\n")
      end   
    end
    pktCtr:update()
    bufs:freeAll()
  end
  pktCtr:finalize()   
  f:close() 
end