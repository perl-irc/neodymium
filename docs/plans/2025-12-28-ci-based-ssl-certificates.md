# CI-Based SSL Certificate Management

## Problem

The current Let's Encrypt setup runs certbot at container startup using HTTP-01 validation. This creates issues with multiple machines:

1. **ACME challenge routing**: HTTP-01 validation requires serving a challenge file from the domain's IP. With multiple machines behind anycast, requests may hit different machines than the one that created the challenge file.

2. **90-day renewal cycle**: Let's Encrypt certs expire every 90 days.

**Constraint**: Scaling to 1 machine is not acceptable - this defeats the purpose of multi-machine redundancy.

## Current State

- `solanum/start.sh` runs certbot at container startup
- Certs stored in `/etc/letsencrypt/` (ephemeral container filesystem)
- Symlinks created at `/opt/solanum/etc/ssl.pem` and `ssl.key`
- Works with 1 machine; breaks with multiple machines during ACME validation
- nginx on port 8080 serves `/.well-known/acme-challenge/` from local `/var/www/`

## Proposed Solution: Shared Storage with Tigris

Use Fly.io's Tigris (S3-compatible object storage) to share ACME challenges and certificates across all machines.

### How It Works

1. **Shared ACME challenges**: All machines serve challenges from Tigris, so any machine can respond to Let's Encrypt validation
2. **Shared certificate storage**: Certs stored in Tigris, all machines download on startup
3. **Single certbot coordinator**: Only one machine runs certbot (using distributed locking or leader election)
4. **Scheduled renewal**: GitHub Actions triggers renewal; any machine can handle it

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Tigris (S3)                          │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  magnet-certs bucket                                 │    │
│  │                                                      │    │
│  │  /acme-challenge/         (challenge tokens)        │    │
│  │  /certs/ssl.pem           (certificate chain)       │    │
│  │  /certs/ssl.key           (private key)             │    │
│  │  /certs/lock              (renewal lock file)       │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
           ▲                              │
           │ upload challenges            │ download certs
           │ upload certs                 ▼
┌─────────────────────────────────────────────────────────────┐
│                magnet-irc (multiple machines)                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   ord (1)    │  │   ord (2)    │  │   ams (1)    │       │
│  │              │  │              │  │              │       │
│  │ nginx:       │  │ nginx:       │  │ nginx:       │       │
│  │ - Proxy      │  │ - Proxy      │  │ - Proxy      │       │
│  │   challenges │  │   challenges │  │   challenges │       │
│  │   to Tigris  │  │   to Tigris  │  │   to Tigris  │       │
│  │              │  │              │  │              │       │
│  │ start.sh:    │  │ start.sh:    │  │ start.sh:    │       │
│  │ - Download   │  │ - Download   │  │ - Download   │       │
│  │   certs from │  │   certs from │  │   certs from │       │
│  │   Tigris     │  │   Tigris     │  │   Tigris     │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
└─────────────────────────────────────────────────────────────┘
           ▲
           │ ACME validation request
           │ (hits any machine)
┌─────────────────────────────────────────────────────────────┐
│                    Let's Encrypt                             │
└─────────────────────────────────────────────────────────────┘
```

### ACME Challenge Flow

1. Certbot runs on one machine, creates challenge token
2. Certbot's auth hook uploads token to `s3://magnet-certs/acme-challenge/{token}`
3. Let's Encrypt sends HTTP request to `http://kowloon.social/.well-known/acme-challenge/{token}`
4. Request hits any machine; nginx proxies to Tigris
5. Tigris returns challenge token
6. Let's Encrypt validates, issues certificate
7. Certbot's deploy hook uploads cert to Tigris
8. All machines download new cert on next startup or via signal

## Implementation Plan

### Phase 1: Set up Tigris bucket

Create a Tigris bucket for cert storage:

```sh
flyctl storage create magnet-certs -a magnet-irc
```

This provides:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_ENDPOINT_URL_S3`
- `BUCKET_NAME`

Store these as Fly secrets.

### Phase 2: nginx proxy to Tigris for ACME challenges

Modify `solanum/nginx.conf` to proxy ACME challenges to Tigris:

```nginx
# ACME challenge proxy to Tigris
location /.well-known/acme-challenge/ {
    # Rewrite to Tigris bucket path
    proxy_pass ${TIGRIS_ENDPOINT}/magnet-certs/acme-challenge/;

    # Or if Tigris requires auth, use a local sync approach instead
}
```

**Note**: If Tigris requires authentication for reads, we'll need an alternative:
- Use a sidecar process that syncs from Tigris to local `/var/www/`
- Or make the bucket publicly readable (less secure but simpler)

**Files to modify:**
- `solanum/nginx.conf` - Add Tigris proxy or sync
- `solanum/Dockerfile` - Add AWS CLI or s3cmd for Tigris access

### Phase 3: Certbot hooks for Tigris

Create certbot hooks that upload challenges and certs to Tigris:

```sh
# /opt/solanum/bin/certbot-auth-hook.sh
#!/bin/sh
# Upload ACME challenge to Tigris
aws s3 cp - "s3://magnet-certs/acme-challenge/${CERTBOT_TOKEN}" \
    --endpoint-url "${AWS_ENDPOINT_URL_S3}" \
    <<< "${CERTBOT_VALIDATION}"
```

```sh
# /opt/solanum/bin/certbot-cleanup-hook.sh
#!/bin/sh
# Remove ACME challenge from Tigris
aws s3 rm "s3://magnet-certs/acme-challenge/${CERTBOT_TOKEN}" \
    --endpoint-url "${AWS_ENDPOINT_URL_S3}"
```

```sh
# /opt/solanum/bin/certbot-deploy-hook.sh
#!/bin/sh
# Upload renewed certs to Tigris
aws s3 cp "${RENEWED_LINEAGE}/fullchain.pem" "s3://magnet-certs/certs/ssl.pem" \
    --endpoint-url "${AWS_ENDPOINT_URL_S3}"
aws s3 cp "${RENEWED_LINEAGE}/privkey.pem" "s3://magnet-certs/certs/ssl.key" \
    --endpoint-url "${AWS_ENDPOINT_URL_S3}"
```

**Files to create:**
- `solanum/certbot-auth-hook.sh`
- `solanum/certbot-cleanup-hook.sh`
- `solanum/certbot-deploy-hook.sh`

### Phase 4: Modify start.sh for Tigris-based certs

Update `solanum/start.sh`:

```sh
# Try to download existing certs from Tigris
echo "Checking Tigris for existing certificates..."
if aws s3 cp "s3://magnet-certs/certs/ssl.pem" "$SSL_CERT" \
    --endpoint-url "${AWS_ENDPOINT_URL_S3}" 2>/dev/null && \
   aws s3 cp "s3://magnet-certs/certs/ssl.key" "$SSL_KEY" \
    --endpoint-url "${AWS_ENDPOINT_URL_S3}" 2>/dev/null; then

    echo "Downloaded certificates from Tigris"

    # Check if cert needs renewal (within 30 days of expiry)
    if openssl x509 -checkend 2592000 -noout -in "$SSL_CERT" 2>/dev/null; then
        echo "Certificate is valid for more than 30 days"
    else
        echo "Certificate expires within 30 days, attempting renewal..."
        # Try to acquire lock and renew
        run_certbot_with_lock
    fi
else
    echo "No certificates in Tigris, running certbot..."
    run_certbot_with_lock
fi
```

**Files to modify:**
- `solanum/start.sh` - Tigris-based cert management

### Phase 5: Distributed locking for certbot

To prevent multiple machines from running certbot simultaneously:

```sh
run_certbot_with_lock() {
    LOCK_FILE="s3://magnet-certs/certs/lock"
    LOCK_ID=$(hostname)-$$

    # Try to acquire lock (upload lock file)
    if aws s3 cp - "$LOCK_FILE" \
        --endpoint-url "${AWS_ENDPOINT_URL_S3}" \
        <<< "$LOCK_ID" 2>/dev/null; then

        # Verify we got the lock
        sleep 2
        CURRENT_LOCK=$(aws s3 cp "$LOCK_FILE" - --endpoint-url "${AWS_ENDPOINT_URL_S3}" 2>/dev/null)

        if [ "$CURRENT_LOCK" = "$LOCK_ID" ]; then
            echo "Acquired certbot lock"

            certbot certonly \
                --webroot \
                --webroot-path /var/www \
                --manual-auth-hook /opt/solanum/bin/certbot-auth-hook.sh \
                --manual-cleanup-hook /opt/solanum/bin/certbot-cleanup-hook.sh \
                --deploy-hook /opt/solanum/bin/certbot-deploy-hook.sh \
                ...

            # Release lock
            aws s3 rm "$LOCK_FILE" --endpoint-url "${AWS_ENDPOINT_URL_S3}"
        else
            echo "Lost lock race, another machine is handling renewal"
        fi
    else
        echo "Could not acquire lock, another machine is handling renewal"
    fi
}
```

### Phase 6: Scheduled renewal workflow

GitHub Actions workflow triggers renewal check:

```yaml
# .github/workflows/cert-renewal.yml
name: SSL Certificate Renewal Check

on:
  schedule:
    - cron: '0 0 1 */2 *'  # 1st of every 2nd month
  workflow_dispatch:

jobs:
  trigger-renewal:
    runs-on: ubuntu-latest
    steps:
      - uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Trigger renewal check on one machine
        run: |
          # SSH to any machine and trigger renewal check
          flyctl ssh console -a magnet-irc -C "/opt/solanum/bin/check-cert-renewal.sh"
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

**Files to create:**
- `.github/workflows/cert-renewal.yml`
- `solanum/check-cert-renewal.sh`

## Alternative: Simpler Tigris Approach

If the nginx-to-Tigris proxy is complex, a simpler approach:

1. **Make Tigris bucket publicly readable** for the `acme-challenge/` prefix only
2. **Use a background sync** process that polls Tigris every few seconds during cert acquisition
3. **Store certs as Fly secrets** instead of Tigris (simpler, no S3 access needed at runtime)

### Hybrid Approach (Recommended)

- **ACME challenges**: Upload to publicly-readable Tigris location
- **Certificates**: Store as Fly secrets (simpler runtime, no S3 client needed)
- **Renewal**: One machine runs certbot, uploads to Tigris for challenge, then updates Fly secrets via API

This gives:
- Simple cert distribution (secrets work everywhere)
- Shared challenge files (Tigris handles multi-machine routing)
- No local filesystem coordination needed

## Tigris Costs

- Free tier: 5GB storage, 10GB egress/month
- ACME challenges and certs are tiny (< 100KB total)
- Effectively free for this use case

## Rollback Plan

1. **Tigris issues**: Fall back to Fly secrets for cert storage
2. **Renewal fails**: Manual certbot run via `fly ssh console`
3. **Complete failure**: Self-signed cert fallback (already implemented)

## Future: DNS-01 Validation

When a permanent domain with DNS API access is available:

1. Switch to DNS-01 validation (no HTTP routing issues at all)
2. Add `certbot-dns-cloudflare` or similar
3. Remove Tigris dependency for ACME challenges
4. Keep Tigris or secrets for cert distribution
