#!/usr/bin/env bash
# Shared helpers for verathos_installer

set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '==> %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run as root (needed for apt/nginx)."
  fi
}

load_env() {
  local env_file="${INSTALLER_ROOT}/.env"
  [[ -f "$env_file" ]] || die "Missing ${env_file}. Copy .env.example → .env and fill values."

  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1091
  source "$env_file"
  set +a

  INSTANCE_IP="${INSTANCE_IP:?INSTANCE_IP required in .env}"
  EXTERNAL_PORT="${EXTERNAL_PORT:?EXTERNAL_PORT required in .env}"
  COLDKEY_NAME="${COLDKEY_NAME:?COLDKEY_NAME required in .env}"
  HOTKEY_NAME="${HOTKEY_NAME:?HOTKEY_NAME required in .env}"
  HUGGING_FACE_TOKEN="${HUGGING_FACE_TOKEN:?HUGGING_FACE_TOKEN required in .env}"

  VERATHOS_DIR="${VERATHOS_DIR:-/root/verathos}"
  VERATHOS_REPO="${VERATHOS_REPO:-https://github.com/verathos-ai/verathos}"
  # Default "auto" matches miner --model-id auto (GPU-tier registry pick).
  # Set MODEL_ID to a concrete HF repo to override (e.g. org/model-name).
  MODEL_ID="${MODEL_ID:-auto}"
  NETUID="${NETUID:-96}"
  NETWORK="${NETWORK:-finney}"
  LOCAL_PORT="${LOCAL_PORT:-8000}"
  GPU_ID="${GPU_ID:-0}"
  PM2_NAME="${PM2_NAME:-verathos-gpu0}"
  GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.85}"
  ENDPOINT="${ENDPOINT:-https://${INSTANCE_IP}:${EXTERNAL_PORT}}"
}

ensure_hf_token() {
  export HF_TOKEN="${HUGGING_FACE_TOKEN}"
  export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_TOKEN}"
  if ! grep -q 'export HF_TOKEN=' ~/.bashrc 2>/dev/null; then
    echo "export HF_TOKEN=\"${HUGGING_FACE_TOKEN}\"" >> ~/.bashrc
    ok "Persisted HF_TOKEN in ~/.bashrc"
  else
    # Refresh existing line without duplicating
    sed -i "s|^export HF_TOKEN=.*|export HF_TOKEN=\"${HUGGING_FACE_TOKEN}\"|" ~/.bashrc || true
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pm2_app_running() {
  have_cmd pm2 || return 1
  pm2 describe "$PM2_NAME" >/dev/null 2>&1
}
