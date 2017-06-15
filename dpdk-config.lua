DPDKConfig {
  -- configure the CPU cores to use, default: all cores
  --cores = {0, 10, 11, 12, 13, 14, 15},
  cores = {4,5,6,7},
  
  -- max number of shared tasks running on core 0
  --sharedCores = 8,

  -- black or whitelist devices to limit which PCI devs are used by DPDK
  -- only one of the following examples can be used
  --pciBlacklist = {"0000:81:00.3","0000:81:00.1"},
  --pciWhitelist = {"0000:81:00.3","0000:81:00.1"},
  
  -- arbitrary DPDK command line options
  -- the following configuration allows multiple DPDK instances (use together with pciWhitelist)
  -- cf. http://dpdk.org/doc/guides/prog_guide/multi_proc_support.html#running-multiple-independent-dpdk-applications
  cli = {
    "--file-prefix", "m2",
  --  "--socket-mem", "512,512",
    "-m", "512"
  }

}