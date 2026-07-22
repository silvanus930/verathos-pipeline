#!/usr/bin/env bash
# Install system dependencies: pipx/btcli, node/npm/pm2, nginx, openssl

install_system_deps() {
  log "Installing apt packages (pipx, curl, nginx, openssl, ca-certificates)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    pipx curl ca-certificates openssl nginx \
    python3-pip python3-venv

  # pipx / btcli
  if ! have_cmd btcli; then
    log "Installing bittensor-cli via pipx..."
    pipx ensurepath >/dev/null 2>&1 || true
    export PATH="${HOME}/.local/bin:${PATH}"
    pipx install bittensor-cli || pipx upgrade bittensor-cli || true
  else
    ok "btcli already present"
  fi
  export PATH="${HOME}/.local/bin:${PATH}"

  # Node.js + npm (prefer NodeSource LTS; fall back to distro packages)
  if ! have_cmd npm; then
    log "Installing Node.js / npm..."
    if curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -; then
      apt-get install -y nodejs
    else
      warn "NodeSource setup failed — falling back to apt nodejs/npm"
      apt-get install -y nodejs npm
    fi
  else
    ok "npm already present ($(npm -v))"
  fi

  if ! have_cmd pm2; then
    log "Installing pm2 globally..."
    npm install -g pm2
  else
    ok "pm2 already present ($(pm2 -v))"
  fi

  have_cmd nginx || die "nginx install failed"
  have_cmd openssl || die "openssl install failed"
  ok "System dependencies ready"
}
