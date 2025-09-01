# ddst-libp2p-test-node

A testing framework for running large-scale libp2p simulations using Kubernetes and Shadow simulator. This repository is based on [dst-gossipsub-test-node](https://github.com/vacp2p/dst-gossipsub-test-node/tree/dockerized) and provides tools for evaluating gossipsub performance at scale.

## Features
* DST libp2p test node 
* Include shadow simulation setup

## Kubernetes example

## Shadow example

```sh
nimble install -dy
cd shadow
# the default shadow.yml will start 5k nodes, you might want to change that by removing
# lines and setting PEERS to the number of instances
./run.sh
# the output is a "latencies" file, or you can find each host output in the
# data.shadow folder

# you can use the plotter tool to extract useful metrics & generate a graph
cd ../tools
nim -d:release c plotter
./plotter ../shadow/latencies "Clever graph name"
# will output averages, and generate a "test.svg" graph
```

The dependencies will be installed in the `nimbledeps` folder, which enables easy tweaking
