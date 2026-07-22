#!/usr/bin/env bash
# nginx TLS reverse proxy driven by .env:
#   EXTERNAL_PORT (HTTPS listen) → 127.0.0.1:LOCAL_PORT (miner, default 8000)
# Called from install.sh step_nginx after load_env.

setup_nginx() {
  : "${EXTERNAL_PORT:?EXTERNAL_PORT must be set from .env via load_env}"
  : "${LOCAL_PORT:?LOCAL_PORT must be set from .env via load_env}"

  log "Configuring nginx TLS proxy on :${EXTERNAL_PORT} → 127.0.0.1:${LOCAL_PORT}"

  mkdir -p /etc/nginx/ssl /etc/nginx/sites-available /etc/nginx/sites-enabled
  if [[ ! -f /etc/nginx/ssl/miner.crt || ! -f /etc/nginx/ssl/miner.key ]]; then
    log "Generating self-signed TLS certificate..."
    openssl req -x509 -nodes -days 365 \
      -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/miner.key \
      -out /etc/nginx/ssl/miner.crt \
      -subj "/CN=verathos-miner"
  else
    ok "TLS cert already present"
  fi

  # Always rewrite from .env values (ASCII only). Prefer sites-available + symlink
  # so a stale plain file in sites-enabled cannot shadow the live config.
  cat > /etc/nginx/sites-available/verathos-miner <<EOF
server {
    listen ${EXTERNAL_PORT} ssl;
    ssl_certificate /etc/nginx/ssl/miner.crt;
    ssl_certificate_key /etc/nginx/ssl/miner.key;
    client_max_body_size 10m;
    location / {
        proxy_pass http://127.0.0.1:${LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  # Older install.sh wrote a regular file into sites-enabled; replace with symlink
  if [[ -e /etc/nginx/sites-enabled/verathos-miner && ! -L /etc/nginx/sites-enabled/verathos-miner ]]; then
    rm -f /etc/nginx/sites-enabled/verathos-miner
  fi
  ln -sfn /etc/nginx/sites-available/verathos-miner /etc/nginx/sites-enabled/verathos-miner

  if [[ -e /etc/nginx/sites-enabled/default ]] && \
     grep -qE "listen[[:space:]]+${EXTERNAL_PORT}([[:space:]]|;)" /etc/nginx/sites-enabled/default 2>/dev/null; then
    warn "default site also listens on :${EXTERNAL_PORT} — disabling it"
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t || die "nginx config test failed"

  if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s reload || { pkill nginx || true; sleep 0.5; nginx; }
  else
    nginx
  fi

  if have_cmd systemctl && systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
  fi

  cat > /usr/local/bin/verathos-nginx-ensure <<'EOS'
#!/usr/bin/env bash
nginx -t || exit 1
pgrep -x nginx >/dev/null 2>&1 || nginx
EOS
  chmod +x /usr/local/bin/verathos-nginx-ensure

  sleep 0.5
  # Anchor port match so EXTERNAL_PORT=80 does not falsely match :8000
  if ! ss -tlnp | grep -qE "[:.]${EXTERNAL_PORT}[[:space:]]"; then
    die "nginx not listening on :${EXTERNAL_PORT}"
  fi
  ok "nginx listening on :${EXTERNAL_PORT} → 127.0.0.1:${LOCAL_PORT}"
}
