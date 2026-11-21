#!/bin/bash
set -Eeuo pipefail

# ============================================================
#  LSHELL INSTALLER
# ============================================================

LOG="/tmp/lshell-installer.log"
MANIFEST_DIR="$HOME/.local/share/lshell"
MANIFEST="$MANIFEST_DIR/manifest"
REPO_URL="https://github.com/deploydy/lshell-play"
T0=$SECONDS

# ---------- palette (truecolor) ----------
R=$'\033[0m'
B=$'\033[1m'
DIM=$'\033[2m'
PURPLE=$'\033[38;2;167;139;250m'
CYAN=$'\033[38;2;103;232;249m'
PINK=$'\033[38;2;244;114;182m'
GREEN=$'\033[38;2;134;239;172m'
YELLOW=$'\033[38;2;253;224;71m'
RED=$'\033[38;2;248;113;113m'
BLUE=$'\033[38;2;125;180;255m'
TEXT=$'\033[38;2;228;228;231m'
GRAY=$'\033[38;2;130;130;145m'
DARK=$'\033[38;2;63;63;80m'
BG_SEL=$'\033[48;2;36;34;58m'
BG_GREEN=$'\033[48;2;134;239;172m\033[38;2;20;20;30m'
BG_RED=$'\033[48;2;248;113;113m\033[38;2;20;20;30m'

HR=""
for ((i = 0; i < 50; i++)); do HR+="─"; done

# ---------- cleanup ----------
KEEPALIVE_PID=""
cleanup() {
    tput cnorm 2>/dev/null || true
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null || true
    [ -n "${BUILD_DIR:-}" ] && rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'echo; exit 130' INT

# ============================================================
#  UI HELPERS
# ============================================================

banner() {
    clear
    local rows=(
"██╗     ███████╗██╗  ██╗███████╗██╗     ██╗     "
"██║     ██╔════╝██║  ██║██╔════╝██║     ██║     "
"██║     ███████╗███████║█████╗  ██║     ██║     "
"██║     ╚════██║██╔══██║██╔══╝  ██║     ██║     "
"███████╗███████║██║  ██║███████╗███████╗███████╗"
"╚══════╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝"
    )
    local cols=("196;148;255" "170;152;255" "143;164;255" "116;184;255" "98;208;255" "103;232;249")
    local i
    echo
    for i in "${!rows[@]}"; do
        printf '   \033[38;2;%sm%s%s\n' "${cols[$i]}" "${rows[$i]}" "$R"
    done
    echo
    printf '   %s◆%s %sSway%s %s·%s %sWaybar%s %s·%s %sRofi%s %s·%s %sKitty%s\n' \
        "$PURPLE" "$R" "$TEXT" "$R" "$DARK" "$R" "$TEXT" "$R" "$DARK" "$R" "$TEXT" "$R" "$DARK" "$R" "$TEXT" "$R"
    printf '   %s%s%s\n' "$DIM$GRAY" "$REPO_URL" "$R"
    printf '   %sArch Linux · %s@%s%s\n' "$DIM$GRAY" "${USER:-user}" "${HOSTNAME:-host}" "$R"
    echo
}

info() { printf '   %s●%s %s\n' "$BLUE" "$R" "$1"; }
ok()   { printf '   %s✔%s %s\n' "$GREEN" "$R" "$1"; }
warn() { printf '   %s▲%s %s\n' "$YELLOW" "$R" "$1"; }
fail() { printf '   %s✘%s %s\n' "$RED" "$R" "$1"; }

# rail-style blocks:  ╭─ Title / │  text / ╰─
RAILC="$PURPLE"
rail_top()  { RAILC="${2:-$PURPLE}"; printf '\n   %s╭─%s %s%s%s%s\n' "$RAILC" "$R" "$B" "$TEXT" "$1" "$R"; }
rail()      { printf '   %s│%s  %s\n' "$RAILC" "$R" "$1"; }
rail_end()  { printf '   %s╰─%s\n' "$RAILC" "$R"; }

# gradient progress bar -> $BAR
BARW=20
gbar() {
    local f=$1 i r g b
    BAR=""
    for ((i = 0; i < BARW; i++)); do
        if (( i < f )); then
            r=$(( 167 + (103 - 167) * i / (BARW - 1) ))
            g=$(( 139 + (232 - 139) * i / (BARW - 1) ))
            b=$(( 250 + (249 - 250) * i / (BARW - 1) ))
            BAR+=$'\033[38;2;'"$r;$g;${b}m━"
        else
            BAR+="${DARK}─"
        fi
    done
    BAR+="$R"
}

STEP=0
TOTAL=0

# run "message" command args...
run() {
    local msg="$1"; shift
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local i=0 t0=$SECONDS el pct
    STEP=$((STEP + 1))

    echo "=== [$STEP/$TOTAL] $msg ===" >> "$LOG"
    "$@" >> "$LOG" 2>&1 < /dev/null &
    local pid=$!

    gbar $(( (STEP - 1) * BARW / TOTAL ))
    pct=$(( (STEP - 1) * 100 / TOTAL ))

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        el=$((SECONDS - t0))
        printf '\r\033[K   %s%s%s %s%d/%d%s  %s%-34s%s %s %s%3d%%%s %s%3ds%s' \
            "$PURPLE" "${frames[$((i % 10))]}" "$R" \
            "$GRAY" "$STEP" "$TOTAL" "$R" \
            "$TEXT" "$msg" "$R" \
            "$BAR" "$GRAY" "$pct" "$R" "$DIM$GRAY" "$el" "$R"
        i=$((i + 1))
        sleep 0.08
    done

    local rc=0
    wait "$pid" || rc=$?
    tput cnorm 2>/dev/null || true
    el=$((SECONDS - t0))
    printf '\r\033[K'

    if (( rc == 0 )); then
        gbar $(( STEP * BARW / TOTAL ))
        printf '   %s✔%s %s%d/%d%s  %s%-34s%s %s %s%3d%%%s %s%3ds%s\n' \
            "$GREEN" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" \
            "$TEXT" "$msg" "$R" \
            "$BAR" "$GRAY" $(( STEP * 100 / TOTAL )) "$R" "$DIM$GRAY" "$el" "$R"
    else
        printf '   %s✘%s %s%d/%d%s  %s%s%s\n' "$RED" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" "$TEXT" "$msg" "$R"
        rail_top "Step failed — last log lines" "$RED"
        tail -n 12 "$LOG" | while IFS= read -r l; do rail "${DIM}${l}${R}"; done
        rail_end
        fail "Full log: $LOG"
        exit 1
    fi
}

summary() {
    local t=$((SECONDS - T0)) took
    took=$(printf '%dm %02ds' $((t / 60)) $((t % 60)))
    echo
    printf '   %s╭%s╮%s\n' "$GREEN" "$HR" "$R"
    printf '   %s│%s %s✔%s  %s%s%-46s%s%s│%s\n' "$GREEN" "$R" "$GREEN$B" "$R" "$B" "$TEXT" "$1" "$R" "$GREEN" "$R"
    printf '   %s│%s    %s%-46s%s%s│%s\n' "$GREEN" "$R" "$GRAY" "Finished in $took" "$R" "$GREEN" "$R"
    printf '   %s╰%s╯%s\n' "$GREEN" "$HR" "$R"
    echo
}

# confirm "question" [default: 0=yes 1=no] [lead]   ->  return 0 for yes
confirm() {
    local q="$1" sel="${2:-1}" lead="${3:-◆}" key k2 yes no
    tput civis 2>/dev/null || true
    while true; do
        if [ "$sel" -eq 0 ]; then
            yes="${BG_GREEN}${B} Yes ${R}"; no="${GRAY} No ${R}"
        else
            yes="${GRAY} Yes ${R}"; no="${BG_RED}${B} No ${R}"
        fi
        printf '\r\033[K   %s%s%s %s%s%s   %s %s   %s←/→ · y/n · Enter%s' \
            "$PURPLE" "$lead" "$R" "$B$TEXT" "$q" "$R" "$yes" "$no" "$DIM$GRAY" "$R"
        key=""
        IFS= read -rsn1 key || key=""
        case "$key" in
            $'\033') k2=""; read -rsn2 -t 0.05 k2 || true
                     case "$k2" in '[C'|'[D') sel=$((1 - sel)) ;; esac ;;
            y|Y)     sel=0; break ;;
            n|N)     sel=1; break ;;
            h|l|$'\t'|' ') sel=$((1 - sel)) ;;
            "")      break ;;
        esac
    done
    tput cnorm 2>/dev/null || true
    local ans="${RED}No${R}"
    [ "$sel" -eq 0 ] && ans="${GREEN}Yes${R}"
    printf '\r\033[K   %s%s%s %s%s%s  %s%s\n' "$PURPLE" "$lead" "$R" "$TEXT" "$q" "$R" "$B" "$ans$R"
    return "$sel"
}

ask_reboot() {
    echo
    if confirm "Reboot now?" 1; then
        info "Rebooting..."
        sudo reboot
    else
        info "Reboot skipped."
    fi
}

# ---------- arrow-key menu ----------
MENU_ITEMS=("Update system" "Full installation" "Uninstall lshell" "Exit")
MENU_DESC=("Refresh databases and upgrade all packages" "Install Sway, Waybar, Rofi, Kitty and configs" "Remove LShell configs and packages" "Leave the installer")
MENU_ICONS=("↻" "✦" "✖" "↩")
MENU_ACC=("$CYAN" "$PURPLE" "$RED" "$GRAY")
MENU_CHOICE=0

menu() {
    local sel=0 key k2 n=${#MENU_ITEMS[@]} i acc ic ti de
    tput civis 2>/dev/null || true
    while true; do
        for i in "${!MENU_ITEMS[@]}"; do
            acc="${MENU_ACC[$i]}"; ic="${MENU_ICONS[$i]}"; ti="${MENU_ITEMS[$i]}"; de="${MENU_DESC[$i]}"
            if [ "$i" -eq "$sel" ]; then
                printf '\r\033[K   %s▌%s%s  %s%s  %s%-46s%s\n' "$acc" "$R" "$BG_SEL" "$acc$B" "$ic" "$TEXT$B" "$ti" "$R"
                printf '\r\033[K   %s▌%s%s     %s%-46s%s\n' "$acc" "$R" "$BG_SEL" "$GRAY" "$de" "$R"
            else
                printf '\r\033[K       %s%s  %s%-46s%s\n' "$GRAY" "$ic" "$TEXT" "$ti" "$R"
                printf '\r\033[K         %s%-46s%s\n' "$DIM$GRAY" "$de" "$R"
            fi
            printf '\r\033[K\n'
        done
        key=""
        IFS= read -rsn1 key || key=""
        if [[ "$key" == $'\033' ]]; then
            k2=""; read -rsn2 -t 0.01 k2 || true
            case "$k2" in
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
        printf '\033[%dA' $((n * 3))
    done
    tput cnorm 2>/dev/null || true
    MENU_CHOICE=$sel
}

# ============================================================
#  CHECKS
# ============================================================

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

start_sudo() {
    sudo -v
    ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    KEEPALIVE_PID=$!
}

# ============================================================
#  CONFLICT HANDLING
# ============================================================

# resolve_conflicts <pacman args...>
# Dry-runs the transaction, finds "A and B are in conflict" and
# asks whether to remove the conflicting installed packages.
resolve_conflicts() {
    info "Checking for package conflicts"
    local out lines line new old tgt
    local -a targets=()

    out=$(sudo pacman "$@" --print --noconfirm 2>&1 || true)
    lines=$(grep -E '^:: .+ and .+ are in conflict' <<< "$out" || true)

    if [ -z "$lines" ]; then
        ok "No package conflicts"
        return 0
    fi

    rail_top "Package conflicts detected" "$YELLOW"
    while IFS= read -r line; do
        new=$(sed -E 's/^:: *([^ ]+) and ([^ ]+) are in conflict.*/\1/' <<< "$line")
        old=$(sed -E 's/^:: *([^ ]+) and ([^ ]+) are in conflict.*/\2/' <<< "$line")
        new=${new%%[<>=]*}
        old=${old%%[<>=]*}

        tgt=""
        if pacman -Qq "$old" &> /dev/null; then
            tgt="$old"
        elif pacman -Qq "$new" &> /dev/null; then
            tgt="$new"
        fi

        rail "${TEXT}${new}${R}  ${YELLOW}⟷${R}  ${TEXT}${old}${R}"
        if [ -n "$tgt" ] && [[ " ${targets[*]:-} " != *" $tgt "* ]]; then
            targets+=("$tgt")
        fi
    done <<< "$lines"

    if [ ${#targets[@]} -eq 0 ]; then
        rail "${GRAY}Nothing installed to remove — resolve manually if the next step fails.${R}"
        rail_end
        return 0
    fi

    rail ""
    rail "${GRAY}Will remove:${R} ${YELLOW}${targets[*]}${R}"

    if confirm "Remove conflicting packages?" 1 "╰─"; then
        if sudo pacman -Rdd --noconfirm "${targets[@]}" >> "$LOG" 2>&1; then
            ok "Removed: ${targets[*]}"
        else
            fail "Could not remove conflicting packages. See $LOG"
            exit 1
        fi
    else
        warn "Conflicts left in place — the next step may fail."
    fi
}

# offer_remove <installed-pkg> <reason>
offer_remove() {
    local pkg="$1" reason="$2"
    pacman -Qq "$pkg" &> /dev/null || return 0
    rail_top "Package conflict" "$YELLOW"
    rail "${TEXT}${pkg}${R}  ${GRAY}${reason}${R}"
    if confirm "Remove $pkg?" 1 "╰─"; then
        if sudo pacman -Rdd --noconfirm "$pkg" >> "$LOG" 2>&1; then
            ok "Removed: $pkg"
        else
            fail "Could not remove $pkg. See $LOG"
            exit 1
        fi
    else
        warn "$pkg kept — the next step may fail."
    fi
}

# ============================================================
#  ACTIONS
# ============================================================

do_update() {
    TOTAL=2
    start_sudo
    echo

    run "Refreshing package databases" sudo pacman -Syy
    resolve_conflicts -Su
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

CORE_PKGS=(
    git autotiling swaybg waybar kitty rofi
    papirus-icon-theme ttf-fira-code ttf-jetbrains-mono-nerd
    ttf-nerd-fonts-symbols ttf-font-awesome noto-fonts-emoji
    gsimplecal wtype rofi-emoji dolphin bluez bluez-utils blueman
    nwg-displays fastfetch python python-pip polkit-gnome
    python-cryptography python-requests python-beautifulsoup4
    python-rich wl-clipboard swaync lutris ppsspp qbittorrent
)

do_install() {
    TOTAL=9
    start_sudo
    BUILD_DIR=$(mktemp -d)
    echo

    run "Refreshing package databases" sudo pacman -Syy
    resolve_conflicts -Su
    run "Upgrading system" sudo pacman -Su --noconfirm

    resolve_conflicts -S --needed "${CORE_PKGS[@]}"
    run "Installing core packages" sudo pacman -S --needed --noconfirm "${CORE_PKGS[@]}"

    run "Installing AUR packages" yay -S --needed --noconfirm waypaper wlogout grim slurp
    run "Building scenefx0.5" build_aur scenefx0.5

    offer_remove sway "conflicts with swayfx"
    run "Building swayfx" build_aur swayfx

    run "Generating fastfetch config" fastfetch --gen-config
    run "Removing old waybar config" rm -rf "$HOME/.config/waybar/config.jsonc"
    run "Installing lshell configs" install_configs

    summary "Installation completed successfully"
    ask_reboot
}

do_uninstall() {
    TOTAL=3

    rail_top "Uninstall LShell" "$RED"
    rail "${GRAY}This removes LShell configs from ~/.config and its packages.${R}"
    if ! confirm "Continue?" 1 "╰─"; then
        info "Cancelled."
        exit 0
    fi

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
printf '   %s%sSelect an action%s   %s↑/↓ or 1-4 · Enter to confirm%s\n\n' "$B" "$TEXT" "$R" "$DIM$GRAY" "$R"
menu

case "$MENU_CHOICE" in
    0) do_update ;;
    1) do_install ;;
    2) do_uninstall ;;
    3) info "Exiting."; exit 0 ;;
esac
