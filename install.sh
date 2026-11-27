#!/bin/bash
set -Eeuo pipefail

# ============================================================
#  LSHELL INSTALLER  (3D edition · v1.4 · multi-distro)
#  Arch / Debian / Fedora (and derivatives) - auto-detected
#  Override detection:  LSHELL_DISTRO=arch|debian|fedora ./lshell-installer.sh
# ============================================================

LOG="/tmp/lshell-installer.log"
MISSING_FILE="/tmp/lshell-missing.tmp"
FXFAIL_FILE="/tmp/lshell-fxfail.tmp"
MANIFEST_DIR="$HOME/.local/share/lshell"
MANIFEST="$MANIFEST_DIR/manifest"
SRC_DIR="$MANIFEST_DIR/src"
NERD_DIR="$HOME/.local/share/fonts/lshell-nerd"
REPO_URL="https://github.com/deploydy/lshell-play"
VERSION="1.4"
T0=$SECONDS

export DEBIAN_FRONTEND=noninteractive

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
#  DISTRO DETECTION
# ============================================================

FAMILY=""
DISTRO_NAME="Linux"

osr() {
    if [ -r /etc/os-release ]; then
        sed -n "s/^$1=//p" /etc/os-release | head -n1 | tr -d '"'
    fi
}

detect_distro() {
    local id like all
    id=$(osr ID || true)
    like=$(osr ID_LIKE || true)
    DISTRO_NAME=$(osr PRETTY_NAME || true)
    if [ -z "$DISTRO_NAME" ]; then DISTRO_NAME="Linux"; fi
    all=" ${id} ${like} "

    case "$all" in
        *" arch "* | *" archlinux "*)   FAMILY="arch" ;;
        *" debian "* | *" ubuntu "*)    FAMILY="debian" ;;
        *" fedora "*)                   FAMILY="fedora" ;;
    esac

    if [ -z "$FAMILY" ]; then
        if   command -v pacman  &> /dev/null; then FAMILY="arch"
        elif command -v apt-get &> /dev/null; then FAMILY="debian"
        elif command -v dnf     &> /dev/null; then FAMILY="fedora"
        fi
    fi

    if [ -n "${LSHELL_DISTRO:-}" ]; then FAMILY="$LSHELL_DISTRO"; fi
}

# ============================================================
#  PACKAGE MANAGER ABSTRACTION
# ============================================================

apt_get() { sudo env DEBIAN_FRONTEND=noninteractive apt-get -y "$@"; }

pkg_refresh() {
    case "$FAMILY" in
        arch)   sudo pacman -Syy ;;
        debian) apt_get update ;;
        fedora) sudo dnf -y makecache --refresh ;;
    esac
}

pkg_upgrade() {
    case "$FAMILY" in
        arch)   sudo pacman -Su --noconfirm ;;
        debian) apt_get upgrade ;;
        fedora) sudo dnf -y upgrade --refresh ;;
    esac
}

pkg_installed() {
    case "$FAMILY" in
        arch)   pacman -Qq "$1" &> /dev/null ;;
        debian) [[ "$(dpkg-query -W -f='${Status}' "$1" 2> /dev/null || true)" == *"install ok installed"* ]] ;;
        fedora) rpm -q "$1" &> /dev/null ;;
    esac
}

pkg_try_install() {
    case "$FAMILY" in
        arch)   sudo pacman -S --needed --noconfirm "$1" ;;
        debian) apt_get install "$1" ;;
        fedora) sudo dnf -y install "$1" ;;
    esac
}

pkg_remove() {
    case "$FAMILY" in
        arch)   sudo pacman -Rns --noconfirm "$1" ;;
        debian) apt_get remove "$1" ;;
        fedora) sudo dnf -y remove "$1" ;;
    esac
}

# pkg_install_tolerant <spec...>
# spec = "name" or "alt1|alt2|alt3" (first alternative that exists wins).
# Packages missing from the repos are collected in $MISSING_FILE instead of aborting.
pkg_install_tolerant() {
    local spec alt ok
    local -a alts
    : > "$MISSING_FILE"
    for spec in "$@"; do
        ok=0
        IFS='|' read -ra alts <<< "$spec"
        for alt in "${alts[@]}"; do
            if pkg_installed "$alt"; then ok=1; break; fi
            if pkg_try_install "$alt"; then ok=1; break; fi
        done
        if (( ok == 0 )); then
            echo "$spec" >> "$MISSING_FILE"
            echo "!! not available: $spec"
        fi
    done
    return 0
}

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
#  3D LOGO
#  extruded block letters · lit top edge · shaded bottom edge
#  fading depth layers · light sweep (shimmer) · floor reflection
# ============================================================

LOGO_DEPTH=3
LOGO_W=0
LOGO_H=0
LOGO_LW=0
LOGO_CELLS=()
LOGO_MASK=()
LCR=(); LCG=(); LCB=()

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
    LOGO_MASK=("${mask[@]}")

    local units=${#mask[0]}
    local lw=$(( units * 2 ))
    LOGO_LW=$lw
    LOGO_H=$(( 5 + LOGO_DEPTH ))
    LOGO_W=$(( lw + 2 * LOGO_DEPTH ))
    LOGO_CELLS=(); LCR=(); LCG=(); LCB=()

    for ((y = 0; y < LOGO_H; y++)); do
        for ((x = 0; x < LOGO_W; x++)); do
            cell=" "; cr=-1; cg=-1; cb=-1
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
                        cr=$(( GR * pct / 100 ))
                        cg=$(( GG * pct / 100 ))
                        cb=$(( GB * pct / 100 ))
                        printf -v cell '\033[38;2;%d;%d;%dm█' "$cr" "$cg" "$cb"
                        break
                    fi
                done
            fi
            LOGO_CELLS+=("$cell")
            LCR+=("$cr"); LCG+=("$cg"); LCB+=("$cb")
        done
    done
}

# print_logo <revealed-width> [sweep-position]
# cells inside the sweep band are lit up on the fly, the rest are cached
print_logo() {
    local w=$1 s=${2:--100} y x line idx d t cr cg cb cell
    for ((y = 0; y < LOGO_H; y++)); do
        line="   "
        for ((x = 0; x < LOGO_W; x++)); do
            if (( x >= w )); then
                line+=" "
                continue
            fi
            idx=$(( y * LOGO_W + x ))
            d=$(( x + 2 * y - s ))
            if (( d < 0 )); then d=$(( -d )); fi
            if (( d < 8 && LCR[idx] >= 0 )); then
                t=$(( (8 - d) * 55 / 8 ))
                cr=$(( LCR[idx] + (255 - LCR[idx]) * t / 100 ))
                cg=$(( LCG[idx] + (255 - LCG[idx]) * t / 100 ))
                cb=$(( LCB[idx] + (255 - LCB[idx]) * t / 100 ))
                printf -v cell '\033[38;2;%d;%d;%dm█' "$cr" "$cg" "$cb"
                line+="$cell"
            else
                line+="${LOGO_CELLS[$idx]}"
            fi
        done
        printf '%s%s\n' "$line" "$R"
    done
}

# soft floor reflection of the front face, fading out
print_reflection() {
    local k y x line cell
    local -a fac=(46 30 18)
    local -a chr=("▒" "▒" "░")
    for ((k = 0; k < 3; k++)); do
        y=$(( 4 - k ))
        line="   "
        for ((x = 0; x < LOGO_W; x++)); do
            if (( x < LOGO_LW )) && [ "${LOGO_MASK[$y]:$((x / 2)):1}" = "X" ]; then
                grad_rgb "$x" $(( LOGO_W - 1 ))
                printf -v cell '\033[38;2;%d;%d;%dm%s' \
                    $(( GR * fac[k] / 100 )) $(( GG * fac[k] / 100 )) $(( GB * fac[k] / 100 )) "${chr[$k]}"
                line+="$cell"
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
        local w s
        # reveal left -> right
        for ((w = 2; w <= LOGO_W; w += 3)); do
            print_logo "$w"
            printf '\033[%dA' "$LOGO_H"
            sleep 0.012
        done
        # light sweep, top-left -> bottom-right
        for ((s = -6; s <= LOGO_W + 2 * LOGO_H + 6; s += 3)); do
            print_logo "$LOGO_W" "$s"
            printf '\033[%dA' "$LOGO_H"
            sleep 0.008
        done
    fi
    print_logo "$LOGO_W"
    print_reflection

    local sub="Liquid Shell · installer · v$VERSION"
    local pad=$(( (LOGO_W - ${#sub}) / 2 ))
    if (( pad < 0 )); then pad=0; fi
    printf '   %*s%s%s%s\n' "$pad" '' "$GRAY" "$sub" "$R"
    grad_line "━" "$LOGO_W"
    printf '   %s\n' "$LINE"
    echo
    printf '   %s◆%s %sSway%s %s·%s %sWaybar%s %s·%s %sRofi%s %s·%s %sKitty%s\n' \
        "$PURPLE" "$R" "$CYAN" "$R" "$DARK" "$R" "$BLUE" "$R" "$DARK" "$R" "$PURPLE" "$R" "$DARK" "$R" "$PINK" "$R"
    printf '   %s%s%s\n' "$DIM$GRAY" "$REPO_URL" "$R"
    printf '   %s%s · %s@%s%s\n' "$DIM$GRAY" "$DISTRO_NAME" "${USER:-user}" "${HOSTNAME:-host}" "$R"
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

# smooth gradient progress bar -> $BAR
# gbar <units>   (BARW * 8 units = 100%, 1/8-cell resolution)
BARW=24
BAR=""
gbar() {
    local u=$1 full rem i
    local -a part=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
    full=$(( u / 8 )); rem=$(( u % 8 ))
    BAR=""
    for ((i = 0; i < BARW; i++)); do
        if (( i < full )); then
            grad_rgb "$i" $(( BARW - 1 ))
            BAR+=$'\033[38;2;'"$GR;$GG;${GB}m█"
        elif (( i == full && rem > 0 )); then
            grad_rgb "$i" $(( BARW - 1 ))
            BAR+=$'\033[38;2;'"$GR;$GG;${GB}m${part[$rem]}"
        else
            BAR+="${SHADOW}░"
        fi
    done
    BAR+="$R"
}

STEP=0
TOTAL=0
SOFT=0
SOFT_FAILED=0

# run "message" command args...
# the bar creeps forward while a step is running, then snaps to the step end
# with SOFT=1 (see run_soft) a failing step is reported and skipped instead of aborting
run() {
    local msg="$1"; shift
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local i=0 t0=$SECONDS el pct p sc ease units
    STEP=$((STEP + 1))
    SOFT_FAILED=0

    echo "=== [$STEP/$TOTAL] $msg ===" >> "$LOG"
    "$@" >> "$LOG" 2>&1 < /dev/null &
    local pid=$!

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        el=$((SECONDS - t0))
        ease=$(( 1000 * i / (i + 120) ))
        units=$(( ((STEP - 1) * 1000 + ease) * BARW * 8 / (TOTAL * 1000) ))
        pct=$(( ((STEP - 1) * 1000 + ease) * 100 / (TOTAL * 1000) ))
        gbar "$units"
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
        gbar $(( STEP * BARW * 8 / TOTAL ))
        printf '   %s✔%s %s%d/%d%s  %s%-34s%s %s %s%3d%%%s %s%3ds%s\n' \
            "$GREEN" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" \
            "$TEXT" "$msg" "$R" \
            "$BAR" "$GRAY" $(( STEP * 100 / TOTAL )) "$R" "$DIM$GRAY" "$el" "$R"
    elif (( SOFT )); then
        SOFT_FAILED=1
        printf '   %s▲%s %s%d/%d%s  %s%-34s%s %s(skipped — see %s)%s\n' \
            "$YELLOW" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" "$TEXT" "$msg" "$R" "$GRAY" "$LOG" "$R"
    else
        printf '   %s✘%s %s%d/%d%s  %s%s%s\n' "$RED" "$R" "$GRAY" "$STEP" "$TOTAL" "$R" "$TEXT" "$msg" "$R"
        rail_top "Step failed — last log lines" "$RED"
        tail -n 12 "$LOG" | while IFS= read -r l; do rail "${DIM}${l}${R}"; done
        rail_end
        fail "Full log: $LOG"
        exit 1
    fi
}

run_soft() { SOFT=1; run "$@"; SOFT=0; }

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
# pill-style buttons: the active one is filled with rounded caps
confirm() {
    local q="$1" sel="${2:-1}" lead="${3:-◆}" key k2 yes no
    tput civis 2>/dev/null || true
    while true; do
        if [ "$sel" -eq 0 ]; then
            yes="${GREEN}▐${BG_GREEN}${B} Yes ${R}${GREEN}▌${R}"; no="${GRAY}  No  ${R}"
        else
            yes="${GRAY}  Yes  ${R}"; no="${RED}▐${BG_RED}${B} No ${R}${RED}▌${R}"
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

# ---------- framed arrow-key menu (gradient border, glowing selection) ----------
MENU_ITEMS=("Update system" "Full installation" "Uninstall lshell" "Exit")
MENU_DESC=("Refresh databases and upgrade all packages" "Install Sway, Waybar, Rofi, Kitty and configs" "Remove LShell configs and packages" "Leave the installer")
MENU_ICONS=("↻" "✦" "✖" "↩")
MENU_ACC=("$CYAN" "$PURPLE" "$RED" "$GRAY")
MENU_CHOICE=0
MW=56

menu() {
    local sel=0 key k2 n=${#MENU_ITEMS[@]} i acc ic ti de blank
    printf -v blank '%*s' "$MW" ''

    grad_line "─" "$MW"
    printf '   %s╭%s%s╮%s\n' "$CYAN" "$LINE" "$PINK" "$R"

    tput civis 2>/dev/null || true
    while true; do
        for i in "${!MENU_ITEMS[@]}"; do
            acc="${MENU_ACC[$i]}"; ic="${MENU_ICONS[$i]}"; ti="${MENU_ITEMS[$i]}"; de="${MENU_DESC[$i]}"
            if [ "$i" -eq "$sel" ]; then
                printf '\r\033[K   %s│%s%s%s▌%s %s%s  %s%-51s%s%s│%s\n' \
                    "$CYAN" "$R" "$BG_SEL" "$acc" "$BG_SEL" "$acc$B" "$ic" "$TEXT$B" "$ti" "$R" "$PINK" "$R"
                printf '\r\033[K   %s│%s%s%s▌%s    %s%-51s%s%s│%s\n' \
                    "$CYAN" "$R" "$BG_SEL" "$acc" "$BG_SEL" "$GRAY" "$de" "$R" "$PINK" "$R"
            else
                printf '\r\033[K   %s│%s  %s%s  %s%-51s%s%s│%s\n' \
                    "$CYAN" "$R" "$GRAY" "$ic" "$TEXT" "$ti" "$R" "$PINK" "$R"
                printf '\r\033[K   %s│%s   %s  %s%-51s%s%s│%s\n' \
                    "$CYAN" "$R" "$GRAY" "$DIM$GRAY" "$de" "$R" "$PINK" "$R"
            fi
            printf '\r\033[K   %s│%s%s%s│%s\n' "$CYAN" "$R" "$blank" "$PINK" "$R"
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

    grad_line "─" "$MW"
    printf '   %s╰%s%s╯%s\n' "$CYAN" "$LINE" "$PINK" "$R"
    MENU_CHOICE=$sel
}

# ============================================================
#  CHECKS
# ============================================================

detect_distro

if [ "$EUID" -eq 0 ]; then
    banner; fail "Do not run this script as root!"; exit 1
fi
case "$FAMILY" in
    arch)
        if ! command -v pacman &> /dev/null; then
            banner; fail "pacman not found."; exit 1
        fi
        if ! command -v yay &> /dev/null; then
            banner; fail "yay is not installed."; exit 1
        fi
        ;;
    debian)
        if ! command -v apt-get &> /dev/null; then
            banner; fail "apt-get not found."; exit 1
        fi
        ;;
    fedora)
        if ! command -v dnf &> /dev/null; then
            banner; fail "dnf not found."; exit 1
        fi
        ;;
    *)
        banner; fail "Unsupported distribution: $DISTRO_NAME"
        info "Supported: Arch, Debian/Ubuntu, Fedora (and derivatives)"
        info "Force a family with: LSHELL_DISTRO=arch|debian|fedora"
        exit 1
        ;;
esac
if ! command -v sudo &> /dev/null; then
    banner; fail "sudo is not installed."; exit 1
fi

: > "$LOG"
: > "$MISSING_FILE"
rm -f "$FXFAIL_FILE"

start_sudo() {
    sudo -v
    ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    KEEPALIVE_PID=$!
}

# ============================================================
#  CONFLICT HANDLING   (pacman only)
# ============================================================

# resolve_conflicts <pacman args...>
# Dry-runs the transaction, finds "A and B are in conflict" and
# asks whether to remove the conflicting installed packages.
resolve_conflicts() {
    if [ "$FAMILY" != "arch" ]; then return 0; fi
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

# offer_remove <installed-pkg> <reason>   (pacman only)
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

# report_missing  ->  shows packages that the repos of this distro do not have
report_missing() {
    if [ -s "$MISSING_FILE" ]; then
        local l
        rail_top "Not available in your repositories" "$YELLOW"
        while IFS= read -r l; do rail "${TEXT}${l}${R}"; done < "$MISSING_FILE"
        rail "${GRAY}Skipped — install them manually if you need them.${R}"
        rail_end
    fi
}

# ============================================================
#  PACKAGE LISTS
# ============================================================

CORE_ARCH=(
    git autotiling swaybg waybar kitty rofi
    papirus-icon-theme ttf-fira-code ttf-jetbrains-mono-nerd
    ttf-nerd-fonts-symbols otf-font-awesome noto-fonts-emoji
    gsimplecal wtype rofi-emoji dolphin bluez bluez-utils blueman
    nwg-displays fastfetch python python-pip polkit-gnome
    python-cryptography python-requests python-beautifulsoup4
    python-rich wl-clipboard swaync lutris ppsspp qbittorrent
)

# "a|b" = alternatives, first one found in the repos is installed
CORE_DEBIAN=(
    git curl tar xz-utils fontconfig
    swaybg waybar kitty rofi
    papirus-icon-theme fonts-firacode fonts-font-awesome fonts-noto-color-emoji
    gsimplecal wtype rofi-emoji dolphin bluez blueman
    fastfetch python3 python3-pip pipx python3-gi gir1.2-gtk-3.0
    "policykit-1-gnome|polkit-gnome"
    python3-cryptography python3-requests python3-bs4 python3-rich
    wl-clipboard "sway-notification-center|swaync" wlogout grim slurp
    lutris ppsspp qbittorrent
)

CORE_FEDORA=(
    git curl tar xz fontconfig
    swaybg waybar kitty "rofi-wayland|rofi"
    papirus-icon-theme fira-code-fonts jetbrains-mono-fonts
    "fontawesome-fonts-all|fontawesome-fonts" google-noto-emoji-fonts
    gsimplecal wtype rofi-emoji dolphin bluez blueman nwg-displays
    fastfetch python3 python3-pip pipx python3-gobject gtk3 polkit-gnome
    python3-cryptography python3-requests python3-beautifulsoup4 python3-rich
    wl-clipboard SwayNotificationCenter wlogout grim slurp
    lutris ppsspp qbittorrent
)

# build dependencies for SwayFX on Debian (missing names are skipped)
SWAYFX_BUILD_DEPS_DEBIAN=(
    meson ninja-build cmake pkg-config scdoc git wayland-protocols libwayland-dev
    libxkbcommon-dev libegl-dev libgles-dev libgbm-dev libdrm-dev libpixman-1-dev
    libjson-c-dev libpcre2-dev libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev
    libevdev-dev libinput-dev libseat-dev libudev-dev libsystemd-dev glslang-tools
    libvulkan-dev libliftoff-dev libdisplay-info-dev hwdata
    libxcb1-dev libxcb-composite0-dev libxcb-icccm4-dev libxcb-render0-dev
    libxcb-xfixes0-dev libxcb-res0-dev libxcb-dri3-dev libxcb-present-dev
    libxcb-ewmh-dev libxcb-errors-dev libxcb-shm0-dev libxcb-xinput-dev
)

PIP_TOOLS=(autotiling waypaper nwg-displays)

# ============================================================
#  ACTIONS - building blocks
# ============================================================

build_aur() {
    local name="$1"
    ( cd "$BUILD_DIR" \
      && git clone "https://aur.archlinux.org/$name.git" \
      && cd "$name" \
      && makepkg -si --noconfirm )
}

# Nerd Fonts (JetBrains Mono + symbols) for distros that do not package them
install_nerd_fonts() {
    local tmp f base="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
    mkdir -p "$NERD_DIR"
    tmp=$(mktemp -d)
    for f in JetBrainsMono NerdFontsSymbolsOnly; do
        curl -fsSL "$base/$f.tar.xz" -o "$tmp/$f.tar.xz" || { rm -rf "$tmp"; return 1; }
        tar -xJf "$tmp/$f.tar.xz" -C "$NERD_DIR" || { rm -rf "$tmp"; return 1; }
    done
    rm -rf "$tmp"
    fc-cache -f "$NERD_DIR"
}

# autotiling / waypaper / nwg-displays are not packaged on Debian, some not on Fedora
install_pip_tools() {
    local tool b
    for tool in "${PIP_TOOLS[@]}"; do
        if command -v "$tool" &> /dev/null; then continue; fi
        if command -v pipx &> /dev/null; then
            pipx install --system-site-packages "$tool" || echo "!! failed: $tool"
        else
            python3 -m pip install --user --break-system-packages "$tool" || echo "!! failed: $tool"
        fi
    done
    for b in "${PIP_TOOLS[@]}"; do
        if [ -x "$HOME/.local/bin/$b" ]; then
            sudo ln -sf "$HOME/.local/bin/$b" "/usr/local/bin/$b"
        fi
    done
    return 0
}

# ---------- SwayFX ----------

WANT_FX=1

choose_swayfx() {
    case "$FAMILY" in
        debian)
            rail_top "SwayFX" "$PURPLE"
            rail "${GRAY}SwayFX is not packaged for Debian. It can be built from source${R}"
            rail "${GRAY}(slow, may fail). Otherwise stock sway is installed and the${R}"
            rail "${GRAY}blur / rounded corners / shadows from the config will not work.${R}"
            if confirm "Build SwayFX from source?" 0 "╰─"; then WANT_FX=1; else WANT_FX=0; fi
            ;;
        fedora)
            rail_top "SwayFX" "$PURPLE"
            rail "${GRAY}SwayFX is installed from the swayfx/swayfx COPR repository.${R}"
            if pkg_installed sway; then
                rail "${GRAY}It will replace the installed stock sway.${R}"
            fi
            if confirm "Use SwayFX?" 0 "╰─"; then WANT_FX=1; else WANT_FX=0; fi
            ;;
    esac
}

build_swayfx_src() {
    local name d
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    apt_get build-dep sway || echo "build-dep unavailable (deb-src not enabled) - installing dependencies by name"
    for d in "${SWAYFX_BUILD_DEPS_DEBIAN[@]}"; do
        if pkg_installed "$d"; then continue; fi
        pkg_try_install "$d" || echo "!! dependency not available: $d"
    done
    for d in libwlroots-0.19-dev libwlroots-0.18-dev libwlroots-dev; do
        if pkg_installed "$d" || pkg_try_install "$d"; then break; fi
    done

    mkdir -p "$SRC_DIR" || return 1
    for name in scenefx swayfx; do
        rm -rf "${SRC_DIR:?}/$name"
        git clone --depth 1 "https://github.com/WillPower3309/$name.git" "$SRC_DIR/$name" || return 1
        meson setup "$SRC_DIR/$name/build" "$SRC_DIR/$name" \
            --prefix=/usr/local --libdir=lib --buildtype=release || return 1
        ninja -C "$SRC_DIR/$name/build" || return 1
        sudo ninja -C "$SRC_DIR/$name/build" install || return 1
        sudo ldconfig || true
    done
    return 0
}

install_sway_debian() {
    rm -f "$FXFAIL_FILE"
    apt_get install sway || return 1
    if (( WANT_FX == 0 )); then return 0; fi
    if build_swayfx_src; then return 0; fi
    : > "$FXFAIL_FILE"
    return 0
}

install_sway_fedora() {
    rm -f "$FXFAIL_FILE"
    if (( WANT_FX )); then
        sudo dnf -y install dnf-plugins-core || true
        if sudo dnf -y copr enable swayfx/swayfx && sudo dnf -y install --allowerasing swayfx; then
            return 0
        fi
        : > "$FXFAIL_FILE"
    fi
    sudo dnf -y install sway
}

report_fx_failure() {
    if [ -e "$FXFAIL_FILE" ]; then
        warn "SwayFX could not be installed — stock sway is used instead."
        warn "Blur, rounded corners and shadows in the sway config will not work (see $LOG)."
    fi
}

# ---------- configs ----------

# the polkit agent lives in a different place on every distro
patch_configs() {
    if [ "$FAMILY" = "arch" ]; then return 0; fi
    local agent="" p f
    for p in /usr/libexec/polkit-gnome-authentication-agent-1 \
             /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
             /usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1; do
        if [ -x "$p" ]; then agent="$p"; break; fi
    done
    if [ -z "$agent" ] || [ ! -d "$HOME/.config/sway" ]; then return 0; fi
    while IFS= read -r f; do
        sed -i -E "s#[^ \"']*polkit-gnome-authentication-agent-1#$agent#g" "$f"
    done < <(grep -rlI 'polkit-gnome-authentication-agent-1' "$HOME/.config/sway" 2>/dev/null || true)
    return 0
}

install_configs() {
    rm -rf "$HOME/lshell-play"
    git clone "$REPO_URL" "$HOME/lshell-play"
    mkdir -p "$HOME/.config" "$MANIFEST_DIR"
    ( cd "$HOME/lshell-play" && ls -A | grep -vx '.git' ) > "$MANIFEST"
    cp -r "$HOME/lshell-play/"* "$HOME/.config/"
    rm -rf "$HOME/lshell-play"
    patch_configs
}

# ============================================================
#  ACTIONS
# ============================================================

do_update() {
    TOTAL=2
    start_sudo
    echo

    run "Refreshing package databases" pkg_refresh
    resolve_conflicts -Su
    run "Upgrading packages" pkg_upgrade

    summary "Update completed"
    ask_reboot
}

install_stack_arch() {
    resolve_conflicts -S --needed "${CORE_ARCH[@]}"
    run "Installing core packages" sudo pacman -S --needed --noconfirm "${CORE_ARCH[@]}"

    run "Installing AUR packages" yay -S --needed --noconfirm waypaper wlogout grim slurp
    run "Building scenefx0.5" build_aur scenefx0.5

    offer_remove sway "conflicts with swayfx"
    run "Building swayfx" build_aur swayfx
}

install_stack_debian() {
    run_soft "Installing core packages" pkg_install_tolerant "${CORE_DEBIAN[@]}"
    report_missing
    run_soft "Installing Nerd Fonts" install_nerd_fonts
    run_soft "Installing Python tools" install_pip_tools
    if (( WANT_FX )); then
        run_soft "Installing sway + building swayfx" install_sway_debian
    else
        run_soft "Installing sway" install_sway_debian
    fi
    report_fx_failure
}

install_stack_fedora() {
    run_soft "Installing core packages" pkg_install_tolerant "${CORE_FEDORA[@]}"
    report_missing
    run_soft "Installing Nerd Fonts" install_nerd_fonts
    run_soft "Installing Python tools" install_pip_tools
    run_soft "Installing swayfx" install_sway_fedora
    report_fx_failure
}

do_install() {
    TOTAL=9
    start_sudo
    BUILD_DIR=$(mktemp -d)
    echo

    choose_swayfx

    run "Refreshing package databases" pkg_refresh
    resolve_conflicts -Su
    run "Upgrading system" pkg_upgrade

    case "$FAMILY" in
        arch)   install_stack_arch ;;
        debian) install_stack_debian ;;
        fedora) install_stack_fedora ;;
    esac

    if [ "$FAMILY" = "arch" ]; then
        run "Generating fastfetch config" fastfetch --gen-config
    else
        run_soft "Generating fastfetch config" fastfetch --gen-config
    fi
    run "Removing old waybar config" rm -rf "$HOME/.config/waybar/config.jsonc"
    run "Installing lshell configs" install_configs

    summary "Installation completed successfully"
    ask_reboot
}

# ---------- uninstall helpers ----------

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
    return 0
}

remove_source_builds() {
    local name b
    for name in swayfx scenefx; do
        b="$SRC_DIR/$name/build"
        if [ -d "$b" ]; then sudo ninja -C "$b" uninstall || true; fi
    done
    if [ -d "$SRC_DIR" ]; then sudo ldconfig || true; fi
    rm -rf "$SRC_DIR"
    return 0
}

remove_pip_tools() {
    local tool
    for tool in "${PIP_TOOLS[@]}"; do
        if command -v pipx &> /dev/null && pipx list --short 2> /dev/null | grep -q "^$tool "; then
            pipx uninstall "$tool" || true
        fi
        if [ -L "/usr/local/bin/$tool" ]; then sudo rm -f "/usr/local/bin/$tool"; fi
    done
    return 0
}

remove_packages() {
    local -a candidates=()
    local pkg had_fx=0
    case "$FAMILY" in
        arch)
            candidates=(swayfx scenefx0.5 waypaper wlogout autotiling swaybg waybar rofi rofi-emoji swaync nwg-displays gsimplecal) ;;
        debian)
            candidates=(waybar rofi rofi-emoji sway-notification-center swaync wlogout swaybg gsimplecal) ;;
        fedora)
            candidates=(swayfx waybar rofi rofi-wayland rofi-emoji SwayNotificationCenter wlogout swaybg gsimplecal nwg-displays) ;;
    esac

    if [ "$FAMILY" = "fedora" ] && pkg_installed swayfx; then had_fx=1; fi

    for pkg in "${candidates[@]}"; do
        if pkg_installed "$pkg"; then
            pkg_remove "$pkg" || true
        fi
    done

    if [ "$FAMILY" != "arch" ]; then
        remove_source_builds
        remove_pip_tools
        rm -rf "$NERD_DIR"
        if command -v fc-cache &> /dev/null; then fc-cache -f || true; fi
    fi
    if (( had_fx )); then
        sudo dnf -y copr disable swayfx/swayfx || true
        sudo dnf -y install sway || true
    fi
    return 0
}

do_uninstall() {
    TOTAL=3

    rail_top "Uninstall LShell" "$RED"
    rail "${GRAY}This removes LShell configs from ~/.config and its packages.${R}"
    if [ "$FAMILY" != "arch" ]; then
        rail "${GRAY}Stock sway is left installed so your session keeps working.${R}"
    fi
    if ! confirm "Continue?" 1 "╰─"; then
        info "Cancelled."
        exit 0
    fi

    start_sudo
    echo

    run "Removing lshell configs" remove_configs
    run "Removing lshell packages" remove_packages
    run "Cleaning up" bash -c 'rm -rf "$HOME/lshell-play" "$1" /tmp/lshell-*.tmp' _ "$MANIFEST_DIR"

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
