#!/bin/sh
set -e

if [ $# -ne 14 ]; then
    echo "Usage: $0 <runs> <nodes> <message_size> <num_fragment> <num_publishers>
            <min_bandwidth> <max_bandwidth> <min_latency> <max_latency> <anchor_stages> 
            <packet_loss> <publisher_id> <publisher_rotation> <inter_message_delay>"
    
    echo "The following sample command runs simulation 1 time, for a 1000 node network. Each published message size \
            is 15KB single-message (no-fragmentation). A total of 10 messages are transmitted in the network. \
            Peer bandwidth varies between 50-150 Mbps, Latency between 40-130ms, and bandwidth/latency is roughly \
            distributed in five different groups. No packet loss is introduced on edges. Peer 4 publishes all messages \
            with 4000 ms inter-packet delay. see the generated network_topology.gml and shadow.yaml for peers/edges details. \
            See Readme.md for details about simulation parameters"   
    
    echo "publisher_id is the peer that starts publishing messages. If publisher_rotation=1, subsequent message is \ 
            transmitted by the next peer (Note: In shadow peers start from peer # 1)"
    echo "inter-message delay is time between messages (in milliseconds). Must be greater than 1"
    echo "$0 1 1000 15000 1 10 50 150 40 130 5 0.0 4 0 4000" 
    exit 1
fi

runs="$1"			    #number of simulation runs
nodes="$2"			    #number of nodes to simulate
msg_size="$3"			#message size to use (in bytes)
num_frag="$4"			#number of fragments per message (1 for no fragmentation)
num_publishers="$5"		#number of messages to transmit 
min_bandwidth="$6"		#In Mbps
max_bandwidth="$7"		#In Mbps
min_latency="$8"		#In milliseconds
max_latency="$9"		#In milliseconds
steps="${10}"			#Number of variation steps between min/max latency and bandwidth in the network
pkt_loss="${11}"		#%age packet loss (not yet tested)
publisher_id="${12}"	#this peer sends first message. If publisher_rotation=0, this peer publishes all messages
publisher_rotation="${13}"	#If 1, every subsequent message is transmitted by the next peer
message_delay="${14}"	#wait time (milliconds) before publishing the next message

connect_to=10			#number of peers we connect with to form full message mesh


#topogen.py uses networkx module from python to generate gml and yaml files
PYTHON=$(which python3 || which python)

if [ -z "$PYTHON" ]; then
    echo "Error: Python, Networkx is required for topology files generation."
    exit 1
fi

"$PYTHON" topogen.py $nodes $min_bandwidth $max_bandwidth $min_latency $max_latency \
        $steps $pkt_loss $msg_size $num_frag $num_publishers $publisher_id $publisher_rotation $message_delay



rm -f shadowlog* latencies* stats* && rm -rf shadow.data/
#nim c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:release main
#nim c --threads:on -d:release main

for i in $(seq $runs); do
    echo "Running for turn "$i
    shadow shadow.yaml > shadowlog$i && 
        grep -rne 'milliseconds\|BW' shadow.data/ > latencies$i 
    #uncomment to to receive every nodes log in shadow data (only if runs == 1, or change data directory in yaml file)
    #rm -rf shadow.data/
done

for i in $(seq $runs); do
    echo "Summary for turn "$i
    if [ "$msg_size" -lt 1000 ]; then
    	awk -f summary_latency.awk latencies$i		#precise per hop coverage for short messages only
    else
	awk -f summary_latency_large.awk latencies$i	#estimated coverage for large messages (TxTime adds to latency)
    fi
    awk -f summary_shadowlog.awk shadowlog$i
done
