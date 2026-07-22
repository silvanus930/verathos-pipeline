#!/usr/bin/env bash
# Clone/setup verathos + optional Hugging Face model prefetch

setup_verathos_repo() {
  if [[ -d "${VERATHOS_DIR}/.git" ]]; then
    ok "Verathos repo already present at ${VERATHOS_DIR}"
  else
    log "Cloning ${VERATHOS_REPO} → ${VERATHOS_DIR}"
    mkdir -p "$(dirname "$VERATHOS_DIR")"
    git clone "$VERATHOS_REPO" "$VERATHOS_DIR"
  fi
}

run_setup_miner() {
  [[ -f "${VERATHOS_DIR}/scripts/setup_miner.sh" ]] || die "Missing ${VERATHOS_DIR}/scripts/setup_miner.sh"
  log "Running scripts/setup_miner.sh (this can take a long time)..."
  (
    cd "$VERATHOS_DIR"
    bash scripts/setup_miner.sh
  )
  ok "setup_miner.sh finished"
}

install_huggingface_hub() {
  log "Installing huggingface_hub..."
  python3 -m pip install --break-system-packages --quiet huggingface_hub || \
    pip install --break-system-packages --quiet huggingface_hub
  ok "huggingface_hub ready"
}

# Resolve MODEL_ID the same way the miner does with --model-id auto:
# detect GPU VRAM tier → recommend_models() → top checkpoint.
# If MODEL_ID is already set to a concrete HF repo, leave it unchanged.
resolve_model_id() {
  if [[ -n "${MODEL_ID}" && "${MODEL_ID}" != "auto" ]]; then
    ok "Using explicit MODEL_ID=${MODEL_ID}"
    return 0
  fi

  local py="${VERATHOS_DIR}/.venv-vllm/bin/python"
  [[ -x "$py" ]] || die "Missing ${py} — run setup_miner before model download"
  [[ -d "${VERATHOS_DIR}" ]] || die "Missing ${VERATHOS_DIR}"

  if [[ -f "${VERATHOS_DIR}/.vllm_ld_path.sh" ]]; then
    # shellcheck disable=SC1091
    source "${VERATHOS_DIR}/.vllm_ld_path.sh"
  fi

  log "Auto-selecting model for GPU ${GPU_ID} (same logic as miner --model-id auto)..."
  local resolved
  resolved="$(
    cd "${VERATHOS_DIR}" && \
    CUDA_VISIBLE_DEVICES="${GPU_ID}" "$py" - <<'PY'
import sys

from verallm.registry import recommend_models
from verallm.registry.gpu import detect_gpu_info

gpu_info = detect_gpu_info(0)
if not gpu_info.get("available"):
    print("No CUDA GPU detected for model auto-select", file=sys.stderr)
    sys.exit(1)

tier = gpu_info["tier"]
print(
    f"GPU: {gpu_info['name']} ({gpu_info['vram_gb']} GB, tier={tier.name})",
    file=sys.stderr,
)

# Match neurons.model_resolve.resolve_model_config(--model-id auto)
recs = recommend_models(tier, verified_only=False)
if not recs:
    print(f"No models fit GPU tier {tier.name}", file=sys.stderr)
    sys.exit(1)

best = recs[0]
print(
    f"Auto-selected: {best.config.checkpoint} "
    f"(registry={best.model.id}, quant={best.quant}, "
    f"ctx={best.est_context}, utility={best.utility:.1f})",
    file=sys.stderr,
)
print(best.config.checkpoint)
PY
  )" || die "Failed to auto-select model for GPU ${GPU_ID}"

  [[ -n "$resolved" ]] || die "Auto-select returned empty MODEL_ID"
  MODEL_ID="$resolved"
  ok "Resolved MODEL_ID=${MODEL_ID}"
}

download_model() {
  local force="${1:-0}"
  ensure_hf_token
  install_huggingface_hub
  resolve_model_id

  # Prefer setup_miner HF_HOME so prefetch lands where the miner loads from.
  if [[ -f "${VERATHOS_DIR}/.env.sh" ]]; then
    # shellcheck disable=SC1091
    source "${VERATHOS_DIR}/.env.sh"
  fi
  mkdir -p "${HF_HOME:-${HOME}/.cache/huggingface}"

  log "Prefetching model ${MODEL_ID} into HF cache (HF_HOME=${HF_HOME:-default})..."
  FORCE_DOWNLOAD="$force" MODEL_ID="$MODEL_ID" python3 - <<'PY'
import os
from huggingface_hub import snapshot_download
from huggingface_hub.constants import HF_HUB_CACHE

repo = os.environ["MODEL_ID"]
force = os.environ.get("FORCE_DOWNLOAD", "0") == "1"
print("Using cache:", HF_HUB_CACHE)
print("HF_HOME:", os.environ.get("HF_HOME"))
print("Repo:", repo, "force_download=", force)

path = snapshot_download(
    repo_id=repo,
    revision="main",
    cache_dir=HF_HUB_CACHE,
    local_files_only=False,
    force_download=force,
)
print("Complete snapshot:", path)
PY
  ok "Model download complete"
}
