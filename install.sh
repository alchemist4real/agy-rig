#!/usr/bin/env bash
# ============================================================================
# AGY RIG — Universal Installer for macOS and Linux
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/alchemist4real/agy-rig/main/install.sh | bash
# ============================================================================

set -e

# Colors
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_RESET='\033[0m'

echo -e "\n${C_YELLOW}================================================================${C_RESET}"
echo -e "${C_YELLOW}   ___   _______  __   ___  ________  ${C_RESET}"
echo -e "${C_YELLOW}  / _ | / ___/\\ \\/ /  / _ \\/  _/ ___/  ${C_RESET}"
echo -e "${C_YELLOW} / __ |/ (_ /  \\  /  / , _// // (_ /   ${C_RESET}"
echo -e "${C_YELLOW}/_/ |_|\\___/   /_/  /_/|_|/___/\\___/    ${C_RESET}"
echo -e "${C_YELLOW}================================================================${C_RESET}"
echo -e " AGY RIG — Universal Installer for macOS & Linux"
echo -e "${C_YELLOW}================================================================${C_RESET}\n"

# 1. Detect Environment
OS_TYPE="$(uname -s)"
ARCH_TYPE="$(uname -m)"
echo -e "  ${C_CYAN}[1/5]${C_RESET} Detecting system: ${OS_TYPE} (${ARCH_TYPE})..."

# 2. Check Prerequisites
echo -e "  ${C_CYAN}[2/5]${C_RESET} Verifying prerequisites..."
if ! command -v python3 >/dev/null 2>&1; then
    echo -e "  ${C_RED}[ERROR] Python 3 is required but not found.${C_RESET}"
    echo -e "  Please install Python 3 using your package manager:"
    if [ "${OS_TYPE}" = "Darwin" ]; then
        echo -e "    ${C_CYAN}brew install python3${C_RESET}"
    elif command -v apt >/dev/null 2>&1; then
        echo -e "    ${C_CYAN}sudo apt update && sudo apt install -y python3${C_RESET}"
    elif command -v dnf >/dev/null 2>&1; then
        echo -e "    ${C_CYAN}sudo dnf install -y python3${C_RESET}"
    elif command -v pacman >/dev/null 2>&1; then
        echo -e "    ${C_CYAN}sudo pacman -S python${C_RESET}"
    else
        echo -e "    Install Python 3 from https://www.python.org"
    fi
    exit 1
fi

PY_VER="$(python3 --version 2>&1)"
echo -e "        Python: ${C_GREEN}${PY_VER}${C_RESET}"

if command -v git >/dev/null 2>&1; then
    echo -e "        Git:    ${C_GREEN}$(git --version 2>&1)${C_RESET}"
else
    echo -e "        Git:    ${C_YELLOW}Not found (curl fallback enabled)${C_RESET}"
fi

# 3. Target Paths
INSTALL_DIR="${HOME}/.local/share/agy-rig"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/agy-rig"

mkdir -p "${INSTALL_DIR}"
mkdir -p "${BIN_DIR}"
mkdir -p "${CONFIG_DIR}/accounts"
mkdir -p "${CONFIG_DIR}/credits"
mkdir -p "${HOME}/.gemini/antigravity/profiles"

# 4. Download Engine with Retries
echo -e "  ${C_CYAN}[3/5]${C_RESET} Installing AGY RIG engine into ${INSTALL_DIR}..."
REPO_URL="https://raw.githubusercontent.com/alchemist4real/agy-rig/main/agy-rig"
TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/agy-rig-dl.XXXXXX")"
trap 'rm -f "${TEMP_FILE}"' EXIT INT TERM

MAX_RETRIES=3
DOWNLOADED=false

for attempt in $(seq 1 ${MAX_RETRIES}); do
    echo -e "        Downloading engine (attempt ${attempt}/${MAX_RETRIES})..."
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --connect-timeout 15 --max-time 60 "${REPO_URL}" -o "${TEMP_FILE}"; then
            DOWNLOADED=true
            break
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --timeout=60 -O "${TEMP_FILE}" "${REPO_URL}"; then
            DOWNLOADED=true
            break
        fi
    else
        echo -e "  ${C_RED}[ERROR] curl or wget is required to download AGY RIG.${C_RESET}"
        exit 1
    fi
    [ "${attempt}" -lt "${MAX_RETRIES}" ] && sleep 2
done

if [ "${DOWNLOADED}" != true ] || [ ! -s "${TEMP_FILE}" ]; then
    echo -e "  ${C_RED}[ERROR] Failed to download AGY RIG from GitHub.${C_RESET}"
    exit 1
fi

mv -f "${TEMP_FILE}" "${INSTALL_DIR}/agy-rig"
chmod +x "${INSTALL_DIR}/agy-rig"
ln -sf "${INSTALL_DIR}/agy-rig" "${BIN_DIR}/agy-rig"
ln -sf "${INSTALL_DIR}/agy-rig" "${BIN_DIR}/agy-switch"

echo -e "        Symlinked ${C_GREEN}${BIN_DIR}/agy-rig${C_RESET}"

# 5. Shell PATH Configuration
echo -e "  ${C_CYAN}[4/5]${C_RESET} Checking PATH configuration..."

NEED_PATH_EXPORT=true
case ":$PATH:" in
    *":${BIN_DIR}:"*) NEED_PATH_EXPORT=false ;;
esac

if [ "${NEED_PATH_EXPORT}" = true ]; then
    SHELL_CONFIG=""
    if [ -f "${HOME}/.zshrc" ]; then
        SHELL_CONFIG="${HOME}/.zshrc"
    elif [ -f "${HOME}/.bashrc" ]; then
        SHELL_CONFIG="${HOME}/.bashrc"
    elif [ -f "${HOME}/.profile" ]; then
        SHELL_CONFIG="${HOME}/.profile"
    fi

    if [ -n "${SHELL_CONFIG}" ]; then
        if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "${SHELL_CONFIG}"; then
            echo -e '\n# AGY RIG PATH\nexport PATH="$HOME/.local/bin:$PATH"' >> "${SHELL_CONFIG}"
            echo -e "        Added ~/.local/bin to ${C_GREEN}${SHELL_CONFIG}${C_RESET}"
        fi
    fi
    export PATH="${BIN_DIR}:${PATH}"
fi

# 6. Verification
echo -e "  ${C_CYAN}[5/5]${C_RESET} Verifying installation..."
"${BIN_DIR}/agy-rig" help >/dev/null 2>&1

echo -e "\n${C_GREEN}================================================================${C_RESET}"
echo -e "${C_GREEN}   AGY RIG INSTALLED SUCCESSFULLY!${C_RESET}"
echo -e "${C_GREEN}================================================================${C_RESET}\n"
echo -e "  To get started:"
echo -e "    ${C_CYAN}agy-rig scan${C_RESET}         # Scan existing credentials & tokens"
echo -e "    ${C_CYAN}agy-rig quota${C_RESET}        # Check live model usage & limits"
echo -e "    ${C_CYAN}agy-rig list${C_RESET}         # View saved accounts"
echo -e "    ${C_CYAN}agy-rig login${C_RESET}        # Add new account via browser PKCE"
echo -e "    ${C_CYAN}agy-rig help${C_RESET}         # Show complete command reference\n"

if [ "${NEED_PATH_EXPORT}" = true ] && [ -n "${SHELL_CONFIG}" ]; then
    echo -e "  ${C_YELLOW}Note: Run 'source ${SHELL_CONFIG}' or restart your terminal to reload PATH.${C_RESET}\n"
fi
