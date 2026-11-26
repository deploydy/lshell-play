#!/bin/bash
set -Eeuo pipefail

# ============================================================
#  LSHELL INSTALLER  (3D edition)
# ============================================================

LOG="/tmp/lshell-installer.log"
MANIFEST_DIR="$HOME/.local/share/lshell"
MANIFEST="$MANIFEST_DIR/manifest"
REPO_URL="https://github.com/deploydy/lshell-play"
VERSION="1.2"
T0=$SECONDS

# ---------- palette (truecolor) ----------
R=$'\033[0m'
B=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[38;2;0;229;255m'
BLUE=$'\033[38;2;80;170;255m'
PURPLE=$'\033[38;2;150;110;255m'
PINK=$'\033[38;2;255;100;210m'
GREEN=$'\033[38;2;134;239;172m'
YELLOW=$'\033[38;2;253;224;71m'
RED=$'\033[38;2;248;113;113m'
TEXT=$'\033[38;2;228;228;236m'
GRAY=$'\033[38;2;130;130;150m'
DARK=$'\033[38;2;60;58;90m'
SHADOW=$'\033[38;2;38;36;62m'
BG_SEL=$'\033[48;2;34;30;66m'
BG_GREEN=$'\033[48;2;134;239;172m\033[38;2;20;20;30m'
BG_RED=$'\033[48;2;248;113;113m\033[38;2;20;20;30m'

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
#  GRADIENT HELPERS   cyan -> violet -> pink
# ============================================================

GR=0; GG=0; GB=0
# grad_rgb <pos> <max>  ->  sets GR GG GB
grad_rgb() {
    local t=$(( $1 * 1000 / $2 ))
    if (( t <= 500 )); then
        GR=$(( 0 + (150 - 0) * t / 500 ))
        GG=$(( 229 + (110 - 229) * t / 500 ))
        GB=255
    else
        t=$(( t - 500 ))
        GR=$(( 150 + (255 - 150) * t / 500 ))
        GG=$(( 110 + (100 - 110) * t / 500 ))
        GB=$(( 255 + (210 - 255) * t / 500 ))
    fi
}

# grad_line <char> <width>  ->  $LINE
LINE=""
grad_line() {
    local ch="$1" w=$2 i
    LINE=""
    for ((i = 0; i < w; i++)); do
        grad_rgb "$i" $(( w - 1 ))
        LINE+=$'\033[38;2;'"$GR;$GG;${GB}m$ch"
    done
    LINE+="$R"
}

# ============================================================
#  3D LOGO  (extruded block letters: lit top edge, shaded
#            bottom edge, diagonal depth with fading layers)
# ============================================================

LOGO_DEPTH=3
LOGO_W=0
LOGO_H=0
LOGO_CELLS=()

build_logo() {
    local -A G=(
        [L]="X..X..X..X..XXX"
        [S]="XXXX..XXX..XXXX"
        [H]="X.XX.XXXXX.XX.X"
        [E]="XXXX..XX.X..XXX"
    )
    local word="LSHELL" r k ch row x y cell d sy sx pct cr cg cb
    local -a mask=()

    for ((r = 0; r < 5; r++)); do
        row=""
        for ((k = 0; k < ${#word}; k++)); do
            ch="${word:k:1}"
            row+="${G[$ch]:$((r * 3)):3}"
            if (( k < ${#word} - 1 )); then row+="."; fi
        done
        mask+=("$row")
    done

    local units=${#mask[0]}
    local lw=$(( units * 2 ))
    LOGO_H=$(( 5 + LOGO_DEPTH ))
    LOGO_W=$(( lw + 2 * LOGO_DEPTH ))
    LOGO_CELLS=()

    for ((y = 0; y < LOGO_H; y++)); do
        for ((x = 0; x < LOGO_W; x++)); do
            cell=" "
            if (( y < 5 && x < lw )) && [ "${mask[$y]:$((x / 2)):1}" = "X" ]; then
                # ---- front face ----
                grad_rgb "$x" $(( LOGO_W - 1 ))
                cr=$GR; cg=$GG; cb=$GB
                if (( y == 0 )) || [ "${mask[$((y - 1))]:$((x / 2)):1}" != "X" ]; then
                    # lit top edge
                    cr=$(( cr + (255 - cr) * 55 / 100 ))
                    cg=$(( cg + (255 - cg) * 55 / 100 ))
                    cb=$(( cb + (255 - cb) * 55 / 100 ))
                elif (( y == 4 )) || [ "${mask[$((y + 1))]:$((x / 2)):1}" != "X" ]; then
                    # shaded bottom edge
                    cr=$(( cr * 72 / 100 ))
                    cg=$(( cg * 72 / 100 ))
                    cb=$(( cb * 72 / 100 ))
                fi
                printf -v cell '\033[38;2;%d;%d;%dm█' "$cr" "$cg" "$cb"
            else
                # ---- extrusion: nearest layer wins, farther = darker ----
                for ((d = 1; d <= LOGO_DEPTH; d++)); do
                    sy=$(( y - d ))
                    sx=$(( x - 2 * d ))
                    if (( sy >= 0 && sy < 5 && sx >= 0 && sx < lw )) \
                       && [ "${mask[$sy]:$((sx / 2)):1}" = "X" ]; then
                        grad_rgb "$x" $(( LOGO_W - 1 ))
                        pct=$(( 62 - (d - 1) * 17 ))
                        printf -v cell '\033[38;2;%d;%d;%dm█' \
                            $(( GR * pct / 100 )) $(( GG * pct / 100 )) $(( GB * pct / 100 ))
                        break
                    fi
                done
            fi
            LOGO_CELLS+=("$cell")
        done
    done
}

print_logo() {
    local w=$1 y x line
    for ((y = 0; y < LOGO_H; y++)); do
        line="   "
        for ((x = 0; x < LOGO_W; x++)); do
            if (( x < w )); then
                line+="${LOGO_CELLS[$((y * LOGO_W + x))]}"
            else
                line+=" "
            fi
        done
        printf '%s%s\n' "$line" "$R"
    done
}

# ============================================================
#  UI HELPERS
# ============================================================

banner() {
    clear
    if [ "$LOGO_W" -eq 0 ]; then build_logo; fi
    echo

    if [ "${ANIM:-0}" = "1" ] && [ -t 1 ]; then
        local w
        for ((w = 2; w <= LOGO_W; w += 3)); do
            print_logo "$w"
            printf '\033[%dA' "$LOGO_H"
            sleep 0.012
        done
    fi
    print_logo "$LOGO_W"

    echo
    printf '   %*s%sLiquid Shell · installer · v%s%s\n' 8 '' "$GRAY" "$VERSION" "$R"
    grad_line "▀" "$LOGO_W"
    printf '   %s\n' "$LINE"
    echo
    printf '   %s◆%s %sSway%s %s·%s %sWaybar%s %s·%s %sRofi%s %s·%s %sKitty%s\n' \
        "$PURPLE" "$R" "$CYAN" "$R" "$DARK" "$R" "$BLUE" "$R" "$DARK" "$R" "$PURPLE" "$R" "$DARK" "$R" "$PINK" "$R"
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

# 3D gradient progress bar -> $BAR   (solid fill, recessed track)
BARW=20
BAR=""
gbar() {
    local f=$1 i
    BAR=""
    for ((i = 0; i < BARW; i++)); do
        if (( i < f )); then
            grad_rgb "$i" $(( BARW - 1 ))
            BAR+=$'\033[38;2;'"$GR;$GG;${GB}m█"
        else
            BAR+="${SHADOW}░"
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
    local i=0 t0=$SECONDS el pct p sc
    STEP=$((STEP + 1))

    echo "=== [$STEP/$TOTAL] $msg ===" >> "$LOG"
    "$@" >> "$LOG" 2>&1 < /dev/null &
    local pid=$!

    gbar $(( (STEP - 1) * BARW / TOTAL ))
    pct=$(( (STEP - 1) * 100 / TOTAL ))

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        el=$((SECONDS - t0))
        p=$(( i % 40 )); if [ "$p" -gt 20 ]; then p=$(( 40 - p )); fi
        grad_rgb "$p" 20
        sc=$'\033[38;2;'"$GR;$GG;${GB}m"
        printf '\r\033[K   %s%s%s %s%d/%d%s  %s%-34s%s %s %s%3d%%%s %s%3ds%s' \
            "$sc" "${frames[$((i % 10))]}" "$R" \
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

# floating summary card with a drop shadow
summary() {
    local t=$((SECONDS - T0)) took sh
    took=$(printf '%dm %02ds' $((t / 60)) $((t % 60)))
    printf -v sh '▒%.0s' $(seq 1 52)
    grad_line "─" 50
    echo
    printf '   %s╭%s%s╮%s\n' "$CYAN" "$LINE" "$PINK" "$R"
    printf '   %s│%s %s✔%s  %s%s%-46s%s%s│%s%s▒%s\n' "$CYAN" "$R" "$GREEN$B" "$R" "$B" "$TEXT" "$1" "$R" "$PINK" "$R" "$SHADOW" "$R"
    printf '   %s│%s    %s%-46s%s%s│%s%s▒%s\n' "$CYAN" "$R" "$GRAY" "Finished in $took" "$R" "$PINK" "$R" "$SHADOW" "$R"
    printf '   %s╰%s%s╯%s%s▒%s\n' "$CYAN" "$LINE" "$PINK" "$R" "$SHADOW" "$R"
    printf '    %s%s%s\n' "$SHADOW" "$sh" "$R"
    echo
}

# confirm "question" [default: 0=yes 1=no] [lead]   ->  return 0 for yes
confirm() {
    local q="$1" sel="${2:-1}" lead="${3:-◆}" key k2 yes no
    tput civis 2>/dev/null || true
    while true; do
        if [ "$sel" -eq 0 ]; then
            yes="${BG_GREEN}${B} Yes ${R}${SHADOW}▌${R}"; no="${GRAY} No ${R}"
        else
            yes="${GRAY} Yes ${R}"; no="${BG_RED}${B} No ${R}${SHADOW}▌${R}"
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

# ---------- arrow-key menu (raised selected "button") ----------
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
                printf '\r\033[K   %s█%s%s  %s%s  %s%-46s%s%s▐%s\n' "$acc" "$R" "$BG_SEL" "$acc$B" "$ic" "$TEXT$B" "$ti" "$R" "$SHADOW" "$R"
                printf '\r\033[K   %s█%s%s     %s%-46s%s%s▐%s\n' "$acc" "$R" "$BG_SEL" "$GRAY" "$de" "$R" "$SHADOW" "$R"
                printf '\r\033[K    %s▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀%s\n' "$SHADOW" "$R"
            else
                printf '\r\033[K       %s%s  %s%-46s%s\n' "$GRAY" "$ic" "$TEXT" "$ti" "$R"
                printf '\r\033[K         %s%-46s%s\n' "$DIM$GRAY" "$de" "$R"
                printf '\r\033[K\n'
            fi
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
    ttf-nerd-fonts-symbols otf-font-awesome noto-fonts-emoji
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

ANIM=1 banner
printf '   %s%sSelect an action%s   %s↑/↓ or 1-4 · Enter to confirm%s\n\n' "$B" "$TEXT" "$R" "$DIM$GRAY" "$R"
menu

case "$MENU_CHOICE" in
    0) do_update ;;
    1) do_install ;;
    2) do_uninstall ;;
    3) info "Exiting."; exit 0 ;;
esac
