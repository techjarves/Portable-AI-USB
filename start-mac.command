#!/bin/bash
# ================================================================
# PORTABLE UNCENSORED AI - MAC LAUNCHER
# ================================================================
# Just double-click this file on any Mac to start your portable AI.
# Everything runs from the USB drive. Nothing is installed on the Mac.
# ================================================================

# Move to the USB drive directory where this script lives
cd "$(dirname "$0")"

USB_DIR=$(pwd)
MAC_OLLAMA_DIR="$USB_DIR/ollama_mac"
DATA_DIR="$USB_DIR/ollama/data"

echo "==================================================="
echo "    Launching Portable AI Engine for Mac...      "
echo "==================================================="

# -----------------------------------------------------------------
# STEP 1: Download Mac Ollama Engine (first time only)
# -----------------------------------------------------------------
if [ ! -d "$MAC_OLLAMA_DIR/Ollama.app" ] && [ ! -f "$MAC_OLLAMA_DIR/ollama" ]; then
    echo "First time on Mac! Downloading the AI Engine..."
    mkdir -p "$MAC_OLLAMA_DIR"
    curl -L --progress-bar "https://github.com/ollama/ollama/releases/latest/download/ollama-darwin.zip" -o "$MAC_OLLAMA_DIR/ollama-darwin.zip"
    echo "Extracting..."
    unzip -o -q "$MAC_OLLAMA_DIR/ollama-darwin.zip" -d "$MAC_OLLAMA_DIR/"
    rm "$MAC_OLLAMA_DIR/ollama-darwin.zip"
    
    # Make executable
    if [ -f "$MAC_OLLAMA_DIR/Ollama.app/Contents/MacOS/Ollama" ]; then
        chmod +x "$MAC_OLLAMA_DIR/Ollama.app/Contents/MacOS/Ollama"
    elif [ -f "$MAC_OLLAMA_DIR/ollama" ]; then
        chmod +x "$MAC_OLLAMA_DIR/ollama"
    fi
    
    echo "Mac Engine Setup Complete!"
    echo ""
fi

# -----------------------------------------------------------------
# STEP 2: Download AnythingLLM (first time only, fully portable!)
# -----------------------------------------------------------------
if [ ! -d "$USB_DIR/anythingllm_mac/AnythingLLM.app" ]; then
    echo "First time setup: Downloading AnythingLLM directly to USB..."
    echo "NO installation on the Mac! Everything stays on the drive."
    mkdir -p "$USB_DIR/anythingllm_mac"

    # Select the correct build for this Mac's CPU — arm64 = Apple Silicon, x86_64 = Intel
    if [ "$(uname -m)" = "arm64" ]; then
        ANYTHINGLLM_DMG_URL="https://cdn.anythingllm.com/latest/AnythingLLMDesktop-Silicon.dmg"
    else
        ANYTHINGLLM_DMG_URL="https://cdn.anythingllm.com/latest/AnythingLLMDesktop.dmg"
    fi

    # Download the DMG
    curl -L --progress-bar "$ANYTHINGLLM_DMG_URL" -o "$USB_DIR/anythingllm_mac/AnythingLLM_Installer.dmg"
    
    echo "Extracting AnythingLLM to USB (please wait)..."
    # Mount the DMG silently and extract
    MOUNT_DIR=$(hdiutil attach -nobrowse "$USB_DIR/anythingllm_mac/AnythingLLM_Installer.dmg" | grep -o '/Volumes/.*')
    
    # Copy the app to the USB
    cp -R "$MOUNT_DIR/AnythingLLM.app" "$USB_DIR/anythingllm_mac/"
    
    # Clean up
    hdiutil detach "$MOUNT_DIR"
    rm "$USB_DIR/anythingllm_mac/AnythingLLM_Installer.dmg"
    
    # Remove Apple quarantine so it runs from USB without being blocked
    xattr -rc "$USB_DIR/anythingllm_mac/AnythingLLM.app"
    
    echo "AnythingLLM extracted and ready!"
fi

# -----------------------------------------------------------------
# STEP 3: Launch the AI Engine
# -----------------------------------------------------------------
echo ""
echo "Starting AI Engine from USB..."

# Brief RAM advisory — Ollama OOM exits silently, so warn early
_RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
_RAM_GB=$(( _RAM_BYTES / 1073741824 ))
if (( _RAM_GB > 0 && _RAM_GB < 4 )); then
    echo "WARNING: Only ${_RAM_GB} GB RAM detected. AI models need at least 4 GB."
elif (( _RAM_GB > 0 && _RAM_GB < 6 )); then
    echo "NOTE: ${_RAM_GB} GB RAM. 7B+ models need 6 GB; NemoMix 12B needs 8 GB."
fi
unset _RAM_BYTES _RAM_GB

# Lock all data paths to the USB drive
export OLLAMA_MODELS="$DATA_DIR"
export STORAGE_DIR="$USB_DIR/anythingllm_data"
mkdir -p "$STORAGE_DIR"

# -----------------------------------------------------------------
# ENSURE ANYTHINGLLM USES EXTERNAL OLLAMA (not built-in)
# -----------------------------------------------------------------
ENV_FILE="$STORAGE_DIR/storage/.env"
mkdir -p "$STORAGE_DIR/storage"

# Read first model
DEFAULT_MODEL="nemomix-local"
if [ -f "$USB_DIR/models/installed-models.txt" ]; then
    DEFAULT_MODEL=$(head -n 1 "$USB_DIR/models/installed-models.txt" | cut -d '|' -f 1)
fi

NEEDS_FIX=0
if [ ! -f "$ENV_FILE" ]; then
    NEEDS_FIX=1
elif ! grep -q "LLM_PROVIDER=ollama" "$ENV_FILE" || grep -q "LLM_PROVIDER=anythingllm_ollama" "$ENV_FILE"; then
    NEEDS_FIX=1
fi

if [ "$NEEDS_FIX" = "1" ]; then
    echo "Configuring AnythingLLM to use external Ollama engine..."
    cat > "$ENV_FILE" << EOF
LLM_PROVIDER=ollama
OLLAMA_BASE_PATH=http://127.0.0.1:11434
OLLAMA_MODEL_PREF=$DEFAULT_MODEL
OLLAMA_MODEL_TOKEN_LIMIT=4096
EMBEDDING_ENGINE=native
VECTOR_DB=lancedb
EOF
fi

# -------------------------------------------------------
# SHOW INSTALLED MODELS
# -------------------------------------------------------
if [ -f "$USB_DIR/models/installed-models.txt" ]; then
    echo ""
    echo "Installed models:"
    while IFS="|" read -r local_name nice_name tag; do
        if [ ! -z "$nice_name" ]; then
            echo "  - $nice_name [$tag]"
        fi
    done < "$USB_DIR/models/installed-models.txt"
    echo ""
fi

# Start Ollama in background
OLLAMA_PID=""
if [ -f "$MAC_OLLAMA_DIR/Ollama.app/Contents/MacOS/Ollama" ]; then
    "$MAC_OLLAMA_DIR/Ollama.app/Contents/MacOS/Ollama" serve > /dev/null 2>&1 &
    OLLAMA_PID=$!
elif [ -f "$MAC_OLLAMA_DIR/ollama" ]; then
    "$MAC_OLLAMA_DIR/ollama" serve > /dev/null 2>&1 &
    OLLAMA_PID=$!
else
    echo "Error: Could not find the Ollama binary on the USB drive!"
fi

# Poll until the API responds (up to 30 s) instead of a fixed sleep.
# If Ollama OOMs on start-up it exits before the timeout and we can explain why.
printf "Waiting for Ollama to be ready"
for _i in $(seq 1 30); do
    if curl -sf --max-time 1 "http://127.0.0.1:11434/api/tags" &>/dev/null; then
        echo " ready."
        break
    fi
    printf "."
    sleep 1
    if [ "$_i" -eq 30 ]; then
        echo " timeout."
        if [ -n "$OLLAMA_PID" ] && ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
            echo ""
            echo "ERROR: Ollama process exited before becoming ready."
            echo "This usually means insufficient RAM for the selected model."
            echo "NemoMix 12B requires at least 8 GB RAM; 7B models need at least 6 GB."
        fi
    fi
done
unset _i

echo ""
echo "==================================================="
echo "  SYSTEM ONLINE: Your AI is running from the USB!  "
echo "==================================================="
echo ""

# -----------------------------------------------------------------
# STEP 4: Launch AnythingLLM
# -----------------------------------------------------------------
echo ""
echo "Starting AI Interface from USB..."

# CRITICAL: We MUST wipe Electron path caches for true portability!
# This fixes the "JavaScript error" when moving USBs between different Macs.
[ -f "$STORAGE_DIR/config.json" ] && rm "$STORAGE_DIR/config.json"
[ -d "$STORAGE_DIR/Cache" ] && rm -rf "$STORAGE_DIR/Cache"
[ -d "$STORAGE_DIR/Code Cache" ] && rm -rf "$STORAGE_DIR/Code Cache"
[ -d "$STORAGE_DIR/GPUCache" ] && rm -rf "$STORAGE_DIR/GPUCache"

# Launch AnythingLLM from USB
echo "Opening AnythingLLM..."
open -a "$USB_DIR/anythingllm_mac/AnythingLLM.app" --args --user-data-dir="$STORAGE_DIR"

echo ""
echo "Keep this terminal open while you chat!"
echo "Press [ENTER] to shut down the AI safely."
echo ""

# Wait for user, then clean shutdown
read -p "Hit [ENTER] to turn off the Engine..."
kill $OLLAMA_PID 2>/dev/null
killall AnythingLLM 2>/dev/null
echo "AI shut down. You may safely eject the USB."
