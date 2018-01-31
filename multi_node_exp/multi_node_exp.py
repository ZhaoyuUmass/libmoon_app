#!/usr/bin/python

# This script is used to automatically generate configure files for multiple anolis nodes.
# used for anolis_v3: need to specify fifo_dir, 2 core mask, chain length

import argparse
import threading
import subprocess
import time
import json
import signal
import sys
import os

# some constant on agave202 only

# An interface example: 0000:41:02.0, where "0000:41:" is the prefix, "02" is the miidle
# Interface prefix
INTERFACE_PREFIX = '0000:41:'

# middles in the interface
INTERFACE_MIDDLES = ['02', '03', '04', '05',
           '0a', '0b', '0c', '0d']

# number of VFs per middle
NUM_VF_PER_MIDDLE = 8

# interface mac address: example: de:ad:be:02:02:00, ..., de:ad:be:02:03:1f
# MAC prefix
MAC_PREFIX = 'de:ad:be:02:'

#middles in MACs
MAC_MIDDLES = ['02', '03']

# number of MACs per middle
NUM_MAC_PER_MIDDLE = 32

# total number
TOTAL_INTERFACE = 64

# CPU MASK OFFSET
CPU_MASK_OFFSET = 5

# config FILE prefix
CONFIG_FILE_PREFIX = 'anolis_config_'

# config folder
CONFIG_HOME='/home/gaozy/multi-node/'

# switchboard folder
SWITCHBOARD_HOME='/home/gaozy/switchboard/'

# anolis binary
ANOLIS_BINARY=SWITCHBOARD_HOME+'src/anolis/build/anolis'


# MoonGen binary
MOONGEN_BINARY='/home/gaozy/build/MoonGen/build/MoonGen'

# MoonGen config home
MOONGEN_CONFIG_HOME='/home/gaozy/build/conf/'

# MoonGen config prefix
MOONGEN_CONFIG_PREFIX='dpdk-config-'

# MoonGen script
MOONGEN_SCRIPT='/home/gaozy/build/libmoon_app/multi_traffic_gen.lua'

# expect template
EXPECT_TEMPLATE='''
expect "password:"
send "qwer1234\r"
expect "gaozy:"
send "qwer1234\r"
interact
'''

# expect script prefix
EXPEXT_PREFIX='startMoonGen'

# this needs to return a 2 core mask: the 2 coers are on socket 0 and socket 1 respectively
# we need three cores because we want to shutdown the system gracefully. If we just use 2 cores, the system can not be shutdown gracefully.
def get_cpu_mask(index):
    return str( hex( int(2**(index*3+CPU_MASK_OFFSET)) + int(2**(index*3+CPU_MASK_OFFSET+1)) + int(2**(index*3+CPU_MASK_OFFSET+2)) ))

def get_mac_suffix(vf_index):
    suffix = None
    left = vf_index%NUM_MAC_PER_MIDDLE
    if left < 16:
	suffix = '0'+str(hex(left))[-1]
    else:
        suffix = str(hex(left))[-2:]
    return suffix

def get_mac(vf_index):
    return MAC_PREFIX+MAC_MIDDLES[int(vf_index/NUM_MAC_PER_MIDDLE)]+':'+get_mac_suffix(vf_index)

def get_interface(vf_index):
    return INTERFACE_PREFIX+INTERFACE_MIDDLES[int(vf_index/NUM_VF_PER_MIDDLE)]+'.'+str(vf_index%8)


class AnolisThread(threading.Thread):
    def __init__(self, id):
        super(AnolisThread, self).__init__()
        self._stop_event = threading.Event()
        self.id = id

    def run(self):
        cmd = 'sudo '+ANOLIS_BINARY+' -c '+CONFIG_HOME+CONFIG_FILE_PREFIX+str(self.id)+'.cfg'
        print cmd
        self.p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.p.communicate()

    def stop(self):
        if self.p is not None:
            self.p.kill()
        self._stop_event.set()

    def stopped(self):
        return self._stop_event.is_set()


def check_kill_process(pstring):
    for line in os.popen("ps ax | grep " + pstring + " | grep -v grep"):
        fields = line.split()
        pid = fields[0]
        os.kill(int(pid), signal.SIGKILL)

class MoonGenThread(threading.Thread):
    def __init__(self, id):
        threading.Thread.__init__(self)
        self._stop_event = threading.Event()
        self.id = id

    def run(self):
        expect_cmd = ['expect', EXPEXT_PREFIX+str(self.id)+".sh"]
        print expect_cmd

        self.p = subprocess.Popen(expect_cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.p.communicate()

    def stop(self):
        if self.p is not None:
            self.p.kill()
        self._stop_event.set()

    def stopped(self):
        return self._stop_event.is_set()

def main():
    parser = argparse.ArgumentParser(description='Execute command on a list of remote machines')
    # The list of remote servers
    parser.add_argument('num_servers',
                        help='The number of servers in the experiment')
    
    # The template to use
    parser.add_argument('-t', '--template', default='anolis_multi_node_template.cfg',
                        help='The local file used as a template')
    
    # The downstream
    parser.add_argument('-m', '--mac', default='de:ad:be:09:02:00',
                        help='The mac address of downstream, default is the 1st interface mac address on 209')

    # The length of the chain
    parser.add_argument('-l', '--length', default=1,
                        help='The length of the chain for chain replication, default is 1 which means there is no replication for flow state')
    
    # The number of flows
    parser.add_argument('-f', '--flow', default=1,
                        help='The number of flows tested in the experiment')

    args = parser.parse_args()

    num_servers = 0
    # num of server must be an integer
    try:
        num_servers = int(args.num_servers)
    except:
        print 'ERROR: the parameter number of servers must be an integer'
        sys.exit(0)

    config = None
    
    # Load the config template
    try:
        fin = open(args.template, 'r')
        json_data = fin.read()
        try:
            config = json.loads(json_data)
        except:
            print 'ERROR: bad json'
            sys.exit(0)
    except:
        print 'ERROR: config file not exists or it is a bad json'
        sys.exit(0)
        
    print "Ready to generate "+str(args.num_servers)+" configure files for "+str(args.num_servers)+" servers to be used in the experiment"

    # 1st step: set downstream
    config["downstream_mac"] = args.mac

    
    # 2nd step: decide the peers, i.e., the list of mac addresses of internal gateways
    peers = []
    for i in range(num_servers):
        index = TOTAL_INTERFACE-(i+1)
        peers.append(get_mac(index))
    print peers
    config["peers"] = peers
    
    # 3rd step: decide the internal and external gateway for each config file and output to files
    for i in range(num_servers):
        internal = TOTAL_INTERFACE - (i+1)
        external = i
        config["int_dev"] = get_interface(internal)
        config["ext_dev"] = get_interface(external)
        config["ext_gate"] = get_mac(external)
        config["cpu_mask"] = get_cpu_mask(i)
        config["lock_name"] = "anolis_"+str(i)
        # anolis_v3 config
        config["fifo_dir"] = "/tmp/anolis_"+str(i)
        config["chain_len"] = int(args.length)
        fout = open(CONFIG_FILE_PREFIX+str(i)+'.cfg', 'w+')
        fout.write(json.dumps(config, indent=4))
        fout.close()
        #print i, json.dumps(config, indent=4)

    print 'Finished generating config files!'

	# 4th step: start servers with the config files
	# commnad: sudo /home/gaozy/switchboard/src/anolis/build/anolis -c /home/gaozy/multi-node/anolis_config_6.cfg
    anolis_th_pool=[]
    for i in range(num_servers):
        t = AnolisThread(i)
        anolis_th_pool.append(t)
        t.start()

    # wait for a second
    time.sleep(1)
	
	# 5th step: start the downstream
    #print 'Please make sure pktgen has started. Ready to start the experiment?'
    #raw_input()

	# 6th step: start the traffic generator
    # command: sudo ./MoonGen/build/MoonGen libmoon_app/multi_traffic_gen.lua --dpdk-config=conf/dpdk-config-1.lua -m de:ad:be:02:02:00 -f 1048576 0
    moongen_th_pool=[]
    for i in range(num_servers):
        cmd = 'sudo ' + MOONGEN_BINARY + ' ' + MOONGEN_SCRIPT + ' --dpdk-config=' \
              + MOONGEN_CONFIG_HOME + MOONGEN_CONFIG_PREFIX + str(i+1) + '.lua' \
              + ' -m ' + str(get_mac(i)) + ' -f ' + str(args.flow) + ' 0'
        print cmd
        # write up expect script and run
        expect_command = 'spawn ssh -t gaozy@agave209.research.att.com \"' + cmd + '\"'
        fname = EXPEXT_PREFIX+str(i)+'.sh'
        fout = open(fname, 'w+')
        fout.write('#!/usr/bin/expect -f\n')
        fout.write(expect_command+'\n')
        fout.write(EXPECT_TEMPLATE)
        fout.close()
        os.chmod(fname, 0777)

    '''
    for i in range(num_servers):
        t = MoonGenThread(i)
        moongen_th_pool.append(t)
        t.start()

    # 30 second experiment
    time.sleep(20)

    # stop moongen first
    print 'Stop MoonGen'
    check_kill_process(EXPEXT_PREFIX)

    for t in moongen_th_pool:
        t.join()
    '''

    print 'Please make sure pktgen has started. Ready to start the experiment?'
    raw_input()
    print 'Start your MoonGen...'
    raw_input()
    print 'Record the number...'
    raw_input()

    # stop anolis
    print 'All anolis threads have been stopped!'
    check_kill_process("anolis")

    for t in anolis_th_pool:
        t.join()

    print "All anolis threads have been joined!"

if __name__ == '__main__':
    #main()
    print get_mac(int(sys.argv[1]))
