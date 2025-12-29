# CI-Based SSL Certificate Management

## Problem

The current Let's Encrypt setup runs certbot at container startup using HTTP-01 validation. This creates issues with multiple machines:

1. **ACME challenge routing**: HTTP-01 validation requires serving a challenge file from the domain's IP. With multiple machines behind anycast, requests may hit different machines than the one that created the challenge file.

2. **Manual intervention required**: Currently must scale to 1 machine before cert renewal, then scale back up.

3. **90-day renewal cycle**: Let's Encrypt certs expire every 90 days, making manual scaling unsustainable.

## Current State

- `solanum/start.sh` runs certbot at container startup
- Certs stored in `/etc/letsencrypt/` (ephemeral container filesystem)
- Symlinks created at `/opt/solanum/etc/ssl.pem` and `ssl.key`
- Works with 1 machine; breaks with multiple machines during ACME validation
- nginx on port 8080 serves `/.well-known/acme-challenge/`

## Proposed Solution

Decouple certificate acquisition from the IRC infrastructure:

1. **Ephemeral certbot machine**: GitHub Actions spins up a temporary Fly machine dedicated to running certbot
2. **Secrets-based cert storage**: Certs stored as Fly secrets, accessible to all machines
3. **Scheduled renewal**: GitHub Actions cron triggers renewal every 60 days
4. **No certbot in IRC containers**: magnet-irc reads certs from secrets, never runs certbot

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    GitHub Actions                            │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  cert-renewal.yml (scheduled every 60 days)         │    │
│  │                                                      │    │
│  │  1. Create temp Fly machine (magnet-certbot)        │    │
│  │  2. Run certbot standalone                          │    │
│  │  3. Extract certs via fly sftp                      │    │
│  │  4. Store as Fly secrets on magnet-irc              │    │
│  │  5. Destroy temp machine                            │    │
│  │  6. Rolling restart magnet-irc                      │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     Fly.io Secrets                           │
│  SSL_CERT_PEM = "-----BEGIN CERTIFICATE-----..."            │
│  SSL_KEY_PEM  = "-----BEGIN PRIVATE KEY-----..."            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                magnet-irc (multiple machines)                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   ord (1)    │  │   ord (2)    │  │   ams (1)    │       │
│  │              │  │              │  │              │       │
│  │ start.sh:    │  │ start.sh:    │  │ start.sh:    │       │
│  │ - Read from  │  │ - Read from  │  │ - Read from  │       │
│  │   secrets    │  │   secrets    │  │   secrets    │       │
│  │ - Write to   │  │ - Write to   │  │ - Write to   │       │
│  │   ssl.pem    │  │   ssl.pem    │  │   ssl.pem    │       │
│  │ - No certbot │  │ - No certbot │  │ - No certbot │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

### Temporary Certbot Machine

A minimal Fly app (`magnet-certbot`) used only for cert acquisition:

- Single machine, single region
- Runs certbot in standalone mode (serves its own HTTP on port 80)
- DNS for kowloon.social/magnet-irc.fly.dev points here temporarily OR
- Uses the existing magnet-irc app's HTTP service (port 8080) with webroot mode
- Destroyed after cert acquisition

**Option A: Standalone mode (simpler)**
- Temp machine binds port 80
- Requires DNS/Fly routing to send ACME traffic to this machine
- Complex because kowloon.social points to magnet-irc

**Option B: Use existing infrastructure (recommended)**
- Scale magnet-irc to 1 machine temporarily in CI
- Run certbot via `fly ssh console`
- Extract certs, store as secrets
- Scale back up

Wait - Option B still requires scaling to 1. Let me reconsider.

**Option C: Dedicated certbot app with its own IP**
- Create `magnet-certbot` Fly app with dedicated IPv4
- Add DNS record: `_acme.kowloon.social` -> certbot app IP (not needed for HTTP-01)
- Actually, HTTP-01 validates against the actual domain, not a subdomain

**Option D: Certbot in CI with DNS-01 (if DNS access available later)**
- When permanent domain with DNS API access is available
- Cleanest solution, no HTTP routing issues

### Recommended Approach: Option B with Automation

Since scaling to 1 machine is currently necessary anyway, automate it fully:

1. CI workflow handles the entire process automatically
2. Scale down, get cert, store secret, scale up
3. Human never needs to intervene
4. Downtime is minimal (seconds during scale operations)

This is pragmatic for a temporary domain. When a permanent domain with DNS API access is available, switch to DNS-01.

## Implementation Plan

### Phase 1: Secrets-based cert loading in start.sh

Modify `solanum/start.sh` to check for cert secrets before running certbot:

```sh
# Check if certs are provided via secrets
if [ -n "${SSL_CERT_PEM}" ] && [ -n "${SSL_KEY_PEM}" ]; then
    echo "Using SSL certificates from secrets..."
    echo "${SSL_CERT_PEM}" > "$SSL_CERT"
    echo "${SSL_KEY_PEM}" > "$SSL_KEY"
else
    # Existing certbot logic
    ...
fi
```

**Files to modify:**
- `solanum/start.sh` - Add secrets-based cert loading

### Phase 2: Manual cert extraction and secret storage

Create a script to extract certs from a running machine and store as secrets:

```sh
#!/bin/sh
# scripts/extract-and-store-certs.sh

# Extract certs from running machine
flyctl ssh console -a magnet-irc -C "cat /opt/solanum/etc/ssl.pem" > /tmp/ssl.pem
flyctl ssh console -a magnet-irc -C "cat /opt/solanum/etc/ssl.key" > /tmp/ssl.key

# Store as secrets
flyctl secrets set -a magnet-irc \
    SSL_CERT_PEM="$(cat /tmp/ssl.pem)" \
    SSL_KEY_PEM="$(cat /tmp/ssl.key)"

# Cleanup
rm /tmp/ssl.pem /tmp/ssl.key
```

**Files to create:**
- `scripts/extract-and-store-certs.sh`

### Phase 3: Automated renewal workflow

Create GitHub Actions workflow for scheduled renewal:

```yaml
# .github/workflows/cert-renewal.yml
name: SSL Certificate Renewal

on:
  schedule:
    - cron: '0 0 1 */2 *'  # 1st of every 2nd month
  workflow_dispatch:  # Manual trigger

jobs:
  renew:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Scale to 1 machine
        run: flyctl scale count 1 -a magnet-irc --yes
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}

      - name: Wait for scale down
        run: sleep 30

      - name: Trigger cert renewal
        run: |
          flyctl ssh console -a magnet-irc -C "certbot renew --force-renewal"
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}

      - name: Extract and store certs
        run: |
          flyctl ssh console -a magnet-irc -C "cat /opt/solanum/etc/ssl.pem" > /tmp/ssl.pem
          flyctl ssh console -a magnet-irc -C "cat /opt/solanum/etc/ssl.key" > /tmp/ssl.key
          flyctl secrets set -a magnet-irc \
            SSL_CERT_PEM="$(cat /tmp/ssl.pem)" \
            SSL_KEY_PEM="$(cat /tmp/ssl.key)"
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}

      - name: Scale back up
        run: flyctl scale count 2 -a magnet-irc --yes
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

**Files to create:**
- `.github/workflows/cert-renewal.yml`

### Phase 4: Initial secret population

One-time manual step to populate secrets from current certs:

```sh
# Run locally or in CI after current deploy
./scripts/extract-and-store-certs.sh
```

### Phase 5: Remove certbot from startup (optional)

Once secrets are reliable, optionally remove certbot logic from `start.sh` entirely. This simplifies the container but removes the fallback.

**Recommendation**: Keep certbot as fallback for now. If secrets are missing, certbot runs. This provides resilience.

## Rollback Plan

If issues occur:

1. **Secrets corrupted**: Delete secrets, redeploy with 1 machine to trigger certbot
2. **Renewal fails**: Manual intervention via `fly ssh console` to run certbot
3. **Complete failure**: Revert to self-signed certs (already implemented as fallback)

## Future Improvements

When permanent domain with DNS API access is available:

1. Switch to DNS-01 validation
2. No scaling required
3. Can add `certbot-dns-cloudflare` or similar to Dockerfile
4. Renewal works regardless of machine count

## Testing

1. Set dummy secrets, verify start.sh uses them
2. Run extraction script, verify secrets stored correctly
3. Manually trigger renewal workflow
4. Verify SSL works after full cycle
