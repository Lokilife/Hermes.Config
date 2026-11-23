#!/usr/bin/env bash
set -euo pipefail

STAMP=$(date +%Y-%m-%d_%H%M)
DEST="/backup/nextcloud-stack-$STAMP"
mkdir -p "$DEST"

# 1. PostgreSQL — logical dump of every database
podman exec postgres pg_dumpall -U postgres > "$DEST/postgres-all.sql"

# 2. Nextcloud data (files + config + apps)
tar -C /srv/containers/nextcloud -czf "$DEST/nextcloud-data.tar.gz" data

# 3. Collabora config
tar -C /srv/containers/collabora -czf "$DEST/collabora-config.tar.gz" config

# 4. Meilisearch index
tar -C /srv/containers/meili -czf "$DEST/meili-data.tar.gz" data

# 5. TLS certificates
tar -C /srv/containers/nginx -czf "$DEST/nginx-certs.tar.gz" data/certs

# 6. TURN config
tar -C /srv/containers/turn -czf "$DEST/turn-config.tar.gz" config

# 7. Manifest
echo "Backup created: $STAMP" > "$DEST/MANIFEST.txt"
echo "Databases: $(podman exec postgres psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1')" | tr '\n' ' ')" >> "$DEST/MANIFEST.txt"

echo "Backup written to $DEST"
