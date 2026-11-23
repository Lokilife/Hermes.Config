#!/usr/bin/env bash
set -euo pipefail

PODMAN_USER="${1:-podman}"
BASE_DIR="/srv/containers"

if ! id "$PODMAN_USER" &>/dev/null; then
  echo "Error: User '$PODMAN_USER' does not exist." >&2
  exit 1
fi

USER_HOME=$(getent passwd "$PODMAN_USER" | cut -d: -f6)
USER_UID=$(id -u "$PODMAN_USER")
USER_GID=$(id -g "$PODMAN_USER")
QUADLET_DIR="$USER_HOME/.config/containers/systemd"

echo "==> 1. Configuring subuid/subgid and sysctl for rootless UserNS=auto..."
if ! grep -q "^${PODMAN_USER}:100000:1048576" /etc/subuid; then
  sudo usermod --add-subuids 100000-1148575 --add-subgids 100000-1148575 "$PODMAN_USER"
fi

if ! grep -q "ip_unprivileged_port_start=80" /etc/sysctl.d/99-podman-ports.conf 2>/dev/null; then
  echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-podman-ports.conf >/dev/null
fi
sudo sysctl --system >/dev/null

sudo loginctl enable-linger "$PODMAN_USER"

echo "==> 2. Configuring Podman userns_size and Quadlet directories..."
sudo -u "$PODMAN_USER" mkdir -p "$QUADLET_DIR"
sudo -u "$PODMAN_USER" chmod 755 "$USER_HOME" "$USER_HOME/.config" \
  "$USER_HOME/.config/containers" "$QUADLET_DIR"

cat << 'EOF' | sudo -u "$PODMAN_USER" tee "$USER_HOME/.config/containers/containers.conf" >/dev/null
[containers]
userns_size = 65536
EOF

echo "==> 3. Creating per-service directories in the git repo tree..."
QUADLET_SERVICES=(
  postgres redis nextcloud collabora meili tika turn voidauth
  nginx prometheus loki grafana crowdsec
)
ENV_SERVICES=(
  postgres redis nextcloud collabora meili turn voidauth grafana
)

sudo mkdir -p "$BASE_DIR" /var/log/nginx

for svc in "${QUADLET_SERVICES[@]}"; do
  sudo -u "$PODMAN_USER" mkdir -p "$QUADLET_DIR/$svc"
done
sudo -u "$PODMAN_USER" mkdir -p "$QUADLET_DIR/nginx/conf.d" "$QUADLET_DIR/nginx/crowdsec"

echo "==> 4. Creating /srv/containers data tree (volumes only, NOT in git)..."
DATA_DIRS=(
  postgres/data
  redis/data
  nextcloud/data
  collabora/data
  meili/data
  crowdsec/data
  nginx/data/certs
  nginx/data/www
  prometheus/data
  loki/data
  grafana/data
)
for dir in "${DATA_DIRS[@]}"; do
  sudo mkdir -p "$BASE_DIR/$dir"
done

echo "==> 5. Setting ownership, permissions, and ACLs..."
sudo chown -R "$USER_UID:$USER_GID" "$BASE_DIR" /var/log/nginx
sudo chmod 755 "$BASE_DIR"

# Service data dirs are private by default (no traverse for other UIDs)
for svc_dir in "$BASE_DIR"/*; do
  sudo chmod 750 "$svc_dir"
done

# nginx/certs must be traversable+readable by nginx's mapped subuid (UserNS=auto).
# Because the mapped UID isn't known until first container start, we make certs
# world-readable and harden later via the certbot deploy-hook.
sudo chmod 755 "$BASE_DIR/nginx/data" "$BASE_DIR/nginx/data/certs"
sudo find "$BASE_DIR/nginx/data/certs" -type f -exec chmod 644 {} \;

# /var/log/nginx must be readable by CrowdSec (different UserNS → different mapped UID).
# 'other' rx bits are the only portable way to express this without knowing mapped UIDs.
sudo apt-get install -y -qq acl apparmor-utils >/dev/null
sudo chmod 755 /var/log/nginx
sudo setfacl -R -m o::rx /var/log/nginx
sudo setfacl -d -m o::rx /var/log/nginx

# Pre-create empty .env files in the Quadlet tree (gitignored) so the operator
# gets an explicit hint about which secrets need filling.
for svc in "${ENV_SERVICES[@]}"; do
  env_file="$QUADLET_DIR/$svc/.env"
  if [ ! -f "$env_file" ]; then
    sudo -u "$PODMAN_USER" touch "$env_file"
  fi
  sudo chown "$USER_UID:$USER_GID" "$env_file"
  sudo chmod 600 "$env_file"
done

echo "==> Done."
echo "    Configs live in:  $QUADLET_DIR"
echo "    Data lives in:    $BASE_DIR"
echo "    Populate .env files and configs, then:"
echo "      sudo -u $PODMAN_USER git -C $QUADLET_DIR init"
