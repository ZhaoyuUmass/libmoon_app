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
local PKT_LEN       = 60  -- max size: 1496
local SRC_IP        = "10.0.0.1"
local DST_IP        = "10.0.1.1"
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT_BASE = 2345

 
local SAMPLE_RATE = 10000 -- sample latency every 10,000 response

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
  parser:description("Edit the source to modify constants like IPs and ports.")
  parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
  parser:option("-r --rx", "specific rx device"):args(1):convert(tonumber)
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
  
  -- configure devices, we only need a single txQueue to send traffic and another port to send latency traffic
  -- Note: VF only supports 1 tx and rx queue on agave machines, that's why we hard code the number to 1 here
  for i,dev in pairs(args.dev) do    
    local dev = device.config{
      port = dev,
      rxQueues = 1
    }
    args.dev[i] = dev
  end

  device.waitForLinks()  
 
  -- start tx tasks
  for i,dev in pairs(args.dev) do        
    print(">>>>>>> start rx task on ", i)
    lm.startTask("rxLatency", dev:getRxQueue(0))     
  end
    
  lm.waitForTasks()
  
  for i,dev in pairs(args.dev) do
    dev:stop()
  end
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