

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
  parser:description("Edit the source to modify constants like IPs and ports.")
  parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
  parser:option("-t --threads", "Number of threads per device."):args(1):convert(tonumber):default(1)
  parser:option("-r --rate", "Transmit rate in Mbit/s per device."):args(1)
  parser:flag("-a --arp", "Use ARP.")
  return parser:parse()
end