#!/bin/bash
# Upload Assistant installer for SBIO/Swizzin Hosted
# https://github.com/wastaken7/Upload-Assistant
#
# Uses pyenv for Python 3.14 (the same approach as Upload Assistant's
# install-seedbox.sh) and adds a systemd user service for the WebUI.

mkdir -p "$HOME/.logs" "$HOME/.install" "$HOME/.tmp"
log="$HOME/.logs/upload-assistant.log"
touch "$log"
chmod 600 "$log" 2>/dev/null || true

export TMPDIR="$HOME/.tmp"
export PYENV_ROOT="$HOME/.local/opt/pyenv"
export PATH="$HOME/.local/bin:$PYENV_ROOT/bin:$PATH"

PYTHON_VERSION="3.14.0"
VENV="$HOME/.venv/upload-assistant"
UA_DIR="$HOME/scripts/Upload-Assistant"
UA_DATA_DIR="$HOME/.local/share/Upload-Assistant"
UA_CONFIG_DIR="$HOME/.config/upload-assistant"
UA_BIN="$HOME/.local/bin/ua"
SERVICE="$HOME/.config/systemd/user/upload-assistant.service"
LOCK="$HOME/.install/.upload-assistant.lock"
DEV_TARBALL="https://github.com/wastaken7/Upload-Assistant/archive/refs/heads/development.tar.gz"

function port() {
    ## Generating a random unused port
    LOW_BOUND=$1
    UPPER_BOUND=$2
    comm -23 <(seq "${LOW_BOUND}" "${UPPER_BOUND}" | sort) <(ss -Htan | awk '{print $4}' | sed 's/.*://' | sort -u) | shuf | head -n 1
}

function _die() {
    echo ""
    echo "$1"
    echo "Check the log at ${log} for details."
    exit 1
}

function _add_bashrc() {
    local line="$1"
    if [[ ! -f "$HOME/.bashrc" ]]; then
        touch "$HOME/.bashrc"
    fi
    grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >> "$HOME/.bashrc"
}

function _deps() {
    local cmd
    for cmd in git curl tar xz; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            _die "Required command not found: ${cmd}. Please ask your provider to install it."
        fi
    done

    # shellcheck disable=SC2016
    _add_bashrc 'export PATH="$HOME/.local/bin:$PATH"'

    if [[ ! -d "$PYENV_ROOT" ]]; then
        echo "Installing pyenv..."
        mkdir -p "$HOME/.local/opt"
        git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT" >> "$log" 2>&1 || {
            _die "Failed to clone pyenv."
        }
    elif [[ ! -d "$PYENV_ROOT/.git" ]]; then
        _die "${PYENV_ROOT} exists but is not a pyenv checkout."
    fi

    if [[ ! -d "$PYENV_ROOT/plugins/pyenv-virtualenv" ]]; then
        git clone https://github.com/pyenv/pyenv-virtualenv.git "$PYENV_ROOT/plugins/pyenv-virtualenv" >> "$log" 2>&1 || true
    fi
    if [[ ! -d "$PYENV_ROOT/plugins/pyenv-update" ]]; then
        git clone https://github.com/pyenv/pyenv-update.git "$PYENV_ROOT/plugins/pyenv-update" >> "$log" 2>&1 || true
    fi

    # shellcheck disable=SC2016
    _add_bashrc 'export PYENV_ROOT="$HOME/.local/opt/pyenv"'
    # shellcheck disable=SC2016
    _add_bashrc 'export PATH="$PYENV_ROOT/bin:$PATH"'

    if [[ ! -x "$PYENV_ROOT/versions/${PYTHON_VERSION}/bin/python3" ]]; then
        for cmd in gcc make; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                _die "Required build command not found: ${cmd}. Please ask your provider to install it before compiling Python."
            fi
        done

        echo "Updating pyenv definitions..."
        git -C "$PYENV_ROOT" pull --ff-only >> "$log" 2>&1 || true

        echo "Compiling Python ${PYTHON_VERSION}. This may take 10-20+ minutes..."
        if ! "$PYENV_ROOT/bin/pyenv" install "$PYTHON_VERSION" >> "$log" 2>&1; then
            tail -n 25 "$log"
            _die "Failed to compile Python ${PYTHON_VERSION}."
        fi
        echo "Python ${PYTHON_VERSION} installed."
    else
        echo "Python ${PYTHON_VERSION} is already installed."
    fi

    if ! "$PYENV_ROOT/versions/${PYTHON_VERSION}/bin/python3" -c 'import ssl' >/dev/null 2>&1; then
        _die "Python ${PYTHON_VERSION} was built without SSL support. Ask your provider to install the OpenSSL development headers (libssl-dev) and rerun this installer."
    fi

    mkdir -p "$HOME/.venv"
    if [[ -x "$VENV/bin/python" ]]; then
        local venv_version
        venv_version=$("$VENV/bin/python" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null)
        if [[ "$venv_version" != "$PYTHON_VERSION" ]]; then
            echo "Existing virtualenv uses Python ${venv_version}; recreating it."
            rm -rf "$VENV"
        fi
    fi

    if [[ ! -x "$VENV/bin/python" ]]; then
        echo "Creating virtualenv..."
        "$PYENV_ROOT/versions/${PYTHON_VERSION}/bin/python3" -m venv "$VENV" >> "$log" 2>&1 || {
            _die "Failed to create the virtualenv."
        }
    fi

    echo "Updating pip and wheel..."
    "$VENV/bin/python" -m pip install --upgrade pip wheel >> "$log" 2>&1 || {
        _die "Failed to update pip/wheel."
    }
}

function _ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 \
        && ffmpeg -version >/dev/null 2>&1 && ffprobe -version >/dev/null 2>&1; then
        echo "Using ffmpeg: $(command -v ffmpeg)"
        return 0
    fi

    local asset
    case "$(uname -m)" in
        x86_64|amd64) asset="ffmpeg-master-latest-linux64-gpl.tar.xz" ;;
        aarch64|arm64) asset="ffmpeg-master-latest-linuxarm64-gpl.tar.xz" ;;
        *)
            echo "ffmpeg is missing and architecture $(uname -m) is not supported by the static fallback."
            return 1
            ;;
    esac

    echo "ffmpeg/ffprobe not found. Downloading a static build (about 150 MB)..."
    mkdir -p "$HOME/.local/opt/ffmpeg" "$HOME/.local/bin"
    local archive="$TMPDIR/${asset}"

    if ! curl -fsSL "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/${asset}" -o "$archive" >> "$log" 2>&1; then
        rm -f "$archive"
        echo "Failed to download ffmpeg."
        return 1
    fi

    rm -rf "${HOME:?}/.local/opt/ffmpeg/"*
    if ! tar -xJf "$archive" -C "$HOME/.local/opt/ffmpeg" --strip-components=1 >> "$log" 2>&1; then
        rm -f "$archive"
        echo "Failed to extract ffmpeg."
        return 1
    fi
    rm -f "$archive"

    ln -sfn "$HOME/.local/opt/ffmpeg/bin/ffmpeg" "$HOME/.local/bin/ffmpeg"
    ln -sfn "$HOME/.local/opt/ffmpeg/bin/ffprobe" "$HOME/.local/bin/ffprobe"

    if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1 \
        || ! ffmpeg -version >/dev/null 2>&1 || ! ffprobe -version >/dev/null 2>&1; then
        echo "Static ffmpeg was installed but is not usable."
        return 1
    fi

    echo "Static ffmpeg installed."
}

function _install_stable() {
    echo "Installing the latest stable Upload Assistant release..."
    if ! "$VENV/bin/python" -m pip install --upgrade upload-assistant >> "$log" 2>&1; then
        echo "Failed to install the stable Upload Assistant release."
        return 1
    fi
}

function _install_dev() {
    echo "Downloading the Upload Assistant development branch..."
    mkdir -p "$HOME/scripts"
    local tmp_dir="$TMPDIR/ua-dev-$$"

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    if ! curl -fsSL "$DEV_TARBALL" -o "$tmp_dir/ua-dev.tar.gz" >> "$log" 2>&1; then
        rm -rf "$tmp_dir"
        echo "Failed to download the development branch."
        return 1
    fi

    rm -rf "$UA_DIR"
    mkdir -p "$UA_DIR"
    if ! tar -xzf "$tmp_dir/ua-dev.tar.gz" -C "$UA_DIR" --strip-components=1 >> "$log" 2>&1; then
        rm -rf "$tmp_dir" "$UA_DIR"
        echo "Failed to extract the development branch."
        return 1
    fi
    rm -rf "$tmp_dir"

    echo "Installing Upload Assistant from the development branch..."
    if ! "$VENV/bin/python" -m pip install --upgrade --force-reinstall "$UA_DIR" >> "$log" 2>&1; then
        echo "Failed to install the development branch."
        return 1
    fi
}

function _install_app() {
    local channel=$1

    case "$channel" in
        stable) _install_stable || return 1 ;;
        development) _install_dev || return 1 ;;
        *)
            echo "Unknown install channel: ${channel}"
            return 1
            ;;
    esac

    mkdir -p "$HOME/.local/bin"
    ln -sfn "$VENV/bin/ua" "$UA_BIN"

    if ! "$VENV/bin/ua" --help >/dev/null 2>&1; then
        echo "Upload Assistant was installed but 'ua --help' failed."
        return 1
    fi
}

function _normalize_roots() {
    local input=$1
    local -a roots
    local root
    local -a clean_roots=()

    IFS=',' read -r -a roots <<< "$input"
    for root in "${roots[@]}"; do
        root="${root#"${root%%[![:space:]]*}"}"
        root="${root%"${root##*[![:space:]]}"}"
        [[ -z "$root" ]] && continue

        if [[ "$root" == "~" ]]; then
            root="$HOME"
        elif [[ "${root:0:1}" == "~" && "${root:1:1}" == "/" ]]; then
            root="$HOME/${root:2}"
        fi
        [[ "$root" != /* ]] && root="$HOME/$root"
        [[ -d "$root" ]] || echo "Warning: ${root} does not exist. Upload Assistant cannot browse it until it does." >&2

        clean_roots+=("$root")
    done

    if [[ ${#clean_roots[@]} -eq 0 ]]; then
        clean_roots=("$HOME")
    fi

    (IFS=','; echo "${clean_roots[*]}")
}

function _browse_roots() {
    local qb_conf="$HOME/.config/qBittorrent/qBittorrent.conf"
    local default_root="$HOME"
    local qb_save=""

    if [[ -f "$qb_conf" ]]; then
        qb_save=$(grep -m1 '^Downloads\\SavePath=' "$qb_conf" 2>/dev/null | cut -d= -f2-)
        if [[ -z "$qb_save" ]]; then
            qb_save=$(grep -m1 '^Session\\DefaultSavePath=' "$qb_conf" 2>/dev/null | cut -d= -f2-)
        fi
        if [[ -n "$qb_save" ]]; then
            if [[ "$qb_save" == "~" ]]; then
                qb_save="$HOME"
            elif [[ "${qb_save:0:1}" == "~" && "${qb_save:1:1}" == "/" ]]; then
                qb_save="$HOME/${qb_save:2}"
            fi
            [[ "$qb_save" != /* ]] && qb_save="$HOME/$qb_save"
            [[ -d "$qb_save" ]] && default_root="$qb_save"
        fi
    fi

    echo "" >&2
    echo "Upload Assistant can only browse directories listed in UA_BROWSE_ROOTS." >&2
    echo "Enter one or more paths separated by commas." >&2
    read -r -p "Browse roots [${default_root}]: " roots
    roots=${roots:-$default_root}

    _normalize_roots "$roots"
}

function _service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        _die "systemctl was not found. This installer requires systemd user services."
    fi
    if ! command -v ss >/dev/null 2>&1; then
        _die "The 'ss' command was not found. Please ask your provider to install iproute2."
    fi

    local app_port
    app_port=$(port 10000 14000)
    if [[ -z "$app_port" ]]; then
        _die "Could not find a free port in the 10000-14000 range."
    fi

    local roots
    roots=$(_browse_roots)
    local safe_roots="${roots//\\/\\\\}"
    safe_roots="${safe_roots//\"/\\\"}"
    safe_roots="${safe_roots//%/%%}"

    echo "Installing systemd user service..."
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$SERVICE" << EOF
[Unit]
Description=Upload Assistant WebUI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
UMask=0077
WorkingDirectory=$HOME
Environment=HOME=$HOME
Environment=XDG_CONFIG_HOME=$HOME/.config
Environment=PATH=$HOME/.local/bin:$VENV/bin:/usr/local/bin:/usr/bin:/bin
Environment=UA_DATA_DIR=$UA_DATA_DIR
Environment="UA_BROWSE_ROOTS=$safe_roots"
Environment=TMPDIR=$HOME/.tmp
Environment=PYTHONUNBUFFERED=1
ExecStart=$VENV/bin/ua --webui 0.0.0.0:$app_port
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=append:$log
StandardError=append:$log

[Install]
WantedBy=default.target
EOF

    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$(id -un)" >> "$log" 2>&1 || true
    fi

    local log_start
    log_start=$(wc -l < "$log")

    systemctl --user daemon-reload >> "$log" 2>&1 || true
    if ! systemctl --user enable --now upload-assistant.service >> "$log" 2>&1; then
        systemctl --user status upload-assistant.service --no-pager >> "$log" 2>&1 || true
        tail -n 25 "$log"
        _die "Failed to enable and start upload-assistant.service."
    fi

    local _
    for _ in $(seq 1 30); do
        systemctl --user is-active --quiet upload-assistant.service && break
        sleep 1
    done
    if ! systemctl --user is-active --quiet upload-assistant.service; then
        systemctl --user status upload-assistant.service --no-pager >> "$log" 2>&1 || true
        tail -n 25 "$log"
        _die "upload-assistant.service did not stay running."
    fi

    local _
    for _ in $(seq 1 10); do
        [[ -f "$UA_CONFIG_DIR/webui_auth.json" ]] && break
        tail -n "+$((log_start + 1))" "$log" 2>/dev/null | grep -qi 'setup code' && break
        sleep 1
    done

    local domain
    domain=$(hostname -f 2>/dev/null)
    [[ -z "$domain" ]] && domain=$(hostname)
    local setup_code=""
    if [[ ! -f "$UA_CONFIG_DIR/webui_auth.json" ]]; then
        setup_code=$(tail -n "+$((log_start + 1))" "$log" 2>/dev/null | sed -E $'s/\x1b\\[[0-9;]*[mK]//g' | grep -i 'setup code' | tail -n 1 | sed -E 's/.*[Ss]etup code:[[:space:]]*//')
    fi

    echo ""
    echo "Upload Assistant is installed and running."
    echo "WebUI: http://${domain}:${app_port}/"
    if [[ -n "$setup_code" ]]; then
        echo "First-run setup code: ${setup_code}"
    elif [[ -f "$UA_CONFIG_DIR/webui_auth.json" ]]; then
        echo "WebUI account is already configured."
    else
        echo "No first-run setup code was printed by this release."
        echo "Stable releases currently let the first WebUI visitor create the account."
        echo "Open the WebUI now and create your account before sharing the URL."
        echo "For the console-only setup code, use the install-dev option."
        echo "You can also check: grep -i 'setup code' ${log} | tail -n 1"
    fi
    echo "Browse roots: ${roots}"
    echo "Config: ${UA_DATA_DIR}/data/config.py"
    echo "WebUI account data: ${UA_CONFIG_DIR}"
    echo "Logs: ${log}"
    echo "Service: systemctl --user status upload-assistant"

    local qb_conf="$HOME/.config/qBittorrent/qBittorrent.conf"
    if [[ -f "$qb_conf" ]]; then
        local qb_port
        qb_port=$(grep -m1 '^WebUI\\Port=' "$qb_conf" 2>/dev/null | cut -d= -f2-)
        if [[ -n "$qb_port" ]]; then
            echo "Detected qBittorrent WebUI port: ${qb_port}"
        fi
    fi
    if [[ -d "$HOME/.local/share/qBittorrent/BT_backup" ]]; then
        echo "qBittorrent BT_backup: ${HOME}/.local/share/qBittorrent/BT_backup"
    fi

    echo ""
    echo "WARNING: The WebUI is served over plain HTTP. Do not expose it to the internet"
    echo "without a VPN or reverse proxy. See tailscale.sh and cloudflared.sh in this repo."
}

function _install() {
    local channel=$1

    if [[ -f "$LOCK" ]]; then
        echo "Upload Assistant is already installed. Use 'upgrade' instead, or uninstall first to switch installation channels."
        exit 0
    fi

    _deps

    if ! _ffmpeg; then
        echo "Warning: ffmpeg is not available. Uploads that need screenshots will fail until it is installed."
    fi

    if ! _install_app "$channel"; then
        _die "Failed to install Upload Assistant."
    fi

    _service

    echo "channel=${channel}" > "$LOCK"
    echo ""
    echo "Installation complete."
}

function _upgrade() {
    if [[ ! -f "$LOCK" ]]; then
        echo "Upload Assistant is not installed."
        exit 0
    fi

    local channel
    channel=$(sed -n 's/^channel=//p' "$LOCK" 2>/dev/null | head -n 1)
    [[ -z "$channel" ]] && channel="stable"

    _deps

    if ! _ffmpeg; then
        echo "Warning: ffmpeg is not available. Uploads that need screenshots will fail until it is installed."
    fi

    echo "Stopping upload-assistant.service..."
    systemctl --user stop upload-assistant.service >> "$log" 2>&1 || true

    if ! _install_app "$channel"; then
        echo "Upgrade failed. Attempting to restart the previous installation..."
        systemctl --user start upload-assistant.service >> "$log" 2>&1 || true
        _die "Upgrade failed."
    fi

    systemctl --user daemon-reload >> "$log" 2>&1 || true
    if ! systemctl --user start upload-assistant.service >> "$log" 2>&1; then
        systemctl --user status upload-assistant.service --no-pager >> "$log" 2>&1 || true
        tail -n 25 "$log"
        _die "Upload Assistant was upgraded but the service failed to start."
    fi

    sleep 2
    if ! systemctl --user is-active --quiet upload-assistant.service; then
        systemctl --user status upload-assistant.service --no-pager >> "$log" 2>&1 || true
        tail -n 25 "$log"
        _die "upload-assistant.service did not stay running after the upgrade."
    fi

    local app_port=""
    if [[ -f "$SERVICE" ]]; then
        app_port=$(sed -n 's/.*--webui 0\.0\.0\.0:\([0-9]*\).*/\1/p' "$SERVICE" | head -n 1)
    fi

    local domain
    domain=$(hostname -f 2>/dev/null)
    [[ -z "$domain" ]] && domain=$(hostname)

    echo "Upgrade complete."
    if [[ -n "$app_port" ]]; then
        echo "WebUI: http://${domain}:${app_port}/"
    fi
}

function _remove() {
    if [[ ! -f "$LOCK" && ! -f "$SERVICE" ]]; then
        echo "Upload Assistant is not installed."
        exit 0
    fi

    echo "Removing Upload Assistant..."
    systemctl --user disable --now upload-assistant.service >> "$log" 2>&1 || true
    rm -f "$SERVICE"
    systemctl --user daemon-reload >> "$log" 2>&1 || true
    systemctl --user reset-failed upload-assistant.service >> "$log" 2>&1 || true

    if [[ -L "$UA_BIN" ]]; then
        local target
        target=$(readlink "$UA_BIN")
        if [[ "$target" == "$VENV/bin/ua" ]]; then
            rm -f "$UA_BIN"
        fi
    fi

    if [[ -x "$VENV/bin/python" ]]; then
        "$VENV/bin/python" -m pip uninstall -y upload-assistant >> "$log" 2>&1 || true
    fi

    rm -rf "$VENV"
    rm -rf "$UA_DIR"
    rm -f "$LOCK"

    local purge
    read -r -p "Also delete Upload Assistant configuration, WebUI account, and cached data? [y/N]: " purge
    case "$purge" in
        y|Y|yes|YES)
            rm -rf "$UA_DATA_DIR"
            rm -rf "$UA_CONFIG_DIR"
            echo "Configuration and WebUI account data removed."
            ;;
        *)
            echo "Configuration kept at ${UA_DATA_DIR}"
            echo "WebUI account data kept at ${UA_CONFIG_DIR}"
            ;;
    esac

    echo "Upload Assistant has been removed."
    echo "Python ${PYTHON_VERSION} was left installed for other applications."
    echo "Remove it with: ${PYENV_ROOT}/bin/pyenv uninstall ${PYTHON_VERSION}"
    echo "Static ffmpeg, if installed, was left at ${HOME}/.local/opt/ffmpeg"
}

echo "This is unsupported software. You will not get help with this, please answer \`yes\` if you understand and wish to proceed"
if [[ -z ${eula} ]]; then
    read -r eula
fi

if ! [[ $eula =~ yes ]]; then
    echo "You did not accept the above. Exiting..."
    exit 1
else
    echo "Proceeding with installation"
fi

echo ""
echo "Welcome to the Upload Assistant installer..."
echo ""
echo "What would you like to do?"
echo "Logs are stored at ${log}"
echo "install = Install the latest stable release"
echo "install-dev = Install the development branch (includes the console setup code)"
echo "upgrade = Upgrade an existing installation"
echo "uninstall = Completely removes Upload Assistant"
echo "exit = Exits Installer"
echo ""

while true; do
    read -r -p "Enter it here: " choice
    case $choice in
        "install")
            _install stable
            break
            ;;
        "install-dev")
            _install development
            break
            ;;
        "upgrade")
            _upgrade
            break
            ;;
        "uninstall")
            _remove
            break
            ;;
        "exit")
            break
            ;;
        *)
            echo "Unknown Option."
            ;;
    esac
done
exit
