# Verathos Miner Installer

One-command installer for a Verathos (Bittensor subnet 96) GPU miner. It follows the steps in `01_command_list.txt` and applies fixes for common setup failures.

## Prerequisites

- Root access on an Ubuntu GPU host/container
- Bittensor wallet already uploaded to:

```text
~/.bittensor/wallets/<COLDKEY_NAME>/
  coldkeypub.txt
  hotkeys/<HOTKEY_NAME>
  hotkeys/<HOTKEY_NAME>pub.txt
```

Do **not** put the coldkey private key on a rented GPU if you can avoid it.

- Cloud/host firewall must forward `EXTERNAL_PORT` → this machine (nginx listens there)

## Quick start

```bash
cd /root/verathos_installer
cp .env.example .env
# Edit .env: INSTANCE_IP, EXTERNAL_PORT, COLDKEY_NAME, HOTKEY_NAME, HUGGING_FACE_TOKEN

bash install.sh
```

Follow logs:

```bash
pm2 logs verathos-gpu0
curl -s http://127.0.0.1:8000/health
curl -sk https://127.0.0.1:${EXTERNAL_PORT}/health
```

## What `install.sh` does

| Step | Action |
|------|--------|
| 1 | `apt` install pipx/nginx/openssl; `pipx install bittensor-cli`; Node.js + `npm install -g pm2` |
| 2 | Export `HF_TOKEN` from `.env` into the environment and `~/.bashrc` |
| 3 | `git clone` Verathos (if needed) + `bash scripts/setup_miner.sh` |
| 4 | `pip install huggingface_hub` + auto-select model for this GPU (same as miner `--model-id auto`) and download that HF snapshot |
| 5 | Generate TLS certs, write nginx site config, start nginx on `EXTERNAL_PORT` → `127.0.0.1:8000` |
| 6 | `pm2 start` the miner with CUDA library path configured |

## `.env` settings

| Variable | Required | Description |
|----------|----------|-------------|
| `INSTANCE_IP` | yes | Public IP used in `--endpoint` |
| `EXTERNAL_PORT` | yes | Public HTTPS port nginx listens on |
| `COLDKEY_NAME` | yes | Wallet name under `~/.bittensor/wallets/` |
| `HOTKEY_NAME` | yes | Hotkey name |
| `HUGGING_FACE_TOKEN` | yes | HF token for model download |
| `VERATHOS_DIR` | no | Default `/root/verathos` |
| `MODEL_ID` | no | Default `auto` — predownloads the same checkpoint Verathos picks for this GPU; set a concrete HF repo to override |
| `NETUID` | no | Default `96` |
| `NETWORK` | no | Default `finney` |
| `LOCAL_PORT` | no | Default `8000` (miner bind port) |
| `GPU_ID` | no | Default `0` |
| `PM2_NAME` | no | Default `verathos-gpu0` |
| `GPU_MEMORY_UTILIZATION` | no | Default `0.85` |

## Options

```bash
bash install.sh --help
```

| Flag | Meaning |
|------|---------|
| `--skip-deps` | Skip apt/npm/pm2 package install |
| `--skip-clone` | Do not `git clone` (repo must already exist) |
| `--skip-setup-miner` | Skip `scripts/setup_miner.sh` |
| `--skip-model` | Skip Hugging Face model download |
| `--force-model` | Force re-download of the model snapshot |
| `--skip-nginx` | Skip nginx setup |
| `--skip-wallet-fix` | Skip wallet `cryptoType` fix |
| `--no-start` | Prepare everything but do not start pm2 |
| `--force-restart` | Replace an already-running pm2 miner |
| `--only-fix` | Only apply wallet/CUDA/nginx fixes (no clone/setup/model) |

### Useful examples

Already installed; only re-apply fixes without touching a live miner:

```bash
bash install.sh --only-fix --no-start
```

Fresh machine, wallet already in place, full install:

```bash
bash install.sh
```

Repo + venv already set up; just nginx + start:

```bash
bash install.sh --skip-deps --skip-clone --skip-setup-miner --skip-model --force-restart
```

bash install.sh \
  --instance-ip=91.224.44.223 \
  --external-port=40039 \
  --coldkey-name=silvanus-hs1 \
  --hotkey-name=hotkey1

## Auto-fixes included

These are issues hit during manual install and handled automatically:

| Problem | Fix |
|---------|-----|
| `npm: command not found` | Installs Node.js LTS + npm + pm2 |
| `externally-managed-environment` for pip | Uses `pip install --break-system-packages` |
| nginx `unknown directive " "` | Writes ASCII-only site config (no NBSP from copy/paste) |
| Missing SSL certs | Generates self-signed cert under `/etc/nginx/ssl/` |
| nginx not running (no systemd) | Starts `nginx` directly; adds `verathos-nginx-ensure` |
| `KeyFileError` / `cryptoType` DeserializationError | Strips `cryptoType` from wallet JSON (backs up as `*.bak`) |
| `ImportError: libcudart.so.13` | Installs `nvidia-cuda-runtime` and sources `.vllm_ld_path.sh` before the miner |

## Safety

- If `PM2_NAME` (default `verathos-gpu0`) is already running, the installer **does not restart it** unless you pass `--force-restart`.
- Prefer `--no-start` when preparing a host that already has a production miner.

## Layout

```text
verathos_installer/
  install.sh          # Main entry (install steps 1–6)
  .env                # Your secrets/config (do not commit)
  .env.example        # Template
  01_command_list.txt # Manual reference commands
  lib/
    common.sh         # Shared helpers / env loading
    wallet_fix.sh    # cryptoType keyfile fix
    cuda_path.sh      # LD_LIBRARY_PATH for vLLM CUDA 13
    nginx.sh          # TLS proxy site + certs
```

## After install

```bash
pm2 list
pm2 logs verathos-gpu0
pm2 restart verathos-gpu0   # only if you intend to restart

# nginx
ss -tlnp | grep :40019
curl -sk https://127.0.0.1:40019/health
```

First startup can take a long time (model load + Merkle tree build). Wait until `/health` returns successfully before expecting validators to connect.
