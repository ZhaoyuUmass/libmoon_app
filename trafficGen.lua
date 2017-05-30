-- Generate TCP or UDP traffic at a rate

local lm     = require "libmoon"
local device = require "device"
local log    = require "log"
local stats  = require "stats"
local memory = require "memory"
local limiter = require "software-ratecontrol"


-- set addresses here
local DST_MAC       = nil -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local PKT_LEN       = 60
local SRC_IP        = "10.0.0.10"
local DST_IP        = "10.1.0.10"
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT      = 1234
local NUM_FLOWS     = 1000
local pattern       = "cbr" -- traffic pattern, default is cbr, another option is poisson

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
  
  -- configure devices and queues
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
  
  -- print statistics
  stats.startStatsTask{devices = args.dev}
  
  -- start tx tasks
  for _,dev in pairs(args.dev) do
    -- initialize a local queue: local is very important here
    local queue = dev:getTxQueue(0)
    -- the software rate limiter always works
    local rateLimiter = limiter:new(queue, pattern, 1 / rate * 1000)
    -- set rate on each device
    -- queue:setRate(args.rate)
    lm.startTask("txSlave", queue, DST_MAC, rateLimiter)   
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