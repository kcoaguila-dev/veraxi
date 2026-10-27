#!/usr/bin/env bash
# ==============================================================================
# Veraxi CLI (vx) Universal Installer
# Supports: Linux (Ubuntu/Debian/Fedora/Arch), macOS, and Android (Termux)
# ==============================================================================

set -e

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
DIM="\033[2m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}"
cat << "EOF"
  _   _                    _ 
 | | | | ___ _ __ __ ___  (_)
 | | | |/ _ \ '__/ _` \ \/ / |
  \ V /  __/ | | (_| |>  <| |
   \_/ \___|_|  \__,_/_/\_\_|
EOF
echo -e "   Veraxi Developer CLI (vx) Universal Installer${RESET}\n"

# 1. Environment Detection
IS_TERMUX=false
if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ] || [[ "$PREFIX" == *"com.termux"* ]]; then
    IS_TERMUX=true
fi

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

if [ "$IS_TERMUX" = true ]; then
    echo -e "${GREEN}✓${RESET} Detected Environment: ${BOLD}Android (Termux - ${ARCH_NAME})${RESET}"
    echo -e "${DIM}  Zero glibc/Rust C-extension dependencies required (Pure Python stdlib).${RESET}"
else
    echo -e "${GREEN}✓${RESET} Detected Environment: ${BOLD}${OS_NAME} (${ARCH_NAME})${RESET}"
fi

# 2. Dependency Verification (Python & Git)
if [ "$IS_TERMUX" = true ]; then
    if ! command -v python3 &> /dev/null || ! command -v git &> /dev/null; then
        echo -e "${YELLOW}!${RESET} Installing Python & Git via Termux package manager..."
        pkg update -y
        pkg install -y python git
    fi
else
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}✗ Error: python3 is not installed.${RESET}"
        echo -e "Please install Python 3.10+ and re-run this script."
        exit 1
    fi
fi

PYTHON_CMD="python3"
PY_VERSION=$($PYTHON_CMD -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo -e "${GREEN}✓${RESET} Python version: ${BOLD}${PY_VERSION}${RESET}"

# Verify Python >= 3.10
$PYTHON_CMD -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || {
    echo -e "${RED}✗ Python 3.10 or higher is required. Found Python ${PY_VERSION}.${RESET}"
    exit 1
}

# 3. Installation
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [ -f "${SCRIPT_DIR}/packages/veraxi-cli/pyproject.toml" ]; then
    echo -e "${CYAN}→${RESET} Installing from local repository..."
    $PYTHON_CMD -m pip install --upgrade --no-warn-script-location "${SCRIPT_DIR}/packages/veraxi-cli"
else
    echo -e "${CYAN}→${RESET} Installing from GitHub repository..."
    $PYTHON_CMD -m pip install --upgrade --no-warn-script-location "git+https://github.com/kcoaguila-dev/veraxi.git#subdirectory=packages/veraxi-cli"
fi

# 4. PATH Verification & Symlink
BIN_LOCATIONS=(
    "$HOME/.local/bin"
    "$PREFIX/bin"
    "/usr/local/bin"
)

FOUND_PATH=false
for DIR in "${BIN_LOCATIONS[@]}"; do
    if [[ ":$PATH:" == *":$DIR:"* ]]; then
        FOUND_PATH=true
        break
    fi
done

if [ "$FOUND_PATH" = false ]; then
    USER_SHELL="$(basename "$SHELL" 2>/dev/null || echo "bash")"
    RC_FILE="$HOME/.bashrc"
    if [ "$USER_SHELL" = "zsh" ]; then
        RC_FILE="$HOME/.zshrc"
    fi
    echo -e "${YELLOW}!${RESET} Adding ~/.local/bin to your PATH in ${RC_FILE}..."
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC_FILE"
    export PATH="$HOME/.local/bin:$PATH"
fi

# 5. Shell Auto-Completion Setup
if command -v vx &> /dev/null; then
    if [ "$IS_TERMUX" = true ] && [ -d "$PREFIX/etc/bash_completion.d" ]; then
        vx completion bash > "$PREFIX/etc/bash_completion.d/vx" 2>/dev/null || true
    fi
fi

# 6. Verification
echo -e "\n${BOLD}${GREEN}================================================================${RESET}"
echo -e "${BOLD}${GREEN}  Veraxi Developer CLI (vx) installed successfully!${RESET}"
echo -e "${BOLD}${GREEN}================================================================${RESET}\n"

echo -e "Quickstart Guide:"
echo -e "  1. Set your API Key:        ${CYAN}vx config set api_key <your_api_key>${RESET}"
echo -e "  2. Explore AI Models:       ${CYAN}vx models list${RESET}"
echo -e "  3. Select Default Model:    ${CYAN}vx models set gemini-2.0-flash${RESET}"
echo -e "  4. Check Environment:       ${CYAN}vx doctor${RESET}"
echo -e "  5. Ask Knowledge Assistant: ${CYAN}vx chat${RESET}\n"

if [ "$IS_TERMUX" = true ]; then
    echo -e "${DIM}Tip for Termux: Install termux-api with 'pkg install termux-api' for Android clipboard support.${RESET}\n"
fi
