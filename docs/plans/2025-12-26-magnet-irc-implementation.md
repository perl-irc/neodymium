# magnet-irc Implementation Plan

## Overview

Create a new Fly.io app `magnet-irc` for anycast client-facing IRC leaf servers that link to the hub backbone.

## Prerequisites

- [x] Atheme uplink mismatch test passed
- [ ] All implementation tasks below

---

## Task 1: Create magnet-irc Fly App

Create the new app without deploying yet.

```bash
fly apps create magnet-irc --org magnet-irc
```

---

## Task 2: Create Leaf Server Configuration

Create `servers/magnet-irc/` directory with leaf-specific config.

### 2.1 Create server.conf for leaves

File: `servers/magnet-irc/server.conf`

Key differences from hub config:
- `serverinfo.name` uses `FLY_REGION` (set at runtime)
- Connect block links TO hub, not FROM other servers
- No connect blocks for other leaves (they don't mesh)

```
serverinfo {
    name = "${SERVER_NAME}.${IRC_DOMAIN}";
    sid = "${SERVER_SID}";
    description = "MagNET IRC - ${FLY_REGION}";
    ...
};

/* Link to hub */
connect "magnet-9rl.${IRC_DOMAIN}" {
    host = "magnet-9rl.${IRC_DOMAIN}";
    send_password = "${HUB_PASSWORD}";
    accept_password = "${LEAF_PASSWORD}";
    port = 7000;
    class = "server";
    flags = topicburst, autoconn;
};
```

### 2.2 Create fly.toml for magnet-irc

File: `servers/magnet-irc/fly.toml`

```toml
app = "magnet-irc"
primary_region = "ord"

[build]
  dockerfile = "../../solanum/Dockerfile"
  context = "../.."
  [build.args]
    SERVER_DIR = "servers/magnet-irc"

[env]
  # SERVER_NAME and SERVER_SID set dynamically in start.sh
  IRC_DOMAIN = "internal"
  TAILSCALE_DOMAIN = "camel-kanyu.ts.net"

[http_service]
  internal_port = 8080
  auto_stop_machines = true
  auto_start_machines = true

[[services]]
  internal_port = 6667
  protocol = "tcp"
  [[services.ports]]
    port = 6667
    handlers = ["proxy_proto"]

[[services]]
  internal_port = 6697
  protocol = "tcp"
  [[services.ports]]
    port = 6697
    handlers = ["proxy_proto"]

[[services]]
  internal_port = 7000
  protocol = "tcp"
  [[services.ports]]
    port = 7000
```

---

## Task 3: Modify start.sh for Dynamic Identity

Update `solanum/start.sh` to derive identity from `FLY_REGION`:

```bash
# Near the top of start.sh, after set -e
if [ -z "${SERVER_NAME}" ]; then
    # Derive from FLY_REGION for leaf servers
    REGION="${FLY_REGION:-local}"
    export SERVER_NAME="magnet-${REGION}"
    export SERVER_SID=$(echo "${REGION}" | tr '[:lower:]' '[:upper:]' | head -c 3)
fi
```

This allows:
- Hub servers to set SERVER_NAME explicitly in fly.toml
- Leaf servers to derive it from FLY_REGION automatically

---

## Task 4: Update Hub Connect Blocks

Add connect blocks to `servers/magnet-9rl/server.conf` for each supported leaf region.

Regions to add initially:
- `magnet-ord` (Chicago)
- `magnet-ams` (Amsterdam)

Future regions (pre-configure):
- `magnet-sin` (Singapore)
- `magnet-syd` (Sydney)
- `magnet-gru` (São Paulo)

Each connect block:
```
connect "magnet-ord.${IRC_DOMAIN}" {
    host = "magnet-ord.${IRC_DOMAIN}";
    send_password = "${LEAF_PASSWORD}";
    accept_password = "${HUB_PASSWORD}";
    port = 7000;
    class = "server";
    flags = topicburst;
};
```

---

## Task 5: Set Up Secrets

Set shared secrets on magnet-irc app:

```bash
fly secrets set -a magnet-irc \
  HUB_PASSWORD="..." \
  LEAF_PASSWORD="..." \
  PASSWORD_9RL="..." \
  PASSWORD_1EU="..." \
  OPERATOR_PASSWORD="..." \
  SERVICES_PASSWORD="..." \
  TAILSCALE_AUTHKEY="..."
```

Also add to magnet-9rl:
```bash
fly secrets set -a magnet-9rl \
  HUB_PASSWORD="..." \
  LEAF_PASSWORD="..."
```

---

## Task 6: Allocate Dedicated IPv4

```bash
fly ips allocate-v4 -a magnet-irc --yes
```

---

## Task 7: Initial Deployment

Deploy to ord and ams:

```bash
# Deploy to ord first
fly deploy -c servers/magnet-irc/fly.toml --region ord

# Scale to add ams
fly scale count 1 --region ams -a magnet-irc
```

Set minimum machines:
```bash
fly scale count --min 1 --region ord -a magnet-irc
fly scale count --min 1 --region ams -a magnet-irc
```

---

## Task 8: Verify Deployment

1. Check both leaves are running:
   ```bash
   fly status -a magnet-irc
   ```

2. Check leaves linked to hub:
   ```bash
   # Connect via anycast and check MAP
   nc <magnet-irc-ip> 6667
   MAP
   ```

3. Verify anycast routing:
   - Connect from US → should hit ord
   - Connect from EU → should hit ams

---

## Task 9: Retire magnet-1eu

Once magnet-irc is stable:

1. Remove magnet-1eu connect block from hub
2. Destroy magnet-1eu app:
   ```bash
   fly apps destroy magnet-1eu
   ```

---

## Task 10: Update Documentation

- Update README with new architecture
- Document how to add new regions
- Document scaling procedures

---

## Rollback Plan

If issues arise:
1. Scale magnet-irc to 0
2. Re-deploy magnet-1eu from git history
3. Update hub connect blocks back

---

## Success Criteria

- [ ] magnet-irc leaves in ord and ams
- [ ] Both linked to hub
- [ ] Anycast routing clients to nearest leaf
- [ ] Services (atheme) working through hub
- [ ] magnet-1eu retired
