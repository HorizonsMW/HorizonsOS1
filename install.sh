#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  HorizonsOS1 installer
#  Deploys Hyprland, Noctalia, Dunst and Swappy configs into ~/.config
#  of the user who invoked sudo, backing up anything it replaces.
#
#  Usage:  sudo ./install.sh [-y|--yes] [-n|--dry-run] [-h|--help]
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

readonly NAME="HorizonsOS1"
readonly AUTHOR="HorizonsMW"          # <- change before publishing
readonly VERSION="1.0.0"

# Config folders shipped in ./config/ -> installed to ~/.config/<folder>
readonly CONFIGS=(hypr noctalia dunst swappy)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SRC_ROOT="${SCRIPT_DIR}/config"

ASSUME_YES=0
DRY_RUN=0
INSTALLED=()

# ── Output helpers ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_GOLD=$'\e[38;5;178m'
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
else
    C_RESET=""; C_BOLD=""; C_GOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

info()  { printf '%s::%s %s\n'     "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s ✓%s %s\n'     "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s !%s %s\n'     "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s ✗%s %s\n'     "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
run()   { if (( DRY_RUN )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

banner() {
    printf '%s%s' "$C_GOLD" "$C_BOLD"
    cat <<'EOF'
  _   _            _                      ___  ____  _
 | | | | ___  _ __(_)_______  _ __  ___  / _ \/ ___|/ |
 | |_| |/ _ \| '__| |_  / _ \| '_ \/ __|| | | \___ \| |
 |  _  | (_) | |  | |/ / (_) | | | \__ \| |_| |___) | |
 |_| |_|\___/|_|  |_/___\___/|_| |_|___/ \___/|____/|_|
EOF
    printf '%s\n' "$C_RESET"
    printf '  %sName:%s    %s\n'   "$C_BOLD" "$C_RESET" "$NAME"
    printf '  %sAuthor:%s  %s\n'   "$C_BOLD" "$C_RESET" "$AUTHOR"
    printf '  %sVersion:%s %s\n\n' "$C_BOLD" "$C_RESET" "$VERSION"
}

usage() {
    cat <<EOF
Usage: sudo $0 [options]

  -y, --yes       Overwrite existing configs without prompting (still backs up)
  -n, --dry-run   Show what would happen, change nothing
  -h, --help      Show this help
EOF
}

# ── Argument parsing ────────────────────────────────────────────────────────
while (( $# )); do
    case "$1" in
        -y|--yes)     ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die "Unknown option: $1" ;;
    esac
    shift
done

banner

# ── Privilege + target user checks ──────────────────────────────────────────
(( EUID == 0 )) || die "This installer must be run with sudo:  sudo $0"

# Under sudo, $HOME may point at /root. Resolve the real invoking user instead.
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] \
    || die "Run via sudo from your normal user account (not as root directly)."

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$TARGET_HOME" ]] || die "Home directory for $TARGET_USER not found."

CONFIG_HOME="${TARGET_HOME}/.config"
RUNTIME_DIR="/run/user/${TARGET_UID}"

info "Target user:  ${C_BOLD}${TARGET_USER}${C_RESET}"
info "Config dir:   ${C_BOLD}${CONFIG_HOME}${C_RESET}"
(( DRY_RUN )) && warn "Dry-run mode: no changes will be made."
echo

[[ -d "$SRC_ROOT" ]] || die "Source directory not found: $SRC_ROOT"

# ── Helpers ─────────────────────────────────────────────────────────────────
# Ask a yes/no question. Reads from /dev/tty so it works even when piped.
confirm() {
    local prompt="$1" reply=""
    (( ASSUME_YES )) && return 0
    { : </dev/tty; } 2>/dev/null || die "No TTY available for prompt; rerun with --yes."
    read -r -p "$(printf '%s ?%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$prompt")" reply </dev/tty
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Run a command as the target user with their Wayland/Hyprland session env.
as_user() {
    local sig="" wl=""
    # Newest Hyprland instance for this user
    if [[ -d "${RUNTIME_DIR}/hypr" ]]; then
        sig="$(ls -1t "${RUNTIME_DIR}/hypr" 2>/dev/null | head -n1 || true)"
    fi
    # First wayland socket
    for s in "${RUNTIME_DIR}"/wayland-*; do
        [[ -S "$s" ]] && { wl="$(basename "$s")"; break; }
    done
    sudo -u "$TARGET_USER" env \
        HOME="$TARGET_HOME" \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        XDG_CONFIG_HOME="$CONFIG_HOME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus" \
        WAYLAND_DISPLAY="$wl" \
        HYPRLAND_INSTANCE_SIGNATURE="$sig" \
        "$@"
}

# Start a detached background process in the user's session.
spawn_user() {
    run as_user setsid -f "$@" >/dev/null 2>&1 </dev/null
}

have() { command -v "$1" >/dev/null 2>&1; }

# Pick a backup name: file.bak, or file.bak.<timestamp> if .bak already exists
backup_name() {
    local f="$1"
    if [[ -e "${f}.bak" ]]; then
        printf '%s.bak.%s' "$f" "$(date +%Y%m%d-%H%M%S)"
    else
        printf '%s.bak' "$f"
    fi
}

# ── Step 1: ~/.config ───────────────────────────────────────────────────────
if [[ -d "$CONFIG_HOME" ]]; then
    ok "${CONFIG_HOME} exists"
else
    info "Creating ${CONFIG_HOME}"
    run install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$CONFIG_HOME"
    ok "Created ${CONFIG_HOME}"
fi
echo

# ── Step 2: deploy each config folder ───────────────────────────────────────
deploy_config() {
    local name="$1"
    local src="${SRC_ROOT}/${name}"
    local dst="${CONFIG_HOME}/${name}"

    if [[ ! -d "$src" ]]; then
        warn "[$name] not present in repo, skipping"
        return 0
    fi

    printf '%s── %s ──%s\n' "$C_BOLD" "$name" "$C_RESET"

    if [[ -d "$dst" ]]; then
        info "${dst} already exists"
        if ! confirm "Overwrite ${name} config? (existing files are kept as *.bak)"; then
            warn "[$name] skipped"
            echo
            return 0
        fi

        # Back up every file that is about to be replaced.
        local rel target bak count=0
        while IFS= read -r -d '' rel; do
            rel="${rel#./}"
            target="${dst}/${rel}"
            if [[ -e "$target" && ! -d "$target" ]]; then
                bak="$(backup_name "$target")"
                run mv -- "$target" "$bak"
                printf '   backup  %s -> %s\n' "${target/#$TARGET_HOME/\~}" "$(basename "$bak")"
                ((++count))
            fi
        done < <(cd "$src" && find . -type f -print0)
        ok "[$name] backed up ${count} file(s)"
    else
        info "${dst} does not exist, creating"
        run install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$dst"
    fi

    # Copy repo files in (repo stays intact so the installer can be re-run).
    run cp -a -- "${src}/." "${dst}/"
    run chown -R "${TARGET_UID}:${TARGET_GID}" "$dst"
    ok "[$name] installed to ${dst/#$TARGET_HOME/\~}"
    INSTALLED+=("$name")
    echo
}

for cfg in "${CONFIGS[@]}"; do
    deploy_config "$cfg"
done

if (( ${#INSTALLED[@]} == 0 )); then
    warn "Nothing installed; no services to reload."
    exit 0
fi

# ── Step 3: reload running components ───────────────────────────────────────
printf '%s── Reloading ──%s\n' "$C_BOLD" "$C_RESET"

is_installed() { local x; for x in "${INSTALLED[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
user_running() { pgrep -u "$TARGET_UID" -x "$1" >/dev/null 2>&1; }

if ! user_running Hyprland && ! user_running Hyprland-wrapped; then
    warn "Hyprland is not running for ${TARGET_USER}; configs apply at next login."
else
    # Hyprland: reload config in place (a full restart would end the session).
    if is_installed hypr && have hyprctl; then
        if run as_user hyprctl reload >/dev/null; then
            ok "Hyprland config reloaded"
        else
            warn "hyprctl reload failed; log out and back in to apply"
        fi
    fi

    # Noctalia: restart the shell.
    if is_installed noctalia && have noctalia; then
        if user_running noctalia; then
            run pkill -u "$TARGET_UID" -x noctalia || true
            (( DRY_RUN )) || sleep 1
        fi
        spawn_user noctalia
        ok "Noctalia restarted"
    fi

    # Dunst: restart the daemon (dunstctl reload is used when available).
    if is_installed dunst && have dunst; then
        if user_running dunst && have dunstctl && run as_user dunstctl reload >/dev/null 2>&1; then
            ok "Dunst config reloaded"
        else
            run pkill -u "$TARGET_UID" -x dunst || true
            (( DRY_RUN )) || sleep 0.5
            spawn_user dunst
            ok "Dunst restarted"
        fi
        (( DRY_RUN )) || as_user notify-send -a "$NAME" "$NAME $VERSION" \
            "Configs installed: ${INSTALLED[*]}" >/dev/null 2>&1 || true
    fi
fi

# Swappy has no daemon; the new config is read on next launch.
is_installed swappy && ok "Swappy config will be used on next launch"

echo
ok "${C_BOLD}${NAME} ${VERSION} installed:${C_RESET} ${INSTALLED[*]}"
info "Restore any file with:  mv <file>.bak <file>"
