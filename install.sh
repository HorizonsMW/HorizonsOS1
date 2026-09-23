#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  HorizonsOS1 installer
#  Deploys Hyprland, Noctalia, Dunst and Swappy configs into ~/.config,
#  backing up every file it replaces (*.bak), then reloads the running
#  components so the new configs take effect immediately.
#
#  Usage:  ./install.sh [-y|--yes] [-n|--dry-run] [--no-reload] [-h|--help]
#          (run as your normal user - do NOT use sudo)
#
#  Environment overrides:
#    NOCTALIA_LAUNCH   full command used to (re)start Noctalia, e.g.
#                      NOCTALIA_LAUNCH="qs -c noctalia-shell" ./install.sh
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

readonly NAME="HorizonsOS1"
readonly AUTHOR="HorizonsMW"          # <- change before publishing
readonly VERSION="1.1.1"

# Config folders shipped in ./config/ -> installed to ~/.config/<folder>
readonly CONFIGS=(hypr noctalia dunst swappy)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SRC_ROOT="${SCRIPT_DIR}/config"
readonly CONFIG_HOME="${HOME}/.config"

ASSUME_YES=0
DRY_RUN=0
NO_RELOAD=0
INSIDE_HYPR=0          # 1 when this script was launched from inside Hyprland
TOTAL_BACKUPS=0
INSTALLED=()
FAILED=()

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

# run:       execute a mutating command (or just print it under --dry-run)
# run_quiet: same, but silences the command's own output
run()       { if (( DRY_RUN )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }
run_quiet() { if (( DRY_RUN )); then printf '   [dry-run] %s\n' "$*"; else "$@" >/dev/null 2>&1; fi; }

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
Usage: $0 [options]        (run as your normal user, without sudo)

  -y, --yes       Overwrite existing configs without prompting (still backs up)
  -n, --dry-run   Show what would happen, change nothing
      --no-reload Install files only; do not reload/restart anything
  -h, --help      Show this help
EOF
}

# ── Argument parsing ────────────────────────────────────────────────────────
while (( $# )); do
    case "$1" in
        -y|--yes)     ASSUME_YES=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        --no-reload)  NO_RELOAD=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die "Unknown option: $1" ;;
    esac
    shift
done

banner

# ── Sanity checks ───────────────────────────────────────────────────────────
# Nothing here needs root: everything lives under the user's own home.
# Running as root would put files in /root or leave root-owned files in ~/.config. 
# I experienced root-owned files in configs folder the hard way : )
(( EUID != 0 )) || die "Do not run with sudo/as root. Run as your normal user:  ./install.sh"
[[ -d "${HOME:-}" ]] || die "\$HOME is not set or not a directory."
[[ -d "$SRC_ROOT" ]] || die "Source directory not found: $SRC_ROOT"

# Session environment: normally inherited from the terminal you launched this
# from; these fill in the gaps when run from a TTY or over SSH.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}"
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

info "User:        ${C_BOLD}$(id -un)${C_RESET}"
info "Config dir:  ${C_BOLD}${CONFIG_HOME}${C_RESET}"
if (( DRY_RUN )); then warn "Dry-run mode: no changes will be made."; fi
echo

# ── Helpers ─────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Ask a yes/no question. Reads from /dev/tty so it works even when piped.
confirm() {
    local prompt="$1" reply=""
    if (( ASSUME_YES )); then return 0; fi
    { : </dev/tty; } 2>/dev/null || die "No TTY available for prompt; rerun with --yes."
    read -r -p "$(printf '%s ?%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$prompt")" reply </dev/tty
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Pick a backup name: file.bak, or file.bak.<timestamp> if .bak already exists
backup_name() {
    local f="$1"
    if [[ -e "${f}.bak" || -L "${f}.bak" ]]; then
        printf '%s.bak.%s' "$f" "$(date +%Y%m%d-%H%M%S)"
    else
        printf '%s.bak' "$f"
    fi
}

is_installed() { local x; for x in "${INSTALLED[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

# ── Noctalia detection ──────────────────────────────────────────────────────
# Noctalia v5+   : standalone binary            -> `noctalia`
# Noctalia v4.x  : runs on Quickshell           -> `qs -c noctalia-shell`
#                  (some distros: `noctalia-qs -c noctalia-shell`)
NOCTALIA_CMD=()
NOCTALIA_MODE=""       # pgrep/pkill match mode: -x (exact name) or -f (cmdline)
NOCTALIA_PATTERN=""

detect_noctalia() {
    if [[ -n "${NOCTALIA_LAUNCH:-}" ]]; then
        read -r -a NOCTALIA_CMD <<<"$NOCTALIA_LAUNCH"
        NOCTALIA_MODE="-f"; NOCTALIA_PATTERN="$NOCTALIA_LAUNCH"
    elif have noctalia; then
        NOCTALIA_CMD=(noctalia)
        NOCTALIA_MODE="-x"; NOCTALIA_PATTERN="noctalia"
    elif have noctalia-qs; then
        NOCTALIA_CMD=(noctalia-qs -c noctalia-shell)
        NOCTALIA_MODE="-f"; NOCTALIA_PATTERN="qs .*-c noctalia-shell"
    elif have qs; then
        NOCTALIA_CMD=(qs -c noctalia-shell)
        NOCTALIA_MODE="-f"; NOCTALIA_PATTERN="qs .*-c noctalia-shell"
    else
        return 1
    fi
}

# ── Hyprland session handling ───────────────────────────────────────────────
# Succeeds if a live Hyprland instance answers, and exports its signature so
# hyprctl talks to the right one. Stale sessions (crashed compositors) are
# skipped because they don't answer.
hypr_session_alive() {
    have hyprctl || return 1

    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && hyprctl version >/dev/null 2>&1; then
        INSIDE_HYPR=1
        return 0
    fi

    local dir="${XDG_RUNTIME_DIR}/hypr" sig
    [[ -d "$dir" ]] || return 1
    while IFS= read -r sig; do
        if HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl version >/dev/null 2>&1; then
            export HYPRLAND_INSTANCE_SIGNATURE="$sig"
            return 0
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null \
                 | sort -rn | cut -d' ' -f2-)
    return 1
}

# Ask Hyprland to launch a command so it inherits the compositor's environment
# (env = lines, Qt/cursor vars, XDG_CURRENT_DESKTOP...). Syntax differs by
# version: hyprlang configs use `exec <cmd>`, the Lua-config era (0.55+) uses
# hl.dsp.exec_cmd(). Try both and only trust an explicit "ok".
hypr_exec() {
    local cmd="$*" out
    out="$(hyprctl dispatch exec "$cmd" 2>&1 || true)"
    if [[ "$out" == ok* ]]; then return 0; fi
    out="$(hyprctl dispatch "hl.dsp.exec_cmd(\"${cmd//\"/\\\"}\")" 2>&1 || true)"
    [[ "$out" == ok* ]]
}

# Start a detached process inside the user's graphical session.
spawn_in_session() {
    if (( INSIDE_HYPR )); then
        # Launched from within Hyprland: our own environment IS the session's.
        setsid -f "$@" >/dev/null 2>&1 </dev/null
    else
        hypr_exec "$@"
    fi
}

# restart_service LABEL SYSTEMD_UNIT PGREP_MODE PGREP_PATTERN CMD...
# Restarts via systemd if the unit is active, otherwise kill + respawn.
# Success is only reported once the process is actually seen running.
restart_service() {
    local label="$1" unit="$2" mode="$3" pattern="$4"; shift 4
    local i

    if (( DRY_RUN )); then
        printf '   [dry-run] would restart %s (%s)\n' "$label" "$*"
        return 0
    fi

    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
        systemctl --user restart "$unit" || { warn "systemctl restart $unit failed"; return 1; }
        ok "${label} restarted (systemd: ${unit})"
        return 0
    fi

    if pgrep -u "$UID" "$mode" -- "$pattern" >/dev/null 2>&1; then
        pkill -u "$UID" "$mode" -- "$pattern" || true
        for i in {1..20}; do   # wait up to ~5s for a clean exit
            pgrep -u "$UID" "$mode" -- "$pattern" >/dev/null 2>&1 || break
            sleep 0.25
        done
    fi

    if ! spawn_in_session "$@"; then
        warn "${label}: could not launch via the session. Start it manually: $*"
        return 1
    fi

    for i in {1..10}; do       # confirm it really came up (~5s)
        if pgrep -u "$UID" "$mode" -- "$pattern" >/dev/null 2>&1; then
            ok "${label} restarted"
            return 0
        fi
        sleep 0.5
    done
    warn "${label} did not appear to start. Try running it by hand: $*"
    return 1
}

reload_hyprland() {
    if (( DRY_RUN )); then
        printf '   [dry-run] hyprctl reload\n'
        return 0
    fi
    if ! hyprctl reload >/dev/null 2>&1; then
        warn "hyprctl reload failed; log out and back in to apply"
        return 1
    fi
    sleep 0.5
    # `hyprctl reload` exits 0 even if the new config is broken - check.
    local errs
    errs="$(hyprctl configerrors 2>&1 || true)"
    if [[ -n "${errs//[[:space:]]/}" ]]; then
        warn "Hyprland reloaded, but reports config errors:"
        printf '%s\n' "$errs" | sed 's/^/     /' >&2
        return 1
    fi
    ok "Hyprland config reloaded (no config errors)"
}

# ── Step 1: ~/.config ───────────────────────────────────────────────────────
if [[ -d "$CONFIG_HOME" ]]; then
    ok "${CONFIG_HOME} exists"
else
    info "Creating ${CONFIG_HOME}"
    run install -d -m 0700 "$CONFIG_HOME"
    ok "Created ${CONFIG_HOME}"
fi
echo

# ── Step 1b: soft dependency check (warn only) ──────────────────────────────
check_deps() {
    local cfg
    for cfg in "${CONFIGS[@]}"; do
        [[ -d "${SRC_ROOT}/${cfg}" ]] || continue
        case "$cfg" in
            hypr)     have hyprctl || warn "[hypr] 'hyprctl' not found - is Hyprland installed?" ;;
            noctalia) detect_noctalia || warn "[noctalia] no 'noctalia' / 'qs' binary found in PATH" ;;
            dunst)    have dunst   || warn "[dunst] 'dunst' not found in PATH" ;;
            swappy)   have swappy  || warn "[swappy] 'swappy' not found in PATH" ;;
        esac
    done
}
check_deps
echo

# ── Step 2: deploy each config folder ───────────────────────────────────────
# Backups made for the folder currently being deployed (used for rollback).
_ORIG=()
_BAK=()

restore_backups() {
    local i
    for i in "${!_BAK[@]}"; do
        mv -f -- "${_BAK[i]}" "${_ORIG[i]}" 2>/dev/null || true
    done
}

# Record a folder as failed (non-fatal: other folders still get installed).
fail_config() {
    FAILED+=("$1")
    echo
}

deploy_config() {
    local name="$1"
    local src="${SRC_ROOT}/${name}"
    local dst="${CONFIG_HOME}/${name}"
    local -a files=() blocked=()
    local rel target bak
    _ORIG=(); _BAK=()

    if [[ ! -d "$src" ]]; then
        warn "[$name] not present in repo, skipping"
        return 0
    fi

    printf '%s── %s ──%s\n' "$C_BOLD" "$name" "$C_RESET"

    # Everything the repo would place (regular files and symlinks).
    mapfile -d '' -t files < <(cd "$src" && find . \( -type f -o -type l \) -print0)
    if (( ${#files[@]} == 0 )); then
        warn "[$name] repo folder is empty, skipping"
        echo
        return 0
    fi

    if [[ -L "$dst" ]]; then
        warn "[$name] ${dst} is a symlink -> $(readlink -f -- "$dst"); refusing to modify its target, skipping"
        echo
        return 0
    elif [[ -e "$dst" && ! -d "$dst" ]]; then
        die "[$name] ${dst} exists but is not a directory"
    elif [[ -d "$dst" ]]; then
        info "${dst/#$HOME/\~} already exists"

        # Pre-flight: renaming/creating files needs write access to every
        # directory involved. Typical cause of failure: a root-owned folder
        # left over from an earlier sudo run. Check BEFORE asking or changing anything.
        mapfile -t blocked < <(find "$dst" -type d ! -writable -print 2>/dev/null | head -n 5)
        if (( ${#blocked[@]} > 0 )); then
            warn "[$name] you don't have write permission here:"
            printf '       %s\n' "${blocked[@]}" >&2
            warn "[$name] owner: $(stat -c '%U:%G' -- "${blocked[0]}")  -> fix with:"
            printf '       sudo chown -R %q:%q %q\n' "$(id -un)" "$(id -gn)" "$dst" >&2
            fail_config "$name"
            return 0
        fi

        if ! confirm "Overwrite ${name} config? (replaced files are kept as *.bak)"; then
            warn "[$name] skipped"
            echo
            return 0
        fi

        # Back up every file that is about to be replaced.
        for rel in "${files[@]}"; do
            rel="${rel#./}"
            target="${dst}/${rel}"
            if [[ ( -e "$target" || -L "$target" ) && ! -d "$target" ]]; then
                # Already identical to the repo copy (e.g. a re-run)? Nothing to
                # preserve - and a "backup" of our own file would only confuse
                # restores later, since .bak should mean "what you had before".
                if [[ -f "${src}/${rel}" && -f "$target" && ! -L "$target" ]] \
                   && cmp -s -- "${src}/${rel}" "$target"; then
                    continue
                fi
                bak="$(backup_name "$target")"
                if ! run mv -- "$target" "$bak"; then
                    warn "[$name] could not back up ${target/#$HOME/\~} - restoring and skipping this folder"
                    restore_backups
                    fail_config "$name"
                    return 0
                fi
                _ORIG+=("$target")
                _BAK+=("$bak")
                printf '   backup  %s -> %s\n' "${target/#$HOME/\~}" "$(basename -- "$bak")"
            fi
        done
        TOTAL_BACKUPS=$(( TOTAL_BACKUPS + ${#_BAK[@]} ))
        ok "[$name] backed up ${#_BAK[@]} file(s)"
    else
        info "${dst/#$HOME/\~} does not exist, creating"
        if ! run install -d -m 0755 "$dst"; then
            warn "[$name] could not create ${dst/#$HOME/\~}"
            fail_config "$name"
            return 0
        fi
    fi

    # Copy repo files in (repo stays intact so the installer can be re-run).
    # If the copy fails, put the originals back rather than leave a half-new config.
    if ! run cp -a -- "${src}/." "${dst}/"; then
        warn "[$name] copy failed - restoring original files"
        restore_backups
        TOTAL_BACKUPS=$(( TOTAL_BACKUPS - ${#_BAK[@]} ))
        fail_config "$name"
        return 0
    fi
    ok "[$name] installed to ${dst/#$HOME/\~}"
    INSTALLED+=("$name")
    echo
}

for cfg in "${CONFIGS[@]}"; do
    deploy_config "$cfg"
done

if (( ${#INSTALLED[@]} == 0 )); then
    warn "Nothing installed; no services to reload."
    if (( ${#FAILED[@]} > 0 )); then exit 1; fi
    exit 0
fi

# ── Step 3: reload running components ───────────────────────────────────────
printf '%s── Reloading ──%s\n' "$C_BOLD" "$C_RESET"

if (( NO_RELOAD )); then
    info "Reload skipped (--no-reload). Configs apply on next login."
elif ! hypr_session_alive; then
    warn "No running Hyprland session found for $(id -un); configs apply at next login."
else
    # Hyprland: reload in place (a full restart would end your session).
    if is_installed hypr; then
        reload_hyprland || true
    fi

    # Noctalia: restart the shell.
    if is_installed noctalia; then
        if detect_noctalia; then
            restart_service "Noctalia" "noctalia.service" \
                "$NOCTALIA_MODE" "$NOCTALIA_PATTERN" "${NOCTALIA_CMD[@]}" || true
        else
            warn "Noctalia not found in PATH; skipping restart"
        fi
    fi

    # Dunst: prefer an in-place reload, fall back to restart.
    if is_installed dunst; then
        if have dunst; then
            if (( ! DRY_RUN )) && pgrep -u "$UID" -x dunst >/dev/null 2>&1 \
               && have dunstctl && dunstctl reload >/dev/null 2>&1; then
                ok "Dunst config reloaded"
            else
                restart_service "Dunst" "dunst.service" "-x" "dunst" dunst || true
            fi
        else
            warn "Dunst not found in PATH; skipping restart"
        fi
    fi

    # Confirmation popup (only if a notification daemon is answering).
    if (( ! DRY_RUN )) && have notify-send; then
        notify-send -a "$NAME" "$NAME $VERSION" \
            "Configs installed: ${INSTALLED[*]}" >/dev/null 2>&1 || true
    fi
fi

# Swappy has no daemon; the new config is read on next launch.
if is_installed swappy; then
    ok "Swappy config will be used on next launch"
fi

echo
if (( DRY_RUN )); then
    ok "${C_BOLD}Dry run complete${C_RESET} - nothing was changed. Would install: ${INSTALLED[*]}"
    exit 0
fi
ok "${C_BOLD}${NAME} ${VERSION} installed:${C_RESET} ${INSTALLED[*]}"
if (( ${#FAILED[@]} > 0 )); then
    warn "NOT installed: ${FAILED[*]} - fix the problem shown above and re-run (safe to repeat)."
fi
if (( TOTAL_BACKUPS > 0 )); then
    info "${TOTAL_BACKUPS} original file(s) saved alongside as <file>.bak (or <file>.bak.<timestamp>)."
    info "Restore one with:  mv <file>.bak <file>"
fi
if (( ${#FAILED[@]} > 0 )); then exit 1; fi