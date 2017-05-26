local lm     = require "libmoon"
local device = require "device"
local log    = require "log"

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
  parser:description("Edit the source to modify constants like IPs and ports.")
  parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
  parser:option("-f --flows", "Number of flows per device."):args(1):convert(tonumber):default(1)
  parser:option("-r --rate", "Transmit rate in Mbit/s per device."):args(1)
  parser:flag("-a --arp", "Use ARP.")
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
      rxQueues = 1,
      rate = rate
    }
    args.dev[i] = dev
  end
  device.waitForLinks()
end