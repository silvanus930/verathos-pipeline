#!/usr/bin/env bash
# =============================================================================
# Verathos one-command installer
# =============================================================================
#
# Usage:
#   cd /root/verathos_installer
#   cp .env.example .env   # edit values
#   bash install.sh --instance-ip 91.224.44.223 --external-port 40039 \
#     --coldkey-name dxpian --hotkey-name default \
#     --hugging-face-token hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#
# Safe default: if pm2 miner is already running, it will NOT be restarted.
#
# Options:
#   --instance-ip VALUE    Override INSTANCE_IP from .env
#   --external-port VALUE  Override EXTERNAL_PORT from .env
#   --coldkey-name VALUE   Override COLDKEY_NAME from .env
#   --hotkey-name VALUE    Override HOTKEY_NAME from .env
#   --hugging-face-token VALUE  Override HUGGING_FACE_TOKEN from .env
#   --skip-deps            Skip apt/npm/pm2/nginx package install
#   --skip-clone           Skip git clone (repo must already exist)
#   --skip-setup-miner     Skip scripts/setup_miner.sh
#   --skip-model           Skip Hugging Face model prefetch
#   --force-model          Force re-download model snapshot
#   --skip-nginx           Skip nginx TLS proxy setup
#   --skip-wallet-fix     Skip cryptoType keyfile fix
#   --no-start             Do not start/restart the miner via pm2
#   --force-restart        Replace an already-running pm2 miner
#   --only-fix            Only apply fixes (wallet/cuda/nginx) — no clone/setup
#   --help                 Show this help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# Auto-fix helpers (wallet cryptoType, CUDA LD_LIBRARY_PATH, nginx site writer)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/wallet_fix.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/cuda_path.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/nginx.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/model.sh"

SKIP_DEPS=0
SKIP_CLONE=0
SKIP_SETUP_MINER=0
SKIP_MODEL=0
FORCE_MODEL=0
SKIP_NGINX=0
SKIP_WALLET_FIX=0
NO_START=0
FORCE_RESTART=0
ONLY_FIX=0
CLI_INSTANCE_IP=""
CLI_EXTERNAL_PORT=""
CLI_COLDKEY_NAME=""
CLI_HOTKEY_NAME=""
CLI_HUGGING_FACE_TOKEN=""

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \?//'
}

require_option_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || die "${option} requires a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-ip)
      require_option_value "$1" "${2:-}"; CLI_INSTANCE_IP="$2"; shift 2 ;;
    --instance-ip=*)
      CLI_INSTANCE_IP="${1#*=}"; require_option_value "--instance-ip" "${CLI_INSTANCE_IP}"; shift ;;
    --external-port)
      require_option_value "$1" "${2:-}"; CLI_EXTERNAL_PORT="$2"; shift 2 ;;
    --external-port=*)
      CLI_EXTERNAL_PORT="${1#*=}"; require_option_value "--external-port" "${CLI_EXTERNAL_PORT}"; shift ;;
    --coldkey-name)
      require_option_value "$1" "${2:-}"; CLI_COLDKEY_NAME="$2"; shift 2 ;;
    --coldkey-name=*)
      CLI_COLDKEY_NAME="${1#*=}"; require_option_value "--coldkey-name" "${CLI_COLDKEY_NAME}"; shift ;;
    --hotkey-name)
      require_option_value "$1" "${2:-}"; CLI_HOTKEY_NAME="$2"; shift 2 ;;
    --hotkey-name=*)
      CLI_HOTKEY_NAME="${1#*=}"; require_option_value "--hotkey-name" "${CLI_HOTKEY_NAME}"; shift ;;
    --hugging-face-token)
      require_option_value "$1" "${2:-}"; CLI_HUGGING_FACE_TOKEN="$2"; shift 2 ;;
    --hugging-face-token=*)
      CLI_HUGGING_FACE_TOKEN="${1#*=}"; require_option_value "--hugging-face-token" "${CLI_HUGGING_FACE_TOKEN}"; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --skip-clone) SKIP_CLONE=1; shift ;;
    --skip-setup-miner) SKIP_SETUP_MINER=1; shift ;;
    --skip-model) SKIP_MODEL=1; shift ;;
    --force-model) FORCE_MODEL=1; shift ;;
    --skip-nginx) SKIP_NGINX=1; shift ;;
    --skip-wallet-fix) SKIP_WALLET_FIX=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --force-restart) FORCE_RESTART=1; shift ;;
    --only-fix) ONLY_FIX=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

# ── Step 1: system packages (pipx/btcli, node/npm/pm2, nginx) ────────────────

step_install_deps() {
  log "[1/6] Installing system packages..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get install -y --no-install-recommends \
    pipx curl ca-certificates openssl nginx \
    python3-pip python3-venv git

  # bittensor CLI
  pipx ensurepath >/dev/null 2>&1 || true
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v btcli >/dev/null 2>&1; then
    pipx install bittensor-cli
  else
    ok "btcli already installed"
  fi

  # Node.js + npm + pm2
  if ! command -v npm >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
  else
    ok "npm already installed ($(npm -v))"
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    npm install -g pm2
  else
    ok "pm2 already installed ($(pm2 -v))"
  fi

  ok "[1/6] deps ready (pipx/btcli, node/npm/pm2, nginx, openssl)"
}

# ── Step 2: HF token ─────────────────────────────────────────────────────────

step_export_hf_token() {
  log "[2/6] Exporting Hugging Face token from .env..."
  export HF_TOKEN="${HUGGING_FACE_TOKEN}"
  export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_TOKEN}"
  if grep -q '^export HF_TOKEN=' ~/.bashrc 2>/dev/null; then
    sed -i "s|^export HF_TOKEN=.*|export HF_TOKEN=\"${HUGGING_FACE_TOKEN}\"|" ~/.bashrc
  else
    echo "export HF_TOKEN=\"${HUGGING_FACE_TOKEN}\"" >> ~/.bashrc
  fi
  ok "[2/6] HF_TOKEN exported"
}

# ── Step 3: clone verathos + setup_miner.sh ──────────────────────────────────

step_clone_and_setup() {
  log "[3/6] Clone verathos + run scripts/setup_miner.sh..."

  if [[ ! -d "${VERATHOS_DIR}/.git" ]]; then
    git clone "${VERATHOS_REPO}" "${VERATHOS_DIR}"
  else
    ok "Repo already exists: ${VERATHOS_DIR}"
  fi

  if [[ "$SKIP_SETUP_MINER" == "1" ]]; then
    warn "Skipping scripts/setup_miner.sh (--skip-setup-miner)"
    return 0
  fi

  cd "${VERATHOS_DIR}"
  bash scripts/setup_miner.sh
  ok "[3/6] setup_miner.sh finished"
}

# ── Step 4: huggingface_hub + model download ─────────────────────────────────

step_download_model() {
  log "[4/6] Install huggingface_hub + download model (MODEL_ID=${MODEL_ID})..."
  download_model "${FORCE_MODEL}"
  ok "[4/6] model ready (${MODEL_ID})"
}

# ── Step 5: nginx TLS proxy ──────────────────────────────────────────────────
# (implemented in lib/nginx.sh — writes ASCII config, generates certs, starts nginx)

step_nginx() {
  log "[5/6] Setup nginx TLS proxy :${EXTERNAL_PORT} → 127.0.0.1:${LOCAL_PORT}..."
  setup_nginx
  ok "[5/6] nginx listening on :${EXTERNAL_PORT}"
}

# ── Step 6: start miner with pm2 ─────────────────────────────────────────────

step_start_miner() {
  log "[6/6] Start miner with pm2 (${PM2_NAME})..."

  # CUDA 13 runtime path (fixes ImportError: libcudart.so.13)
  setup_cuda_ld_path

  if ! command -v pm2 >/dev/null 2>&1; then
    die "pm2 not found — run without --skip-deps"
  fi
  [[ -x "${VERATHOS_DIR}/.venv-vllm/bin/python" ]] || \
    die "Missing ${VERATHOS_DIR}/.venv-vllm — run setup_miner first"

  # Keep nginx up for external port check
  pgrep -x nginx >/dev/null 2>&1 || nginx

  if pm2 describe "${PM2_NAME}" >/dev/null 2>&1; then
    if [[ "${FORCE_RESTART}" != "1" ]]; then
      warn "pm2 app '${PM2_NAME}' already running — leaving it alone"
      warn "Use --force-restart to replace it"
      pm2 list
      return 0
    fi
    pm2 delete "${PM2_NAME}" || true
  fi

  # .env.sh sets HF_HOME / cache paths from setup_miner; .vllm_ld_path.sh sets CUDA libs
  pm2 start bash --name "${PM2_NAME}" -- -lc "\
cd ${VERATHOS_DIR} && \
source .env.sh && \
source .vllm_ld_path.sh && \
CUDA_VISIBLE_DEVICES=${GPU_ID} python -m neurons.miner \
  --wallet ${COLDKEY_NAME} \
  --hotkey ${HOTKEY_NAME} \
  --model-id auto \
  --netuid ${NETUID} \
  --subtensor-network ${NETWORK} \
  --endpoint ${ENDPOINT} \
  --auto-update \
  --port ${LOCAL_PORT} \
  -- --gpu-memory-utilization ${GPU_MEMORY_UTILIZATION}"

  pm2 save || true
  pm2 list
  ok "[6/6] miner started — follow with: pm2 logs ${PM2_NAME}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  require_root
  load_env

  # Explicit CLI values take precedence over matching values in .env.
  [[ -z "${CLI_INSTANCE_IP}" ]] || INSTANCE_IP="${CLI_INSTANCE_IP}"
  [[ -z "${CLI_EXTERNAL_PORT}" ]] || EXTERNAL_PORT="${CLI_EXTERNAL_PORT}"
  [[ -z "${CLI_COLDKEY_NAME}" ]] || COLDKEY_NAME="${CLI_COLDKEY_NAME}"
  [[ -z "${CLI_HOTKEY_NAME}" ]] || HOTKEY_NAME="${CLI_HOTKEY_NAME}"
  [[ -z "${CLI_HUGGING_FACE_TOKEN}" ]] || HUGGING_FACE_TOKEN="${CLI_HUGGING_FACE_TOKEN}"

  INSTANCE_IP="${INSTANCE_IP:?INSTANCE_IP is required in .env or --instance-ip}"
  EXTERNAL_PORT="${EXTERNAL_PORT:?EXTERNAL_PORT is required in .env or --external-port}"
  COLDKEY_NAME="${COLDKEY_NAME:?COLDKEY_NAME is required in .env or --coldkey-name}"
  HOTKEY_NAME="${HOTKEY_NAME:?HOTKEY_NAME is required in .env or --hotkey-name}"
  HUGGING_FACE_TOKEN="${HUGGING_FACE_TOKEN:?HUGGING_FACE_TOKEN is required in .env or --hugging-face-token}"

  if [[ -n "${CLI_INSTANCE_IP}" || -n "${CLI_EXTERNAL_PORT}" ]]; then
    ENDPOINT="https://${INSTANCE_IP}:${EXTERNAL_PORT}"
  fi
  ENDPOINT="${ENDPOINT:-https://${INSTANCE_IP}:${EXTERNAL_PORT}}"

  log "Verathos installer"
  log "  endpoint = ${ENDPOINT}"
  log "  wallet   = ${COLDKEY_NAME}/${HOTKEY_NAME}"
  log "  dir      = ${VERATHOS_DIR}"
  log "  model    = ${MODEL_ID}"

  if [[ "${ONLY_FIX}" == "1" ]]; then
    log "Fix-only mode"
    step_export_hf_token
    [[ "${SKIP_WALLET_FIX}" == "1" ]] || fix_wallet_keyfiles
    [[ "${SKIP_NGINX}" == "1" ]] || step_nginx
    setup_cuda_ld_path
    [[ "${NO_START}" == "1" ]] || step_start_miner
    ok "Fix-only complete"
    return 0
  fi

  # 1) apt / npm / pm2 / nginx packages
  [[ "${SKIP_DEPS}" == "1" ]] || step_install_deps

  # 2) HF token into env + ~/.bashrc
  step_export_hf_token

  # Wallet must already be under ~/.bittensor/wallets/$COLDKEY_NAME
  # Auto-fix: strip legacy cryptoType that breaks bittensor_wallet 4.x
  [[ "${SKIP_WALLET_FIX}" == "1" ]] || fix_wallet_keyfiles

  # 3) git clone + bash scripts/setup_miner.sh
  if [[ "${SKIP_CLONE}" == "1" && "${SKIP_SETUP_MINER}" == "1" ]]; then
    warn "Skipping clone and setup_miner"
  elif [[ "${SKIP_CLONE}" == "1" ]]; then
    [[ "${SKIP_SETUP_MINER}" == "1" ]] || {
      cd "${VERATHOS_DIR}"
      bash scripts/setup_miner.sh
    }
  else
    step_clone_and_setup
  fi

  # CUDA path helper after venv exists
  setup_cuda_ld_path

  # 4) pip install huggingface_hub + snapshot_download
  [[ "${SKIP_MODEL}" == "1" ]] || step_download_model

  # 5) nginx cert + site + start
  [[ "${SKIP_NGINX}" == "1" ]] || step_nginx

  # 6) pm2 start miner
  if [[ "${NO_START}" == "1" ]]; then
    warn "Skipping miner start (--no-start)"
  else
    step_start_miner
  fi

  cat <<EOF

========================================================================
Install finished.

  Endpoint:  ${ENDPOINT}
  Local:     http://127.0.0.1:${LOCAL_PORT}/health
  Logs:      pm2 logs ${PM2_NAME}

Auto-fixes applied when needed:
  - wallet cryptoType DeserializationError
  - nginx NBSP / missing certs / nginx not running
  - libcudart.so.13 via .vllm_ld_path.sh + nvidia-cuda-runtime
========================================================================
EOF
}

main "$@"
