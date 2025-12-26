# Geo-Distributed IRC Network Architecture

## Overview

This design describes a geo-distributed IRC network on Fly.io with anycast routing for clients and a stable hub backbone for server-to-server linking.

## Goals

- **Lower latency**: Route clients to geographically nearest server
- **Redundancy**: Automatic failover if a region goes down
- **Cost optimization**: Scale down in quiet regions, scale up where demand exists

## Architecture

```
                 Backbone (separate apps, private)
        ┌────────────────────────────────────────────┐
        │                                            │
        │  ┌─────────────┐       ┌───────────────┐  │
        │  │ magnet-9rl  │◄──────│ magnet-atheme │  │
        │  │ (hub app)   │       │ (services)    │  │
        │  │             │       │               │  │
        │  │ Region: ord │       │ failover via  │  │
        │  │             │       │ .internal DNS │  │
        │  └──────┬──────┘       └───────────────┘  │
        │         │                                 │
        └─────────┼─────────────────────────────────┘
                  │
          .internal links
                  │
         ┌────────┴────────┬─────────────────┐
         ▼                 ▼                 ▼
┌──────────────────────────────────────────────────────┐
│                    magnet-irc                        │
│              (leaf app, public, anycast)             │
│                                                      │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│   │ leaf-ord │    │ leaf-ams │    │ leaf-sin │ ...  │
│   │ SID: 0OR │    │ SID: 0AM │    │ SID: 0SI │      │
│   └────▲─────┘    └────▲─────┘    └────▲─────┘      │
└────────┼───────────────┼───────────────┼─────────────┘
         │               │               │
    ─────┴───anycast─────┴───────────────┴─────
                         │
                      Clients
```

## App Responsibilities

| App | Purpose | Scaling | Identity |
|-----|---------|---------|----------|
| `magnet-9rl` | Hub server | Manual, region-based SID | Fixed per instance |
| `magnet-atheme` | IRC Services | Single instance | Fixed |
| `magnet-irc` | Client-facing leaves | Auto, multi-region | Dynamic per region |

## Scaling Behavior

| Region | Min Machines | Behavior |
|--------|--------------|----------|
| ord | 1 | Always on |
| ams | 1 | Always on |
| others | 0 | Scale up on demand, scale down when idle |

## Dynamic Identity (magnet-irc leaves)

Each leaf derives its identity from `FLY_REGION` at startup:

```sh
REGION="${FLY_REGION:-local}"
REGION_UPPER=$(echo "$REGION" | tr '[:lower:]' '[:upper:]')

export SERVER_NAME="magnet-${REGION}"
export SERVER_SID="${REGION_UPPER}"
export IRC_DOMAIN="internal"
```

## Hub Connect Blocks

Hub pre-configures connect blocks for all supported regions. The `host` field uses a wildcard
to match Fly.io's machine-ID-based reverse DNS (e.g., `48e3102b7e0118.vm.magnet-irc.internal`):

```
connect "magnet-ord.${IRC_DOMAIN}" {
    host = "*.vm.magnet-irc.internal";
    send_password = "${LEAF_PASSWORD}";
    accept_password = "${HUB_PASSWORD}";
    port = 7000;
    class = "server";
    flags = topicburst;
};
```

Unused regions are harmless - no leaf means no connection.

## Atheme Failover

Atheme connects to `magnet-9rl.internal`. With multiple hub instances:
- Fly's internal DNS returns all healthy hub IPs
- Atheme connects to one
- On disconnect, reconnects to `.internal` (gets a healthy hub)
- No config change needed when adding hubs

**Assumption to test**: Atheme handles connecting to a server whose name differs from the uplink hostname.

## Prerequisites Verified

1. **Atheme uplink hostname mismatch test** - PASSED (2025-12-26)
   - Changed hub's serverinfo.name from `magnet-9rl` to `magnet-test`
   - Atheme connected to `magnet-9rl.internal`, server identified as `magnet-test.internal`
   - Atheme logged: `handle_server(): uplink magnet-9rl.internal actually has name magnet-test.internal, continuing anyway`
   - Synced successfully in 2ms
   - **Conclusion:** Multi-hub failover via `.internal` DNS will work without config changes

## Migration Status (Completed)

### Final State
- magnet-9rl (hub, ord) - no public IP needed, internal only
- magnet-irc (leaves, ord + ams) - anycast with dedicated IPv4
- magnet-atheme (services, ord) - connects directly to hub

### Completed Steps

1. ✅ Tested atheme uplink hostname mismatch behavior
2. ✅ Updated magnet-9rl: added connect blocks with wildcard host matching
3. ✅ Created magnet-irc app with dynamic identity from FLY_REGION
4. ✅ Deployed to ord + ams
5. ✅ Allocated dedicated IPv4 for anycast
6. ✅ Verified leaves link to hub via autoconn
7. ✅ Retired magnet-1eu
8. ✅ Released hub's public IP (internal-only traffic)

### Pre-configured Regions

Ready to activate with `flyctl scale count`:
- sin (Singapore)
- syd (Sydney)
- gru (São Paulo)
- sea (Seattle)
- lhr (London)
- iad (Virginia)
