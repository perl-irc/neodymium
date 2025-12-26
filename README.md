# Magnet IRC Network

A modern, geo-distributed IRC network infrastructure built for irc.perl.org with
anycast routing and automatic regional scaling.

## Overview

The Magnet IRC Network provides reliable, secure, and performant IRC services
across multiple geographic regions. Built using Solanum IRCd and Atheme services,
it leverages Fly.io's global anycast infrastructure for optimal client routing
and go-mmproxy for client IP preservation.

### Key Features

- **Anycast Routing**: Clients automatically connect to the nearest regional server
- **Client IP Preservation**: go-mmproxy unwraps PROXY protocol headers to maintain
  real client IPs for bans, geolocation, and logging
- **Dynamic Scaling**: Add new regions with a single command - no code changes needed
- **Hub-and-Spoke Topology**: Central hub with auto-connecting leaf servers
- **Modern Infrastructure**: Container-based deployment with health checks and monitoring

## Architecture

```
                         ┌─────────────────┐
                         │      Hub        │
                         │  (Coordinator)  │
                         │                 │
                         └────────┬────────┘
                                  │
            ┌─────────────────────┼─────────────────────┐
            │                     │                     │
            ▼                     ▼                     ▼
   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
   │   Leaf (ord)    │   │   Leaf (ams)    │   │    Services     │
   │   Chicago, US   │   │  Amsterdam, EU  │   │   (Atheme)      │
   │                 │   │                 │   │                 │
   └─────────────────┘   └─────────────────┘   └─────────────────┘
            ▲                     ▲
            │                     │
      ┌─────┴─────┐         ┌─────┴─────┐
      │  Clients  │         │  Clients  │
      │ (Anycast) │         │ (Anycast) │
      └───────────┘         └───────────┘
```

### Components

1. **Hub Server** - Central coordinator
   - Routes messages between all connected servers
   - Accepts connections from leaf servers and services
   - Single point of network coordination

2. **Leaf Servers (magnet-irc)** - Regional client-facing servers
   - Deployed via Fly.io anycast to multiple regions
   - Dynamic identity derived from `FLY_REGION` (e.g., ord → magnet-ord)
   - Auto-connect to hub via `autoconn` flag
   - go-mmproxy preserves real client IPs through PROXY protocol

3. **Services (magnet-atheme)** - IRC Services
   - NickServ, ChanServ, OperServ, MemoServ
   - Persistent data via opensex flat file backend
   - Connects directly to hub

### Client Connection Flow

```
Client → Fly.io Anycast → Nearest Leaf → go-mmproxy → Solanum
                                              │
                                    (preserves real IP)
```

1. Client connects to `irc.perl.org:6667` or `:6697` (SSL)
2. Fly.io routes to nearest regional leaf server
3. Fly.io edge adds PROXY protocol headers with real client IP
4. go-mmproxy unwraps headers and spoofs the client IP
5. Solanum receives connection with original client IP intact

## Deployment

**IMPORTANT**: All deployments must be run from the project root directory.

### Adding a New Region

To add a new region (e.g., Frankfurt):

```bash
# Scale to include the new region
flyctl scale count 3 --region ord,ams,fra -a magnet-irc

# Add connect block to hub config (servers/magnet-hub/server.conf)
# Then redeploy hub
flyctl deploy -a magnet-hub --config servers/magnet-hub/fly.toml
```

The leaf server will automatically:
- Derive its name from the region (fra → magnet-fra)
- Generate a valid SID (0FR)
- Connect to the hub via autoconn

### Current Regions

| Region | Location | Code |
|--------|----------|------|
| ord | Chicago, US | 0OR |
| ams | Amsterdam, EU | 0AM |

### Pre-configured Regions

These connect blocks exist on the hub - just scale to activate:

- sin (Singapore)
- syd (Sydney)
- gru (São Paulo)
- dfw (Dallas)
- iad (Virginia)
- lhr (London)
- fra (Frankfurt)

## Configuration

### Environment Variables

**Leaf Servers (magnet-irc):**
- `FLY_REGION` - Automatically set by Fly.io, used to derive identity
- `HUB_PASSWORD` - Password sent to hub
- `LEAF_PASSWORD` - Password accepted from hub
- `IRC_DOMAIN` - Domain suffix (default: `internal`)

**Hub Server:**
- `SERVER_NAME` - Explicit server name
- `SERVER_SID` - Three-character server ID
- `LEAF_PASSWORD` / `HUB_PASSWORD` - Shared secrets for leaf auth
- `SERVICES_PASSWORD` - Authentication for Atheme

### Configuration Files

```
servers/
├── magnet-hub/
│   ├── fly.toml          # Hub Fly.io config
│   └── server.conf       # Hub-specific IRC config
├── magnet-irc/
│   ├── fly.toml          # Leaf Fly.io config
│   └── server.conf       # Leaf template (uses env vars)
└── magnet-atheme/
    └── fly.toml          # Services Fly.io config

solanum/
├── common.conf.template  # Shared IRC settings
├── opers.conf.template   # Operator definitions
├── start.sh              # Startup script with env substitution
└── Dockerfile            # Solanum + go-mmproxy build

atheme/
├── atheme.conf.template  # Services configuration
├── entrypoint.sh         # Startup script
└── Dockerfile            # Atheme build
```

## Security

### Network Security

- **Fly.io Internal Network**: Server-to-server communication uses `.internal` DNS
  over Fly.io's encrypted private network
- **No Public S2S Ports**: Port 7000 (S2S) only accessible within Fly.io network
- **Client SSL/TLS**: Port 6697 for encrypted client connections

### Secrets Management

All sensitive values stored as Fly.io secrets:
```bash
flyctl secrets set HUB_PASSWORD=xxx LEAF_PASSWORD=xxx -a magnet-irc
flyctl secrets set SERVICES_PASSWORD=xxx -a magnet-atheme
```

### Client IP Preservation

go-mmproxy ensures real client IPs are visible to Solanum for:
- K-lines and bans
- Connection logging
- Geolocation
- Abuse prevention

## Operations

### Common Commands

```bash
# Check leaf server status
flyctl status -a magnet-irc

# View logs
flyctl logs -a magnet-irc

# SSH into a specific region
flyctl ssh console -a magnet-irc -r ord

# Check network links (from any server)
flyctl ssh console -a magnet-irc -C "sh -c 'printf \"LINKS\r\n\" | nc -w 2 127.0.0.1 16667'"

# Scale regions
flyctl scale count 4 --region ord,ams,fra,sin -a magnet-irc
```

### Health Checks

All components include health checks:
- TCP checks on IRC ports (6667, 6697)
- S2S port availability (7000)
- Process monitoring in start.sh

## Troubleshooting

### Leaf Not Linking to Hub

1. Check host matching - hub connect blocks must use wildcard:
   ```
   host = "*.vm.magnet-irc.internal";
   ```
   (Fly.io VMs have machine-ID-based reverse DNS, not region names)

2. Verify secrets match between hub and leaf

3. Check DNS resolution:
   ```bash
   flyctl ssh console -a magnet-irc -C "nslookup magnet-hub.internal"
   ```

### Client IP Shows as 127.0.0.1

go-mmproxy isn't running or routing rules aren't set. Check:
```bash
flyctl ssh console -a magnet-irc -C "ps -ef | grep mmproxy"
flyctl ssh console -a magnet-irc -C "ip rule list"
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Resources

- [Fly.io Documentation](https://fly.io/docs/)
- [Solanum IRCd](https://github.com/solanum-ircd/solanum)
- [Atheme Services](https://github.com/atheme/atheme)
- [go-mmproxy](https://github.com/path-network/go-mmproxy)
