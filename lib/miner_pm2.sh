#!/usr/bin/env bash
# Start / restart miner under pm2 (does nothing if already running unless forced)

start_miner_pm2() {
  local force_restart="${1:-0}"

  have_cmd pm2 || die "pm2 not installed"
  [[ -x "${VERATHOS_DIR}/.venv-vllm/bin/python" ]] || die "Missing ${VERATHOS_DIR}/.venv-vllm — run setup_miner first"
  [[ -f "${VERATHOS_DIR}/.vllm_ld_path.sh" ]] || setup_cuda_ld_path

  # Ensure nginx is up before miner port-check
  if have_cmd verathos-nginx-ensure; then
    verathos-nginx-ensure || true
  elif ! pgrep -x nginx >/dev/null 2>&1; then
    nginx || true
  fi

  if pm2_app_running; then
    if [[ "$force_restart" != "1" ]]; then
      warn "pm2 app '${PM2_NAME}' already running — leaving it alone (use --force-restart to replace)."
      pm2 list
      return 0
    fi
    log "Stopping existing ${PM2_NAME} (--force-restart)..."
    pm2 delete "$PM2_NAME" || true
  fi

  local start_cmd
  start_cmd=$(cat <<EOF
cd ${VERATHOS_DIR} && source .env.sh && source .vllm_ld_path.sh && CUDA_VISIBLE_DEVICES=${GPU_ID} python -m neurons.miner --wallet ${COLDKEY_NAME} --hotkey ${HOTKEY_NAME} --model-id auto --netuid ${NETUID} --subtensor-network ${NETWORK} --endpoint ${ENDPOINT} --auto-update --port ${LOCAL_PORT} -- --gpu-memory-utilization ${GPU_MEMORY_UTILIZATION}
EOF
)

  log "Starting ${PM2_NAME} via pm2..."
  # shellcheck disable=SC2086
  pm2 start bash --name "$PM2_NAME" -- -lc "$start_cmd"
  pm2 save || true
  ok "Started ${PM2_NAME}"
  pm2 list
  log "Follow logs with: pm2 logs ${PM2_NAME}"
}
