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
        │  │ Start: ord  │       │ failover via  │  │
        │  │ Later: +ams │       │ .internal DNS │  │
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
│            (NEW app, public, anycast)                │
│                                                      │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│   │ leaf-ord │    │ leaf-ams │    │ leaf-sin │ ...  │
│   │ SID: ORD │    │ SID: AMS │    │ SID: SIN │      │
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

Hub pre-configures connect blocks for all supported regions:

```
connect "magnet-ord.${IRC_DOMAIN}" {
    host = "magnet-ord.${IRC_DOMAIN}";
    send_password = "${HUB_PASSWORD}";
    accept_password = "${LEAF_PASSWORD}";
    port = 7000;
    class = "server";
    flags = topicburst;
};

connect "magnet-ams.${IRC_DOMAIN}" {
    host = "magnet-ams.${IRC_DOMAIN}";
    ...
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

## Prerequisites to Verify

1. **Atheme uplink hostname mismatch test**
   - Change hub's serverinfo.name temporarily
   - Verify atheme still connects and syncs
   - If fails, need explicit uplink per hub

## Migration Path

### Current State
- magnet-9rl (hub, ord)
- magnet-1eu (leaf, ams)
- magnet-atheme (services, ord)

### Target State
- magnet-9rl (hub, ord) - add leaf connect blocks
- magnet-irc (leaves, multi-region) - NEW, absorbs magnet-1eu
- magnet-atheme (services, ord) - unchanged

### Steps

1. Test atheme uplink mismatch behavior
2. Update magnet-9rl: add connect blocks for `magnet-ord`, `magnet-ams`, etc.
3. Create magnet-irc app with dynamic identity startup
4. Deploy to ord + ams with min 1 each
5. Allocate dedicated IPv4 for anycast
6. Verify leaves link to hub, clients connect via anycast
7. Retire magnet-1eu once magnet-irc (ams) is stable

## Open Questions

- Which additional regions to pre-configure? (sin, syd, gru, etc.)
- Cold start latency acceptable for scale-to-zero regions?
- Need health check endpoint on leaves for Fly.io?
