#!/bin/bash
set -Eeuo pipefail

# ============================================================
#  LSHELL INSTALLER
# ============================================================

LOG="/tmp/lshell-installer.log"
MANIFEST_DIR="$HOME/.local/share/lshell"
MANIFEST="$MANIFEST_DIR/manifest"
REPO_URL="https://github.com/deploydy/lshell-play"

# ---------- colors ----------
R=$'\033[0m'
B=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[38;5;203m'
GREEN=$'\033[38;5;114m'
YELLOW=$'\033[38;5;221m'
BLUE=$'\033[38;5;75m'
PURPLE=$'\033[38;5;141m'
GRAY=$'\033[38;5;244m'

# ---------- cleanup ----------
KEEPALIVE_PID=""
cleanup() {
    tput cnorm 2>/dev/null || true
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null || true
    [ -n "${BUILD_DIR:-}" ] && rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'echo; exit 130' INT

# ---------- ui helpers ----------
banner() {
    clear
    local c=(141 135 105 75 81 87)
    local rows=(
"██╗     ███████╗██╗  ██╗███████╗██╗     ██╗     "
"██║     ██╔════╝██║  ██║██╔════╝██║     ██║     "
"██║     ███████╗███████║█████╗  ██║     ██║     "
"██║     ╚════██║██╔══██║██╔══╝  ██║     ██║     "
"███████╗███████║██║  ██║███████╗███████╗███████╗"
"╚══════╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝"
    )
    echo
    for i in "${!rows[@]}"; do
        printf '   \033[38;5;%sm%s%s\n' "${c[$i]}" "${rows[$i]}" "$R"
    done
    echo
    printf '   %sSway • Waybar • Rofi • Kitty%s   %s%s%s\n' "$GRAY" "$R" "$DIM" "$REPO_URL" "$R"
    echo
}

line() { printf '   %s%s%s\n' "$GRAY" "────────────────────────────────────────────────────" "$R"; }

info()  { printf '   %s●%s %s\n' "$BLUE" "$R" "$1"; }
ok()    { printf '   %s✔%s %s\n' "$GREEN" "$R" "$1"; }
warn()  { printf '   %s▲%s %s\n' "$YELLOW" "$R" "$1"; }
fail()  { printf '   %s✘%s %s\n' "$RED" "$R" "$1"; }

STEP=0
TOTAL=0

progress() {
    local width=30
    local filled=$(( STEP * width / TOTAL ))
    local bar="" i
    for ((i = 0; i < width; i++)); do
        if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done
    printf '   %s%s%s %s%3d%%%s\n' "$PURPLE" "$bar" "$R" "$B" $(( STEP * 100 / TOTAL )) "$R"
}

# run "message" command args...
run() {
    local msg="$1"; shift
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local i=0
    STEP=$((STEP + 1))

    echo "=== [$STEP/$TOTAL] $msg ===" >> "$LOG"
    "$@" >> "$LOG" 2>&1 &
    local pid=$!

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r   %s%s%s %s[%d/%d]%s %s' \
            "$PURPLE" "${frames[$((i % 10))]}" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" "$msg"
        i=$((i + 1))
        sleep 0.08
    done

    local rc=0
    wait "$pid" || rc=$?
    tput cnorm 2>/dev/null || true
    printf '\r\033[K'

    if (( rc == 0 )); then
        printf '   %s✔%s %s[%d/%d]%s %s\n' "$GREEN" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" "$msg"
    else
        printf '   %s✘%s %s[%d/%d]%s %s\n' "$RED" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" "$msg"
        echo
        fail "Step failed. Last log lines:"
        tail -n 12 "$LOG" | sed "s/^/     ${DIM}/;s/$/${R}/"
        echo
        fail "Full log: $LOG"
        exit 1
    fi
}

summary() {
    echo
    line
    printf '   %s%s%s\n' "$GREEN$B" "$1" "$R"
    line
    echo
}

ask_reboot() {
    local ans
    read -rp "   Reboot now? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        info "Rebooting..."
        sudo reboot
    else
        info "Reboot skipped."
    fi
}

# ---------- arrow-key menu ----------
MENU_ITEMS=("Update system" "Full installation" "Uninstall lshell" "Exit")
MENU_ICONS=("" "" "" "")

menu() {
    local sel=0 key n=${#MENU_ITEMS[@]} i
    tput civis 2>/dev/null || true
    while true; do
        for i in "${!MENU_ITEMS[@]}"; do
            if (( i == sel )); then
                printf '\r\033[K   %s▍%s %s%s%d  %s%s\n' "$PURPLE" "$R" "$B" "$PURPLE" $((i + 1)) "${MENU_ITEMS[$i]}" "$R"
            else
                printf '\r\033[K   %s  %d  %s%s\n' "$GRAY" $((i + 1)) "${MENU_ITEMS[$i]}" "$R"
            fi
        done
        IFS= read -rsn1 key || true
        if [[ "$key" == $'\033' ]]; then
            read -rsn2 -t 0.01 key || true
            case "$key" in
                '[A') sel=$(( (sel - 1 + n) % n )) ;;
                '[B') sel=$(( (sel + 1) % n )) ;;
            esac
        elif [[ -z "$key" ]]; then
            break
        elif [[ "$key" =~ ^[1-4]$ ]]; then
            sel=$((key - 1)); break
        elif [[ "$key" == "k" ]]; then
            sel=$(( (sel - 1 + n) % n ))
        elif [[ "$key" == "j" ]]; then
            sel=$(( (sel + 1) % n ))
        fi
        printf '\033[%dA' "$n"
    done
    tput cnorm 2>/dev/null || true
    MENU_CHOICE=$sel
}

# ---------- checks ----------
if [ "$EUID" -eq 0 ]; then
    banner; fail "Do not run this script as root!"; exit 1
fi
if ! command -v pacman &> /dev/null; then
    banner; fail "pacman not found. This script requires Arch Linux."; exit 1
fi
if ! command -v yay &> /dev/null; then
    banner; fail "yay is not installed."; exit 1
fi

: > "$LOG"

# ---------- sudo keepalive ----------
start_sudo() {
    sudo -v
    ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    KEEPALIVE_PID=$!
}

# ============================================================
#  ACTIONS
# ============================================================

do_update() {
    TOTAL=2
    start_sudo
    echo

    run "Refreshing package databases" sudo pacman -Syy

    local conflicts
    conflicts=$(sudo pacman -Su --print 2>&1 | grep -iE "conflict" || true)
    if [ -n "$conflicts" ]; then
        warn "Conflicts detected:"
        echo "$conflicts" | sed 's/^/     /'
        echo
        local ans
        read -rp "   Remove conflicting packages? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            local pkgs
            pkgs=$(echo "$conflicts" | grep -oP '^\s*\K[^:]+(?=\s*:)' || true)
            if [ -n "$pkgs" ]; then
                # shellcheck disable=SC2086
                sudo pacman -Rdd --noconfirm $pkgs >> "$LOG" 2>&1 || true
                ok "Conflicting packages removed."
            fi
        fi
        echo
    fi

    run "Upgrading packages" sudo pacman -Su --noconfirm

    summary "Update completed"
    ask_reboot
}

build_aur() {
    local name="$1"
    ( cd "$BUILD_DIR" \
      && git clone "https://aur.archlinux.org/$name.git" \
      && cd "$name" \
      && makepkg -si --noconfirm )
}

install_configs() {
    rm -rf "$HOME/lshell-play"
    git clone "$REPO_URL" "$HOME/lshell-play"
    mkdir -p "$HOME/.config" "$MANIFEST_DIR"
    ( cd "$HOME/lshell-play" && ls -A | grep -vx '.git' ) > "$MANIFEST"
    cp -r "$HOME/lshell-play/"* "$HOME/.config/"
    rm -rf "$HOME/lshell-play"
}

do_install() {
    TOTAL=8
    start_sudo
    BUILD_DIR=$(mktemp -d)
    echo

    run "Updating system" sudo pacman -Syyu --noconfirm

    run "Installing core packages" sudo pacman -S --needed --noconfirm \
        git autotiling swaybg waybar kitty rofi \
        papirus-icon-theme ttf-fira-code ttf-jetbrains-mono-nerd \
        ttf-nerd-fonts-symbols ttf-font-awesome noto-fonts-emoji \
        gsimplecal wtype rofi-emoji dolphin bluez bluez-utils blueman \
        nwg-displays fastfetch python python-pip polkit-gnome \
        python-cryptography python-requests python-beautifulsoup4 \
        python-rich wl-clipboard swaync lutris ppsspp qbittorrent

    run "Installing AUR packages" yay -S --needed --noconfirm waypaper wlogout grim slurp
    run "Building scenefx0.5" build_aur scenefx0.5
    run "Building swayfx" build_aur swayfx
    run "Generating fastfetch config" fastfetch --gen-config
    run "Removing old waybar config" rm -rf "$HOME/.config/waybar/config.jsonc"
    run "Installing lshell configs" install_configs

    summary "Installation completed successfully"
    ask_reboot
}

do_uninstall() {
    TOTAL=3
    start_sudo
    echo

    remove_configs() {
        local items=()
        if [ -f "$MANIFEST" ]; then
            mapfile -t items < "$MANIFEST"
        else
            items=(sway waybar rofi swaync wlogout waypaper kitty fastfetch autotiling gsimplecal nwg-displays)
        fi
        local item
        for item in "${items[@]}"; do
            [ -n "$item" ] && rm -rf "$HOME/.config/${item:?}"
        done
        rm -rf "$MANIFEST_DIR"
    }

    remove_packages() {
        local candidates=(swayfx scenefx0.5 waypaper wlogout autotiling swaybg waybar rofi rofi-emoji swaync nwg-displays gsimplecal)
        local pkg
        for pkg in "${candidates[@]}"; do
            if pacman -Qq "$pkg" &> /dev/null; then
                sudo pacman -Rns --noconfirm "$pkg" || true
            fi
        done
    }

    run "Removing lshell configs" remove_configs
    run "Removing lshell packages" remove_packages
    run "Cleaning package cache" bash -c 'rm -rf "$HOME/lshell-play" /tmp/lshell-*.tmp'

    summary "lshell has been removed"
    ask_reboot
}

# ============================================================
#  MAIN
# ============================================================

banner
printf '   %sSelect an action%s  %s↑/↓ or 1-4, Enter to confirm%s\n' "$B" "$R" "$GRAY" "$R"
line
MENU_CHOICE=0
menu
line

case "$MENU_CHOICE" in
    0) do_update ;;
    1) do_install ;;
    2) do_uninstall ;;
    3) info "Exiting."; exit 0 ;;
esac
