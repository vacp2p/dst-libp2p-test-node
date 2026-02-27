## How to run

Compile and run `main.nim`.

### For running bootstrap

Env variables:
```bash
NODE_ROLE=RoleBootstrap PORT=5001 main
```

### For running nodes

Env variables for node 1, if you want to use more nodes, remember to increase `PORT` on the other executions:
```bash
NODE_ROLE=RoleNormal \
PORT=5002 \
SERVICE=127.0.0.1:5001 \
BOOTSTRAP_ADDR=/ip4/127.0.0.1/tcp/5001 \
BOOTSTRAP_PEER_ID=<BOOTSTRAP_PEER_ID> main
```
