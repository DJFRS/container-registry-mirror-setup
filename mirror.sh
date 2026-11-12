#!/usr/bin/env bash
set -Eeuo pipefail

# Registry mirror installer: Docker Hub, Quay, MCR, Kubernetes, GHCR, GitLab, Red Hat.
# Run with: sudo bash setup-all-container-mirrors.sh
# To replace pre-existing same-name containers with the new configuration:
#   sudo env RECREATE_EXISTING=1 bash setup-all-container-mirrors.sh
# RECREATE_EXISTING removes/recreates those containers (bind-mounted cache remains).

DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-sepehrsabz.ir}"
MIRROR_ROOT="${MIRROR_ROOT:-/opt}"
CACHE_ROOT="${CACHE_ROOT:-/data2/.cache}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
RECREATE_EXISTING="${RECREATE_EXISTING:-0}"

REGISTRIES=$'docker|5000|registry-1.docker.io\nquay|5001|quay.io\nmcr|5002|mcr.microsoft.com\nk8s|5003|registry.k8s.io\nghcr|5004|ghcr.io\ngitlab|5005|registry.gitlab.com\nredhat|5006|registry.redhat.io'

if [[ $EUID -ne 0 ]]; then
  echo 'ERROR: Run as root (sudo).' >&2
  exit 1
fi
for cmd in docker nginx; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is not installed." >&2
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  echo 'ERROR: Docker Compose v2 plugin is required.' >&2
  exit 1
fi
if [[ "$RECREATE_EXISTING" != 0 && "$RECREATE_EXISTING" != 1 ]]; then
  echo 'ERROR: RECREATE_EXISTING must be 0 or 1.' >&2
  exit 1
fi

mkdir -p "$NGINX_CONF_DIR" "$CACHE_ROOT" "$MIRROR_ROOT"
backup_dir="$(mktemp -d)"
trap 'rm -rf "$backup_dir"' EXIT

# Generate registry, Compose, and Nginx configurations for all seven mirrors.
while IFS='|' read -r name port upstream; do
  dir="${MIRROR_ROOT}/${name}-mirror"
  cache_dir="${CACHE_ROOT}/${name}"
  host="${name}.${DOMAIN_SUFFIX}"
  nginx_file="${NGINX_CONF_DIR}/${host}.conf"

  mkdir -p "$dir" "$cache_dir"
  if [[ -f "$nginx_file" ]]; then
    cp -p "$nginx_file" "${backup_dir}/${name}.conf"
  fi

  cat > "${dir}/config.yml" <<EOF
version: 0.1

log:
  level: info
  formatter: text

storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true

http:
  addr: 0.0.0.0:${port}
  headers:
    X-Content-Type-Options:
      - nosniff

proxy:
  remoteurl: https://${upstream}
  ttl: 0
EOF

  cat > "${dir}/docker-compose.yml" <<EOF
services:
  registry:
    image: registry:3
    container_name: ${name}-registry-cache
    restart: unless-stopped
    ports:
      - "127.0.0.1:${port}:${port}"
    volumes:
      - ${dir}/config.yml:/etc/distribution/config.yml:ro
      - ${cache_dir}:/var/lib/registry
    environment:
      REGISTRY_HTTP_ADDR: "0.0.0.0:${port}"
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"
EOF

  cat > "$nginx_file" <<EOF
server {
    listen 80;
    server_name ${host};

    location = / {
        root /data/docs;
        try_files /docker.html =404;
    }

    location /v2/ {
        proxy_pass http://127.0.0.1:${port};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_connect_timeout 60s;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;

        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF
  echo "Configured ${host} -> 127.0.0.1:${port} -> https://${upstream}"
done <<< "$REGISTRIES"

# Validate Nginx; restore previous vhosts if the new configuration fails.
if ! nginx -t; then
  echo 'ERROR: Nginx validation failed; restoring prior mirror vhost files.' >&2
  while IFS='|' read -r name port upstream; do
    nginx_file="${NGINX_CONF_DIR}/${name}.${DOMAIN_SUFFIX}.conf"
    if [[ -f "${backup_dir}/${name}.conf" ]]; then
      cp -p "${backup_dir}/${name}.conf" "$nginx_file"
    else
      rm -f "$nginx_file"
    fi
  done <<< "$REGISTRIES"
  exit 1
fi

# Start new caches, preserving containers that already exist unless opted in.
while IFS='|' read -r name port upstream; do
  container_name="${name}-registry-cache"
  compose_file="${MIRROR_ROOT}/${name}-mirror/docker-compose.yml"

  if docker container inspect "$container_name" >/dev/null 2>&1; then
    if [[ "$RECREATE_EXISTING" == 1 ]]; then
      echo "Replacing existing container: $container_name"
      docker container rm -f "$container_name"
    else
      echo "Keeping existing container: $container_name (config may differ)."
      docker container start "$container_name" >/dev/null
      continue
    fi
  fi

  docker compose -f "$compose_file" up -d
  echo "Started: $container_name"
done <<< "$REGISTRIES"

# Nginx is assumed to be installed and already running.
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
  systemctl reload nginx
else
  nginx -s reload
fi

echo
echo 'Mirror setup completed. HTTPS must be provided by your TLS proxy/CDN.'
echo 'Red Hat registry.redhat.io requires upstream authentication; private GitLab images require credentials.'
echo 'Secure mirrors before configuring upstream credentials: private upstream images may be exposed through the cache.'
echo 'Cache directories: '"$CACHE_ROOT"'/{docker,quay,mcr,k8s,ghcr,gitlab,redhat}'
echo 'Configs: '"$MIRROR_ROOT"'/{docker,quay,mcr,k8s,ghcr,gitlab,redhat}-mirror/'
if [[ "$RECREATE_EXISTING" == 0 ]]; then
  echo 'Note: Existing containers were reused. Set RECREATE_EXISTING=1 to apply new configs to them.'
fi
