#!/usr/bin/env bash
# ===================================================
#     Portable Uncensored AI - Launcher (Linux)
# ===================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DGRAY='\033[0;90m'
NC='\033[0m'

# All paths resolve relative to this script's location (the USB root)
USB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${CYAN}==================================================="
echo -e "     Launching Portable AI Engine from USB..."
echo -e "===================================================${NC}"

# -------------------------------------------------------
# PATH CONFIGURATION — everything stays on the USB
# -------------------------------------------------------
export OLLAMA_MODELS="$USB_DIR/ollama/data"
export STORAGE_DIR="$USB_DIR/anythingllm_data"

# XDG overrides so Electron/AnythingLLM writes to the USB
export XDG_CONFIG_HOME="$STORAGE_DIR/config"
export XDG_DATA_HOME="$STORAGE_DIR/data"
export XDG_CACHE_HOME="$STORAGE_DIR/cache"

mkdir -p \
    "$STORAGE_DIR" \
    "$STORAGE_DIR/storage" \
    "$XDG_CONFIG_HOME" \
    "$XDG_DATA_HOME" \
    "$XDG_CACHE_HOME"

OLLAMA_BIN="$USB_DIR/ollama/ollama"
APPIMAGE="$USB_DIR/anythingllm/AnythingLLM.AppImage"

# -------------------------------------------------------
# READ DEFAULT MODEL FROM installed-models.txt
# -------------------------------------------------------
DEFAULT_MODEL="nemomix-local"
MODELS_FILE="$USB_DIR/models/installed-models.txt"
if [[ -f "$MODELS_FILE" ]]; then
    FIRST_LINE=$(head -1 "$MODELS_FILE")
    DEFAULT_MODEL="${FIRST_LINE%%|*}"
fi

# -------------------------------------------------------
# CONFIGURE .env IF NEEDED
# -------------------------------------------------------
ENV_FILE="$STORAGE_DIR/storage/.env"

needs_fix=false
[[ ! -f "$ENV_FILE" ]] && needs_fix=true
if [[ -f "$ENV_FILE" ]]; then
    grep -q "LLM_PROVIDER=ollama" "$ENV_FILE" || needs_fix=true
    grep -q "LLM_PROVIDER=anythingllm_ollama" "$ENV_FILE" && needs_fix=true
fi

if $needs_fix; then
    echo "Configuring AnythingLLM to use external Ollama engine..."
    cat > "$ENV_FILE" <<EOF
LLM_PROVIDER=ollama
OLLAMA_BASE_PATH=http://127.0.0.1:11434
OLLAMA_MODEL_PREF=${DEFAULT_MODEL}
OLLAMA_MODEL_TOKEN_LIMIT=4096
EMBEDDING_ENGINE=native
VECTOR_DB=lancedb
EOF
    echo "Done. Default model: ${DEFAULT_MODEL}"
fi

# -------------------------------------------------------
# SHOW INSTALLED MODELS
# -------------------------------------------------------
if [[ -f "$MODELS_FILE" ]]; then
    echo ""
    echo "Installed models:"
    while IFS='|' read -r local_name display_name label _; do
        echo "  - ${display_name} [${label}]"
    done < "$MODELS_FILE"
    echo ""
fi

# -------------------------------------------------------
# SANITY CHECKS
# -------------------------------------------------------
if [[ ! -x "$OLLAMA_BIN" ]]; then
    echo -e "${RED}ERROR: Ollama binary not found at: $OLLAMA_BIN${NC}"
    echo "Please run install.sh first."
    exit 1
fi

if [[ ! -f "$APPIMAGE" ]]; then
    echo -e "${RED}ERROR: AnythingLLM AppImage not found at: $APPIMAGE${NC}"
    echo "Please run install.sh first."
    exit 1
fi

# Ensure AppImage is executable
chmod +x "$APPIMAGE" 2>/dev/null || true

# -------------------------------------------------------
# WIPE ELECTRON PATH CACHES (ensures true portability
# when USB is moved between machines)
# -------------------------------------------------------
ANYTHINGLLM_CACHE="$XDG_CONFIG_HOME/anythingllm-desktop"
rm -f  "$ANYTHINGLLM_CACHE/config.json"           2>/dev/null || true
rm -rf "$ANYTHINGLLM_CACHE/Cache"                 2>/dev/null || true
rm -rf "$ANYTHINGLLM_CACHE/Code Cache"            2>/dev/null || true
rm -rf "$ANYTHINGLLM_CACHE/GPUCache"              2>/dev/null || true

# -------------------------------------------------------
# RAM ADVISORY
# -------------------------------------------------------
_RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
_RAM_GB=$(( _RAM_KB / 1024 / 1024 ))
if (( _RAM_GB > 0 && _RAM_GB < 4 )); then
    echo -e "${RED}WARNING: Only ${_RAM_GB} GB RAM detected. AI models require at least 4 GB — expect crashes or very slow responses.${NC}"
elif (( _RAM_GB > 0 && _RAM_GB < 6 )); then
    echo -e "${YELLOW}NOTE: ${_RAM_GB} GB RAM. 7B+ models need 6 GB; NemoMix 12B needs 8 GB.${NC}"
fi
unset _RAM_KB _RAM_GB

# -------------------------------------------------------
# START OLLAMA ENGINE (background)
# -------------------------------------------------------
echo "Starting Ollama Engine..."
OLLAMA_HOST="127.0.0.1:11434" "$OLLAMA_BIN" serve &>/dev/null &
OLLAMA_PID=$!

# Poll until the API responds (up to 30 s) instead of a fixed sleep.
# If Ollama OOMs on start-up it exits before the timeout and we can explain why.
printf "Waiting for Ollama to be ready"
_ollama_ready=false
for (( _i=1; _i<=30; _i++ )); do
    if curl -sf --max-time 1 "http://127.0.0.1:11434/api/tags" &>/dev/null; then
        echo " ready."
        _ollama_ready=true
        break
    fi
    printf "."
    sleep 1
done
if ! $_ollama_ready; then
    echo " timeout."
    if ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
        echo -e "${RED}ERROR: Ollama exited before becoming ready.${NC}"
        echo "This usually means insufficient RAM for the selected model."
        echo "NemoMix 12B requires at least 8 GB RAM; 7B models need at least 6 GB."
        exit 1
    fi
    echo -e "${YELLOW}Warning: Ollama did not respond yet — it may still be initialising.${NC}"
fi
unset _ollama_ready _i

# -------------------------------------------------------
# START ANYTHINGLLM (foreground-launched, detached)
# -------------------------------------------------------
echo "Starting AnythingLLM Interface..."

# AppImages need FUSE. If not available, try --appimage-extract-and-run
if "$APPIMAGE" --appimage-help &>/dev/null 2>&1; then
    # Standard launch with user-data-dir pointing to USB
    "$APPIMAGE" \
        --user-data-dir="$STORAGE_DIR/anythingllm-desktop" \
        --no-sandbox \
        &>/dev/null &
else
    # Fallback: extract-and-run mode (no FUSE required)
    APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE" \
        --user-data-dir="$STORAGE_DIR/anythingllm-desktop" \
        --no-sandbox \
        &>/dev/null &
fi
ANYTHINGLLM_PID=$!

echo ""
echo -e "${CYAN}==================================================="
echo -e "   SYSTEM ONLINE: Your AI is running from USB!"
echo -e "===================================================${NC}"
echo ""
echo "You can now use the AnythingLLM window to chat."
echo -e "${YELLOW}Keep this terminal open to keep the AI engine running!${NC}"
echo ""
echo "TIP: Go to Settings > LLM to switch between models."
echo ""
echo -e "${RED}Press Enter to SHUT DOWN the AI safely...${NC}"
read -r

# -------------------------------------------------------
# CLEAN SHUTDOWN
# -------------------------------------------------------
echo ""
echo "Shutting down..."
kill "$ANYTHINGLLM_PID" 2>/dev/null || true
kill "$OLLAMA_PID"       2>/dev/null || true
pkill -f "AnythingLLM"   2>/dev/null || true
pkill -f "ollama serve"  2>/dev/null || true

echo "AI Engine shut down. You may safely eject the USB."
sleep 2
