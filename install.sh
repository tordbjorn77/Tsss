#!/usr/bin/env bash
# =============================================================================
#  Tsss Installer
#  Installs Erlang/OTP, rebar3, builds the application, and drops a
#  ready-to-run `tsss` command in the project directory.
#
#  One-liner (fresh machine, no Erlang needed):
#    curl -fsSL https://raw.githubusercontent.com/tordbjorn77/Tsss/main/install.sh | bash
#
#  Or, if you have already cloned the repo:
#    bash install.sh
# =============================================================================
set -euo pipefail

# ─── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[tsss]${NC} $*"; }
ok()   { echo -e "${GREEN}[tsss]${NC} $*"; }
warn() { echo -e "${YELLOW}[tsss]${NC} $*"; }
die()  { echo -e "${RED}[tsss] ERROR:${NC} $*" >&2; exit 1; }

# ─── configuration ────────────────────────────────────────────────────────────
REPO_URL="https://github.com/tordbjorn77/Tsss"
OTP_MIN=24
REBAR3_VERSION="3.23.0"
INSTALL_DIR="${TSSS_INSTALL_DIR:-$HOME/.tsss}"

# ─── helpers ──────────────────────────────────────────────────────────────────
need_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1. Please install it and retry."; }

otp_vsn() {
    erl -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)]),halt()' 2>/dev/null \
        | tr -d '\n' || echo "0"
}

version_ge() {
    # true if $1 >= $2 (numeric comparison)
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ─── OS detection ─────────────────────────────────────────────────────────────
detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    DISTRO="unknown"
    DISTRO_LIKE=""
    case "$OS" in
        Darwin)
            PLATFORM="macos"
            ;;
        Linux)
            PLATFORM="linux"
            if [ -f /etc/os-release ]; then
                # shellcheck source=/dev/null
                . /etc/os-release
                DISTRO="${ID:-unknown}"
                DISTRO_LIKE="${ID_LIKE:-}"
            fi
            ;;
        *)
            die "Unsupported OS: $OS. Only macOS and Linux are supported."
            ;;
    esac
}

# ─── Erlang/OTP installation ──────────────────────────────────────────────────
install_erlang_macos() {
    if ! command -v brew &>/dev/null; then
        log "Homebrew not found. Installing Homebrew first..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [ "$ARCH" = "arm64" ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
    log "Installing Erlang via Homebrew (this may take a few minutes)..."
    brew install erlang
}

install_erlang_debian() {
    log "Adding Erlang Solutions repository and installing Erlang..."
    curl -fsSL https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb \
        -o /tmp/erlang-solutions.deb
    sudo dpkg -i /tmp/erlang-solutions.deb
    sudo apt-get update -q
    sudo apt-get install -y erlang
    rm -f /tmp/erlang-solutions.deb
}

install_erlang_rhel() {
    log "Installing Erlang via dnf/yum (Erlang Solutions)..."
    if command -v dnf &>/dev/null; then
        sudo dnf install -y erlang
    else
        sudo yum install -y erlang
    fi
}

install_erlang_arch() {
    log "Installing Erlang via pacman..."
    sudo pacman -Sy --noconfirm erlang
}

install_erlang_asdf() {
    log "Falling back to asdf for Erlang (compiles from source; ~10 min)..."
    if ! command -v asdf &>/dev/null; then
        log "Installing asdf version manager..."
        git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch v0.14.0 2>/dev/null \
            || git -C "$HOME/.asdf" pull
        # shellcheck source=/dev/null
        . "$HOME/.asdf/asdf.sh"
    fi
    asdf plugin add erlang 2>/dev/null || true
    OTP_TARGET="27.0"
    log "Compiling OTP $OTP_TARGET..."
    asdf install erlang "$OTP_TARGET"
    asdf global erlang "$OTP_TARGET"
    # shellcheck source=/dev/null
    . "$HOME/.asdf/asdf.sh"
}

ensure_erlang() {
    local current
    current="$(otp_vsn)"
    if version_ge "$current" "$OTP_MIN" 2>/dev/null; then
        ok "Erlang/OTP $current already installed (minimum: $OTP_MIN)."
        return
    fi

    warn "Erlang/OTP $OTP_MIN+ not found (found: '$current'). Installing..."

    case "$PLATFORM" in
        macos) install_erlang_macos ;;
        linux)
            case "$DISTRO" in
                ubuntu|debian|pop|linuxmint|raspbian)
                    install_erlang_debian ;;
                fedora|rhel|centos|rocky|almalinux)
                    install_erlang_rhel ;;
                arch|manjaro|endeavouros)
                    install_erlang_arch ;;
                *)
                    if command -v apt-get &>/dev/null; then
                        install_erlang_debian
                    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
                        install_erlang_rhel
                    else
                        install_erlang_asdf
                    fi
                    ;;
            esac
            ;;
    esac

    current="$(otp_vsn)"
    version_ge "$current" "$OTP_MIN" \
        || die "Erlang/OTP installation failed. Install OTP $OTP_MIN+ manually: https://www.erlang.org/downloads"
    ok "Erlang/OTP $current installed."
}

# ─── rebar3 ───────────────────────────────────────────────────────────────────
ensure_rebar3() {
    if command -v rebar3 &>/dev/null; then
        ok "rebar3 already installed ($(rebar3 --version 2>/dev/null | head -1))."
        return
    fi

    log "Installing rebar3 $REBAR3_VERSION..."
    local dest="$HOME/.local/bin/rebar3"
    mkdir -p "$HOME/.local/bin"
    curl -fsSL "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
        -o "$dest"
    chmod +x "$dest"
    export PATH="$HOME/.local/bin:$PATH"

    for profile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$profile" ] && ! grep -q '\.local/bin' "$profile"; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$profile"
            warn "Added ~/.local/bin to PATH in $profile (restart shell to persist)"
        fi
    done
    ok "rebar3 installed at $dest."
}

# ─── Clone or locate source ───────────────────────────────────────────────────
get_source() {
    # If run locally from within the repo, skip cloning.
    if [ -f "$(pwd)/rebar.config" ] && [ -d "$(pwd)/src" ]; then
        REPO_DIR="$(pwd)"
        log "Using existing source at $REPO_DIR"
        return
    fi

    REPO_DIR="$INSTALL_DIR/src"
    if [ -d "$REPO_DIR/.git" ]; then
        log "Updating existing checkout at $REPO_DIR..."
        git -C "$REPO_DIR" pull --ff-only
    else
        log "Cloning Tsss into $REPO_DIR..."
        mkdir -p "$INSTALL_DIR"
        git clone "$REPO_URL" "$REPO_DIR"
    fi
    cd "$REPO_DIR"
}

# ─── Build ────────────────────────────────────────────────────────────────────
build() {
    log "Fetching dependencies and compiling..."
    rebar3 compile

    log "Building production release..."
    rebar3 as prod release

    ok "Build complete."
}

# ─── Write the `tsss` wrapper script ─────────────────────────────────────────
write_wrapper() {
    local wrapper="$REPO_DIR/tsss"

    cat > "$wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# tsss — convenience wrapper for the Tsss messaging system
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL_BIN="$SCRIPT_DIR/_build/prod/rel/tsss/bin/tsss"
EBIN_GLOB="$SCRIPT_DIR/_build/default/lib/*/ebin"

usage() {
    cat <<EOF
Usage: tsss <command> [options]

Commands:
  start             Start a Tsss node in the background
  stop              Stop the running node
  console           Start a node with an interactive Erlang shell
  shell             Attach to a running node's shell
  status            Check if the node is running
  demo              Run a guided interactive demo (no extra setup needed)
  cluster <N>       Start N local nodes on this machine (default: 3)
  help              Show this help

Options (for start / console):
  --name   <name>   Erlang node name  (default: tsss@127.0.0.1)
  --cookie <cookie> Erlang cookie     (default: tsss_secret_cookie)
EOF
}

CMD="${1:-help}"
shift || true

NODE_NAME="tsss@127.0.0.1"
COOKIE="tsss_secret_cookie"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)   NODE_NAME="$2"; shift 2 ;;
        --cookie) COOKIE="$2";    shift 2 ;;
        *)        break ;;
    esac
done

case "$CMD" in
    start|stop|console)
        exec "$REL_BIN" "$CMD" "$@"
        ;;

    shell)
        exec "$REL_BIN" remote_console
        ;;

    status)
        "$REL_BIN" ping && echo "Node is running." || echo "Node is not running."
        ;;

    demo)
        cat <<'BANNER'

  ████████╗███████╗███████╗███████╗
     ██╔══╝██╔════╝██╔════╝██╔════╝
     ██║   ███████╗███████╗███████╗
     ██║       ╚══╝╚════██║╚════╝
     ██║   ███████║███████║███████║
     ╚═╝   ╚══════╝╚══════╝╚══════╝

  Distributed Anonymous Encrypted Messaging
  ──────────────────────────────────────────
  Type:  tsss_demo:run().     to start the demo
         tsss_demo:help().    to see all demo commands
         q().                 to quit

BANNER
        erl \
            -name "$NODE_NAME" \
            -setcookie "$COOKIE" \
            -kernel dist_auto_connect never \
            -pa $EBIN_GLOB \
            -eval "application:ensure_all_started(tsss)."
        ;;

    cluster)
        N="${1:-3}"
        COOKIE_VAL="${COOKIE:-tsss_secret_cookie}"
        echo "Starting $N local Tsss nodes..."
        BASE_PORT=9100
        PIDS=()
        for i in $(seq 1 "$N"); do
            PORT=$((BASE_PORT + (i - 1) * 10))
            NNAME="tsss${i}@127.0.0.1"
            echo "  → $NNAME  (dist ports $PORT–$((PORT + 9)))"
            erl \
                -name "$NNAME" \
                -setcookie "$COOKIE_VAL" \
                -kernel dist_auto_connect never \
                -kernel inet_dist_listen_min "$PORT" \
                -kernel inet_dist_listen_max "$((PORT + 9))" \
                -pa $EBIN_GLOB \
                -noshell \
                -eval "application:ensure_all_started(tsss)." &
            PIDS+=("$!")
        done
        echo ""
        echo "All $N nodes started. Press Ctrl+C to stop them all."
        echo ""
        echo "To interact with one node in another terminal:"
        echo "  erl -name debug@127.0.0.1 -setcookie $COOKIE_VAL -remsh tsss1@127.0.0.1"
        echo ""
        trap "echo 'Stopping nodes...'; kill ${PIDS[*]} 2>/dev/null || true" INT TERM
        wait
        ;;

    help|--help|-h)
        usage
        ;;

    *)
        echo "Unknown command: $CMD" >&2
        usage
        exit 1
        ;;
esac
WRAPPER

    chmod +x "$wrapper"
    ok "Wrapper script written to $wrapper"
}

# ─── Final instructions ───────────────────────────────────────────────────────
print_success() {
    local wrapper_dir
    wrapper_dir="$(realpath "$REPO_DIR" 2>/dev/null || echo "$REPO_DIR")"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  Tsss installed successfully!${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Quick start:${NC}"
    echo ""
    echo -e "    cd $wrapper_dir"
    echo -e "    ./tsss demo          ${BLUE}# guided demo${NC}"
    echo -e "    ./tsss console       ${BLUE}# interactive Erlang shell${NC}"
    echo -e "    ./tsss cluster 3     ${BLUE}# 3-node local cluster${NC}"
    echo ""
    echo -e "  ${BOLD}To use from anywhere, add this to your shell profile:${NC}"
    echo ""
    echo -e "    ${YELLOW}export PATH=\"$wrapper_dir:\$PATH\"${NC}"
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}  Tsss — Distributed Anonymous Encrypted Messaging${NC}"
    echo -e "  Installer v1.0"
    echo ""

    need_cmd curl
    need_cmd git

    detect_os
    log "Platform : $PLATFORM ($ARCH)"
    [ "$PLATFORM" = "linux" ] && log "Distro   : ${DISTRO:-unknown}"

    ensure_erlang
    ensure_rebar3
    get_source
    build
    write_wrapper
    print_success
}

main "$@"
