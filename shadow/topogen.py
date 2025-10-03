import math
import argparse
import networkx as nx
import yaml

#Configurable in test node, message injector, but fixed here
shadow_env = 1 
connections = 10
gml_file = "network_topology.gml"
yaml_file = "shadow.yaml"


def parse_arguments():
    parser = argparse.ArgumentParser(description="Generate network topology and yaml for shadow")
    parser.add_argument('-n', '--network-size', type=int, help='Number of peers in the network', default=100)
    parser.add_argument('-bl', '--min-bandwidth', type=int, help='Minimum bandwidth in Mbps', default=50)
    parser.add_argument('-bh', '--max-bandwidth', type=int, help='Maximum bandwidth in Mbps', default=50)
    parser.add_argument('-ll', '--min-latency', type=int, help='Minimum latency in ms', default=100)
    parser.add_argument('-lh', '--max-latency', type=int, help='Maximum latency in ms', default=100)
    parser.add_argument('-st', '--anchor-stages', type=int, help='Number of bandwidth/latency variations', default=1)
    parser.add_argument('-l', '--packet-loss', type=float, help='Packet loss rate (0-1)', default=0.0)
    parser.add_argument('-s', '--msg-size-bytes', type=int, help='Message size in bytes', default=1500)
    parser.add_argument('-f', '--num-frags', type=int, choices=range(1, 10), help='Number of fragments per message (1-10)', default=1)
    parser.add_argument('-m', '--messages', type=int, help='Number of messages to publish', default=10)
    parser.add_argument('-d', '--delay-seconds', type=float, help='Inter-message delay in seconds', default=0.1)
    parser.add_argument('-mx', '--muxer', type=str, choices=['mplex', 'yamux', 'quic'], help='Muxer selection', default='yamux')
    
    args = parser.parse_args()
    
    # Validate arguments
    if args.min_bandwidth > args.max_bandwidth:
        parser.error("min_bandwidth cannot exceed max_bandwidth")
    if args.min_latency > args.max_latency:
        parser.error("min_latency cannot exceed max_latency")
    
    return args


def create_network_topology(steps, min_bandwidth, max_bandwidth, 
                            min_latency, max_latency, packet_loss):

    G = nx.complete_graph(steps)

    bandwidth_jump = int((max_bandwidth - min_bandwidth) / steps)
    latency_jump = int((max_latency - min_latency) / steps)
    
    # Configure nodes and edges
    for i in range(steps):
        node_bw = f"{math.ceil(i * bandwidth_jump + min_bandwidth)} Mbit"
        G.nodes[i]["host_bandwidth_up"] = node_bw
        G.nodes[i]["host_bandwidth_down"] = node_bw
        
        # Self-loop for intra-node communication
        G.add_edge(i, i)
        G.edges[i, i]["latency"] = f"{max((steps - i) * latency_jump, min_latency)} ms"
        G.edges[i, i]["packet_loss"] = packet_loss
        
        # Edges to other nodes
        for j in range(i + 1, steps):
            edge_latency = min(math.ceil((steps - j) * latency_jump + min_latency), max_latency)
            G.edges[i, j]["latency"] = f"{edge_latency} ms"
            G.edges[i, j]["packet_loss"] = packet_loss
    
    # Add fast node for message injector
    G.add_node(steps, host_bandwidth_up="100 Mbit", host_bandwidth_down="100 Mbit")
    for i in range(steps + 1):
        G.add_edge(i, steps)
        G.edges[i, steps]["latency"] = "1 ms"
        G.edges[i, steps]["packet_loss"] = 0.0
    
    nx.write_gml(G, gml_file)


def create_shadow_config(steps, network_size, num_publishers, num_frags, 
                        message_size, message_delay, muxer):
    
    #simulation details
    config = {
        'general': {
            'bootstrap_end_time': '10s',
            'heartbeat_interval': '12s',
            'stop_time': '15m',
            'progress': True
        },
        'experimental': {
            'use_memory_manager': False
        },
        'network': {
            'graph': {
                'type': 'gml',
                'file': {
                    'path': gml_file
                }
            }
        },
        'hosts': {}
    }
    
    # Peer settings (for each stage)
    host_templates = {}
    for i in range(steps):
        host_config = {
            'network_node_id': i,
            'processes': [{
                'path': './main',
                'start_time': '5s',
                'environment': {
                    'PEERS': str(network_size),
                    'SHADOWENV': str(shadow_env),
                    'CONNECTTO': str(connections),
                    'PUBLISHERS': str(num_publishers),
                    'FRAGMENTS': str(num_frags),
                    'MUXER': muxer
                }
            }]
        }
        host_templates[i] = host_config
        config['hosts'][f'pod-{i}'] = host_config
    
    # Distribute peers in all stages
    for i in range(steps, network_size):
        config['hosts'][f'pod-{i}'] = host_templates[i % steps]
    
    # Add publish controller
    controller_config = {
        'network_node_id': steps,
        'processes': [{
            'path': '/usr/bin/python',
            'args': f'../../../traffic_sync.py -s {message_size} -m {num_publishers} -d {message_delay} -n {network_size} --peer-selection id',
            'start_time': '500s',
            'environment': {
                'SHADOWENV': str(shadow_env)
            }
        }]
    }
    config['hosts'][f'pod-{network_size}'] = controller_config

    with open(yaml_file, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)


def main():
    args = parse_arguments()
    
    # generate network topology
    create_network_topology(
        args.anchor_stages,
        args.min_bandwidth,
        args.max_bandwidth,
        args.min_latency,
        args.max_latency,
        args.packet_loss
        )       
    
    # generate shadow configuration
    create_shadow_config(
        args.anchor_stages,
        args.network_size,
        args.messages,
        args.num_frags,
        args.msg_size_bytes,
        args.delay_seconds,
        args.muxer
        )
    
if __name__ == "__main__":
    main()