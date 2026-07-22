#!/usr/bin/env bash
# Fix legacy Bittensor keyfiles that include "cryptoType" (breaks bittensor_wallet 4.x)

fix_wallet_keyfiles() {
  local wallet_dir="${HOME}/.bittensor/wallets/${COLDKEY_NAME}"
  [[ -d "$wallet_dir" ]] || die "Wallet not found: ${wallet_dir}
Upload your wallet folder to ~/.bittensor/wallets/${COLDKEY_NAME}/ first."

  local hotkey_path="${wallet_dir}/hotkeys/${HOTKEY_NAME}"
  [[ -f "$hotkey_path" ]] || die "Hotkey not found: ${hotkey_path}"

  log "Fixing wallet keyfiles for bittensor_wallet compatibility (strip cryptoType)..."
  python3 - <<PY
import json
from pathlib import Path

wallet = Path.home() / ".bittensor/wallets" / "${COLDKEY_NAME}"
paths = [
    wallet / "coldkeypub.txt",
    wallet / "hotkeys" / "${HOTKEY_NAME}",
    wallet / "hotkeys" / f"${HOTKEY_NAME}pub.txt",
]
# Also fix any sibling hotkeys in the folder
hk_dir = wallet / "hotkeys"
if hk_dir.is_dir():
    for p in hk_dir.iterdir():
        if p.is_file():
            paths.append(p)

seen = set()
fixed = 0
for path in paths:
    path = path.resolve()
    if path in seen or not path.is_file():
        continue
    seen.add(path)
    raw = path.read_bytes()
    # Skip NACL-encrypted coldkey private files
    if raw.startswith(b"\$NACL") or raw.startswith(b"\$NACLX"):
        print(f"skip encrypted: {path.name}")
        continue
    try:
        obj = json.loads(raw.decode("utf-8"))
    except Exception:
        print(f"skip non-json: {path.name}")
        continue
    if not isinstance(obj, dict) or "cryptoType" not in obj:
        continue
    bak = path.with_suffix(path.suffix + ".bak")
    if not bak.exists():
        bak.write_bytes(raw)
    obj.pop("cryptoType", None)
    path.write_text(json.dumps(obj, separators=(",", ":")))
    fixed += 1
    print(f"fixed: {path}")
print(f"fixed_count={fixed}")
PY

  ok "Wallet keyfiles checked/fixed for ${COLDKEY_NAME}/${HOTKEY_NAME}"
}
