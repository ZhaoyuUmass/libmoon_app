-- Generate TCP or UDP traffic

local lm     = require "libmoon"
local device = require "device"
local log    = require "log"

-- set addresses here
local DST_MAC       = nil -- resolved via ARP on GW_IP or DST_IP, can be overriden with a string here
local PKT_LEN       = 60
local SRC_IP        = "10.0.0.10"
local DST_IP        = "10.1.0.10"
local SRC_PORT_BASE = 1234 -- actual port will be SRC_PORT_BASE * random(NUM_FLOWS)
local DST_PORT      = 1234
local NUM_FLOWS     = 1000

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
  parser:description("Edit the source to modify constants like IPs and ports.")
  parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
  parser:option("-f --flows", "Number of flows per device."):args(1):convert(tonumber):default(1)
  parser:option("-r --rate", "Transmit rate in Mbit/s per device."):args(1)
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
  
  
end