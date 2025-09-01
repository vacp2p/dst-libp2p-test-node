## dst-libp2p-test-node for shadow simulator
This directory contains necessary files for running the dst-libp2p-test-nod using the [shadow simulator](https://github.com/shadow/shadow). This can either be done by compiling the `main.nim` file directly or by extracting the executable from a Docker image. Currently we support nim-libp2p only. Support for other implementations will be added soon. This directory includes utilities for:
* Creating a `shadow.yaml` file for describing the network topology.
* Running the shadow simulation with configurable parameters.
* Listing latency and bandwidth utilization.
* Collecting Prometheus metrics from simulated nodes 

### Getting the Executable Test Node
You have two options for obtaining the `main` executable:

#### Option 1: Extract from Docker Image (Recommended)
Extract the pre-built executable from the Docker image without building it locally.

```bash
# Pull the Docker image
docker pull <docker_image>

# Create a temporary container from the image
docker create --name temp-container <docker_image>

# Copy the 'main' binary from the container to this directory
docker cp temp-container:/node/main ./main

# Make it executable
chmod +x ./main

# Remove the temporary container
docker rm temp-container
```

#### Option 2: Build from Source
Build the `main` executable directly from the source.

```bash
#Navigate to the parent directory
cd ../

#Compile with required flags
nim c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:release main

#Move the executable to the shadow directory
mv ./main shadow/
```

### Running Simulations
Use the `run.sh` script to create and run simulations with custo parameters

#### Example

```bash
#usage parameters
./run.sh <runs> <nodes> <Message_size> <num_fragment> <num_publishers>
        <min_bandwidth> <max_bandwidth> <min_latency> <max_latency>
        <anchor_stages> <packet_loss> <publisher_id> <publisher_rotation> <inter_message_delay>

#example
./run.sh 1 2000 15000 1 10 50 150 40 130 5 0.0 6 1 1000

#This will output latency/bandwidth and store prometheus metrics (and peer data) in shadow.data directory
```

#### Parameters
| Parameter | Description | Example Value |
|-----------|-------------|---------------|
| `runs` | Number of times to run a simulation | 1 |
| `nodes` | Total number of nodes in the network | 2000 |
| `message_size` | Message size in bytes | 15000 |
| `num_fragments` | Number of message fragments (1-10). 1 means not fragmented | 1 |
| `num_publishers` | Number of messages to publish | 10 |
| `min_bandwidth` | Minimum peer bandwidth in Mbps | 50 |
| `max_bandwidth` | Maximum peer bandwidth in Mbps | 150 |
| `min_latency` | Minimum link latency in ms | 40 |
| `max_latency` | Maximum link latency in ms | 130 |
| `anchor_stages` | Bandwidth/latency variations | 5 |
| `packet_loss` | Packet loss rate (0.0-1.0) | 0.0 |
| `publisher_id` | Starting publisher node ID | 6 |
| `publisher_rotation` | Rotate publishers (0=no, 1=yes) | 1 |
| `inter_message_delay` | Delay between messages in ms | 1000 |


### Supported Implementation
✅ = Available
🚧 = In progress

| Name                         | Node | Latest tested version |
|------------------------------|:----:|:---------------------:|
| nim-libp2p                   |  ✅  |  v1.12.0              |
| go-libp2p                    |  🚧  |  -                    |
| rust-libp2p                  |  🚧  |  -                    |

