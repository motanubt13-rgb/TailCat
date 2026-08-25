#!/usr/bin/env bash
set -Eeuo pipefail

# VastWin - Windows Server 2025 deployer for Vast.ai KVM VMs
# Public release 1.0.1
#
# Normal mode keeps the interface compact and mobile-terminal safe.
# Use --verbose for additional diagnostics.

readonly SCRIPT_NAME="VastWin"
readonly VERSION="1.0.1"
readonly TOTAL_STEPS=6

readonly DEFAULT_USER="CloudUser"
readonly DEFAULT_PASS="VastGaming1"

readonly HF_REPO="MotanuB/vastwin-backup"
readonly HF_REVISION="925722ddf093617a3ea798ee5c72b444e8b41234"
readonly HF_FILE="win2025-master.raw.lz4"

readonly EXPECTED_SHA256="ca7ec9cb32d4be460e0d8e5f35e1373e54df9e8d060eb04137f84d2b686d6a20"
readonly EXPECTED_COMPRESSED_BYTES=11971744939
readonly EXPECTED_RAW_BYTES=32212254720

# Verified 30 GiB master layout.
readonly EFI_PARTITION_OFFSET=1048576
readonly EFI_PARTITION_SIZE=134217728
readonly WINDOWS_PARTITION_OFFSET=269484032
readonly WINDOWS_PARTITION_SIZE=31942753792

readonly TARGET_DISK="${TARGET_DISK:-/dev/vda}"
readonly DOWNLOAD_DIR="${VASTWIN_DOWNLOAD_DIR:-/var/tmp/vastwin-download}"
readonly DISK_IMAGE="${DOWNLOAD_DIR}/${HF_FILE}"
readonly HF_VENV="${DOWNLOAD_DIR}/.hf-venv"
readonly HF_HOME_DIR="${DOWNLOAD_DIR}/.hf-home"

readonly RAM_MOUNT="/mnt/vastwin-takeover"
readonly RAM_SIZE="14G"
readonly RAM_MARGIN_BYTES=$((2 * 1024 * 1024 * 1024))
readonly MIN_DOWNLOAD_FREE_BYTES=$((24 * 1024 * 1024 * 1024))
readonly XET_CONCURRENCY="${VASTWIN_XET_CONCURRENCY:-16}"

readonly STEP_LOG="/tmp/vastwin-step-$$.log"
readonly STATUS_FILE="/tmp/vastwin-status-$$"

TAKEOVER_LAUNCHED=0
ACTIVE_PID=""
UI_ENABLED=0
VERBOSE=0

C_RESET=""
C_BOLD=""
C_DIM=""
C_CYAN=""
C_GREEN=""
C_YELLOW=""
C_RED=""

SPINNER=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

usage() {
    cat <<EOF
VastWin ${VERSION}

Usage:
  ./vastwin.sh [--verbose]

Options:
  --verbose, -v   Show additional diagnostics when a step fails.
  --help, -h      Show this help.

Optional environment variables:
  HF_TOKEN                    Hugging Face read-only token.
  VASTWIN_XET_CONCURRENCY     Xet concurrency (1-64, default 16).
  VASTWIN_DOWNLOAD_DIR        Disk-backed download directory.
  TARGET_DISK                 Target boot disk (default /dev/vda).
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --verbose|-v)
                VERBOSE=1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf '[VastWin] ERROR: Unknown option: %s\n' "$1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

init_ui() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
        UI_ENABLED=1

        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_CYAN=$'\033[36m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_RED=$'\033[31m'
    fi
}

banner() {
    printf '\n'
    printf '%s╭──────────────────────────────────────────────╮%s\n' "$C_CYAN" "$C_RESET"
    printf '%s│%s%s                  VastWin                     %s%s│%s\n' \
        "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '%s│%s          Windows Server 2025 Setup           %s│%s\n' \
        "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '%s╰──────────────────────────────────────────────╯%s\n' "$C_CYAN" "$C_RESET"
    printf '%sPublic release %s%s\n\n' "$C_DIM" "$VERSION" "$C_RESET"
}

set_status() {
    printf '%s\n' "$*" > "$STATUS_FILE"
}

get_status() {
    if [[ -s "$STATUS_FILE" ]]; then
        head -n1 "$STATUS_FILE" 2>/dev/null || true
    fi
}

clear_active_line() {
    if (( UI_ENABLED )); then
        printf '\r\033[2K'
    fi
}

render_detail() {
    local detail="$1"

    [[ -n "$detail" ]] || return 0

    clear_active_line

    printf '      %s%s%s\n' \
        "$C_DIM" \
        "$detail" \
        "$C_RESET"
}

render_active() {
    local step="$1"
    local label="$2"
    local frame="$3"
    local elapsed="$4"

    if (( UI_ENABLED )); then
        clear_active_line

        printf '%s[%d/%d]%s %-21s %s%s%s %s%ss%s' \
            "$C_CYAN" \
            "$step" \
            "$TOTAL_STEPS" \
            "$C_RESET" \
            "$label" \
            "$C_YELLOW" \
            "$frame" \
            "$C_RESET" \
            "$C_DIM" \
            "$elapsed" \
            "$C_RESET"
    fi
}

render_done() {
    local step="$1"
    local label="$2"

    clear_active_line

    printf '%s[%d/%d]%s %-21s %s✓%s\n' \
        "$C_CYAN" \
        "$step" \
        "$TOTAL_STEPS" \
        "$C_RESET" \
        "$label" \
        "$C_GREEN" \
        "$C_RESET"
}

render_failed() {
    local step="$1"
    local label="$2"

    clear_active_line

    printf '%s[%d/%d]%s %-21s %s✗%s\n' \
        "$C_CYAN" \
        "$step" \
        "$TOTAL_STEPS" \
        "$C_RESET" \
        "$label" \
        "$C_RED" \
        "$C_RESET" >&2
}

make_bar() {
    local percent="$1"
    local width=10
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local i

    for ((i=0; i<filled; i++)); do
        bar+="█"
    done

    for ((i=0; i<empty; i++)); do
        bar+="░"
    done

    printf '%s' "$bar"
}

format_eta() {
    local seconds="$1"

    if (( seconds < 0 )); then
        printf '%s' '--'
    elif (( seconds < 60 )); then
        printf '%ss' "$seconds"
    else
        printf '%dm%02ds' \
            "$((seconds / 60))" \
            "$((seconds % 60))"
    fi
}

render_progress_line() {
    local percent="$1"
    local mibps="$2"
    local eta="${3:-}"
    local bar

    (( percent < 0 )) && percent=0
    (( percent > 100 )) && percent=100

    bar="$(make_bar "$percent")"

    clear_active_line

    printf '      %s %3d%%' \
        "$bar" \
        "$percent"

    if (( mibps > 0 )); then
        printf '  %d MiB/s' "$mibps"
    fi

    if [[ -n "$eta" ]]; then
        printf '  ETA %s' "$eta"
    fi
}

print_progress_header() {
    local step="$1"
    local label="$2"

    printf '%s[%d/%d]%s %s\n' \
        "$C_CYAN" \
        "$step" \
        "$TOTAL_STEPS" \
        "$C_RESET" \
        "$label"
}

fatal() {
    printf '[VastWin] ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf '%s!%s %s\n' \
        "$C_YELLOW" \
        "$C_RESET" \
        "$*" >&2
}

show_step_error() {
    local clean_log
    local explicit_error

    clean_log="$(
        sed -r 's/\x1B\[[0-9;]*[mK]//g' \
            "$STEP_LOG" 2>/dev/null || true
    )"

    explicit_error="$(
        printf '%s\n' "$clean_log" |
            grep -F '[VastWin] ERROR:' |
            tail -n1 || true
    )"

    printf '\n'

    if [[ -n "$explicit_error" ]]; then
        printf '%s\n' "$explicit_error" >&2
    else
        printf '[VastWin] ERROR: This step could not be completed.\n' >&2
    fi

    if (( VERBOSE )); then
        printf '\n--- verbose step log ---\n' >&2
        printf '%s\n' "$clean_log" | tail -n 30 >&2
        printf '%s\n' '--- end log ---' >&2
    fi
}

cleanup() {
    local rc=$?

    set +e

    if [[ -n "$ACTIVE_PID" ]]; then
        kill "$ACTIVE_PID" 2>/dev/null || true
        wait "$ACTIVE_PID" 2>/dev/null || true
        ACTIVE_PID=""
    fi

    rm -f "$STEP_LOG" "$STATUS_FILE" 2>/dev/null || true

    if [[ "$TAKEOVER_LAUNCHED" -eq 1 ]]; then
        return "$rc"
    fi

    mountpoint -q "$RAM_MOUNT/dev" &&
        umount -l "$RAM_MOUNT/dev"

    mountpoint -q "$RAM_MOUNT/proc" &&
        umount -l "$RAM_MOUNT/proc"

    mountpoint -q "$RAM_MOUNT/sys" &&
        umount -l "$RAM_MOUNT/sys"

    mountpoint -q "$RAM_MOUNT/oldroot" &&
        umount -l "$RAM_MOUNT/oldroot"

    mountpoint -q "$RAM_MOUNT" &&
        umount -l "$RAM_MOUNT"

    rm -rf "$RAM_MOUNT" 2>/dev/null || true

    return "$rc"
}

on_signal() {
    trap - EXIT INT TERM

    cleanup

    printf '\n[VastWin] Deployment cancelled.\n' >&2
    exit 130
}

trap cleanup EXIT
trap on_signal INT TERM

run_stage() {
    local step="$1"
    local label="$2"

    shift 2

    : > "$STEP_LOG"
    : > "$STATUS_FILE"

    if (( ! UI_ENABLED )); then
        printf '[%d/%d] %s...\n' \
            "$step" \
            "$TOTAL_STEPS" \
            "$label"
    fi

    "$@" >"$STEP_LOG" 2>&1 &
    ACTIVE_PID=$!

    local start="$SECONDS"
    local i=0
    local detail=""
    local last_detail=""
    local rc=0

    while kill -0 "$ACTIVE_PID" 2>/dev/null; do
        detail="$(get_status)"

        if [[ -n "$detail" &&
              "$detail" != "$last_detail" ]]; then

            render_detail "$detail"
            last_detail="$detail"
        fi

        if (( UI_ENABLED )); then
            render_active \
                "$step" \
                "$label" \
                "${SPINNER[$((i % ${#SPINNER[@]}))]}" \
                "$((SECONDS - start))"

            i=$((i + 1))

        elif (( VERBOSE )) &&
             [[ -n "$detail" &&
                "$detail" != "$last_detail" ]]; then

            printf '      %s\n' "$detail"
        fi

        sleep 0.15
    done

    if wait "$ACTIVE_PID"; then
        rc=0
    else
        rc=$?
    fi

    ACTIVE_PID=""

    if (( rc == 0 )); then
        render_done "$step" "$label"
        return 0
    fi

    render_failed "$step" "$label"
    show_step_error

    return "$rc"
}

require_root() {
    [[ "${EUID}" -eq 0 ]] ||
        fatal "Run this script as root."
}

validate_xet_concurrency() {
    [[ "$XET_CONCURRENCY" =~ ^[0-9]+$ ]] ||
        fatal "VASTWIN_XET_CONCURRENCY must be an integer."

    (( XET_CONCURRENCY >= 1 &&
       XET_CONCURRENCY <= 64 )) ||
        fatal "VASTWIN_XET_CONCURRENCY must be between 1 and 64."
}

dependencies_present() {
    local cmd

    for cmd in \
        curl \
        python3 \
        lz4 \
        sgdisk \
        lsblk \
        blockdev \
        findmnt \
        fsfreeze \
        losetup \
        mount \
        umount \
        mountpoint \
        busybox \
        ntfs-3g \
        modprobe \
        chroot \
        sha256sum \
        stat; do

        command -v "$cmd" >/dev/null 2>&1 ||
            return 1
    done

    python3 -m venv --help >/dev/null 2>&1 ||
        return 1

    return 0
}

disable_automatic_apt() {
    set_status "Stopping automatic Linux updates..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop \
            apt-daily.timer \
            apt-daily-upgrade.timer \
            apt-daily.service \
            apt-daily-upgrade.service \
            unattended-upgrades.service \
            >/dev/null 2>&1 || true

        systemctl mask --runtime \
            apt-daily.timer \
            apt-daily-upgrade.timer \
            apt-daily.service \
            apt-daily-upgrade.service \
            unattended-upgrades.service \
            >/dev/null 2>&1 || true
    fi

    mkdir -p /etc/apt/apt.conf.d

    cat > /etc/apt/apt.conf.d/99-vastwin-disable-auto-updates <<'EOF_APT'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF_APT
}

install_dependencies() {
    if dependencies_present; then
        set_status "Deployment tools already available"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export APT_LISTCHANGES_FRONTEND=none

    set_status "Updating package lists..."

    apt-get \
        -o DPkg::Lock::Timeout=180 \
        update -y

    set_status "Installing deployment tools..."

    apt-get \
        -o DPkg::Lock::Timeout=180 \
        -o Dpkg::Options::="--force-confold" \
        install -y \
        ca-certificates \
        curl \
        python3 \
        python3-venv \
        lz4 \
        gdisk \
        util-linux \
        coreutils \
        busybox-static \
        ntfs-3g \
        kmod

    dependencies_present ||
        fatal "Required Linux deployment tools are still missing after installation."

    set_status "Linux deployment tools ready"
}

get_root_disk() {
    local source
    local parent

    source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"

    [[ -n "$source" ]] ||
        return 1

    source="$(
        readlink -f "$source" 2>/dev/null ||
            printf '%s' "$source"
    )"

    parent="$(
        lsblk -ndo PKNAME "$source" 2>/dev/null |
            head -n1 || true
    )"

    [[ -n "$parent" ]] ||
        return 1

    printf '/dev/%s' "$parent"
}

validate_environment() {
    set_status "Validating KVM, UEFI and target disk..."

    [[ -b "$TARGET_DISK" ]] ||
        fatal "Target disk $TARGET_DISK does not exist."

    [[ "$(lsblk -dn -o TYPE "$TARGET_DISK" 2>/dev/null)" == "disk" ]] ||
        fatal "$TARGET_DISK is not a whole block disk."

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --quiet --container; then
            fatal "Run VastWin inside the Vast.ai KVM VM, not inside a container."
        fi
    fi

    [[ -d /sys/firmware/efi ]] ||
        fatal "This VM is not booted in UEFI mode."

    local disk_bytes
    local root_disk

    disk_bytes="$(blockdev --getsize64 "$TARGET_DISK")"

    (( disk_bytes >= EXPECTED_RAW_BYTES )) ||
        fatal "The target disk is smaller than the Windows master image."

    root_disk="$(get_root_disk || true)"

    [[ -n "$root_disk" ]] ||
        fatal "Unable to determine the Linux root disk."

    [[ "$root_disk" == "$TARGET_DISK" ]] ||
        fatal "Linux root is on $root_disk, not $TARGET_DISK. Takeover cancelled."

    set_status "System ready"
}

system_check_stage() {
    disable_automatic_apt
    install_dependencies
    validate_environment
}

prompt_settings() {
    read -r -p "Windows username [${DEFAULT_USER}]: " WIN_USER
    WIN_USER="${WIN_USER:-$DEFAULT_USER}"

    read -r -s -p "Windows password [${DEFAULT_PASS}]: " WIN_PASS
    printf '\n'

    WIN_PASS="${WIN_PASS:-$DEFAULT_PASS}"

    [[ ${#WIN_USER} -ge 1 &&
       ${#WIN_USER} -le 20 ]] ||
        fatal "Windows username must contain 1-20 characters."

    [[ "$WIN_USER" != *$'\n'* &&
       "$WIN_USER" != *$'\r'* ]] ||
        fatal "Username cannot contain newline or carriage return."

    [[ ! "$WIN_USER" =~ [\\/\[\]:\;\|=,\+\*\?\<\>\"] ]] ||
        fatal "Username contains a character not accepted by Windows."

    [[ "$WIN_USER" != "." &&
       "$WIN_USER" != ".." ]] ||
        fatal "Invalid Windows username."

    [[ "$WIN_PASS" != *$'\n'* &&
       "$WIN_PASS" != *$'\r'* ]] ||
        fatal "Password cannot contain newline or carriage return."

    if [[ -z "${HF_TOKEN:-}" ]]; then
        read -r -s -p "Hugging Face token: " HF_TOKEN
        printf '\n'
    fi

    [[ -n "${HF_TOKEN:-}" ]] ||
        fatal "A Hugging Face token is required."

    printf '\n'
}

print_system_summary() {
    local disk_size
    local available_kb
    local available_gib

    disk_size="$(
        lsblk -dn -o SIZE "$TARGET_DISK" 2>/dev/null |
            xargs
    )"

    available_kb="$(
        awk '/MemAvailable:/ {print $2}' /proc/meminfo
    )"

    available_gib=$(( available_kb / 1024 / 1024 ))

    printf '\n'
    printf '  %-15s %s\n' \
        "Target disk" \
        "$TARGET_DISK — $disk_size"

    printf '  %-15s %s\n' \
        "Available RAM" \
        "${available_gib} GiB"

    printf '  %-15s %s\n' \
        "Image" \
        "Windows Server 2025"

    printf '  %-15s %s\n\n' \
        "Source" \
        "Private Hugging Face"
}

check_download_storage() {
    mkdir -p "$DOWNLOAD_DIR"
    chmod 700 "$DOWNLOAD_DIR"

    local fstype
    local available

    fstype="$(
        findmnt -n -o FSTYPE -T "$DOWNLOAD_DIR" \
            2>/dev/null || true
    )"

    [[ "$fstype" != "tmpfs" &&
       "$fstype" != "ramfs" ]] ||
        fatal "$DOWNLOAD_DIR is RAM-backed. Download staging must be on disk."

    available="$(
        df -PB1 "$DOWNLOAD_DIR" |
            awk 'NR==2 {print $4}'
    )"

    [[ -n "$available" ]] ||
        fatal "Unable to determine free download space."

    if [[ -f "$DISK_IMAGE" ]]; then
        return 0
    fi

    (( available >= MIN_DOWNLOAD_FREE_BYTES )) ||
        fatal "At least 24 GiB of free Linux disk space is required."
}

prepare_hf_client() {
    set_status "Checking download storage..."
    check_download_storage

    set_status "Preparing Hugging Face Xet client..."

    if [[ ! -x "$HF_VENV/bin/python" ]]; then
        python3 -m venv "$HF_VENV"
    fi

    if ! "$HF_VENV/bin/python" - <<'PY' >/dev/null 2>&1
import huggingface_hub
import hf_xet
PY
    then
        set_status "Installing Hugging Face Xet client..."

        "$HF_VENV/bin/python" -m pip install \
            --disable-pip-version-check \
            --quiet \
            --upgrade \
            huggingface_hub \
            hf_xet
    fi

    [[ -x "$HF_VENV/bin/hf" ]] ||
        fatal "The Hugging Face download client could not be installed."

    set_status "Xet ready"
}

get_rx_bytes() {
    awk '
        NR > 2 {
            iface=$1
            gsub(":", "", iface)

            if (iface != "lo") {
                sum += $2
            }
        }

        END {
            printf "%.0f", sum + 0
        }
    ' /proc/net/dev
}

get_download_disk_bytes() {
    local bytes=0
    local b
    local file

    if [[ -f "$DISK_IMAGE" ]]; then
        b="$(
            stat -c '%s' "$DISK_IMAGE" \
                2>/dev/null || printf '0'
        )"

        (( b > bytes )) &&
            bytes="$b"
    fi

    while IFS= read -r -d '' file; do
        b="$(
            stat -c '%b' "$file" \
                2>/dev/null || printf '0'
        )"

        b=$(( b * 512 ))

        (( b > bytes )) &&
            bytes="$b"

    done < <(
        find "$DOWNLOAD_DIR/.cache/huggingface" \
            -type f \
            -name "*${HF_FILE}*.incomplete" \
            -print0 \
            2>/dev/null || true
    )

    printf '%s' "$bytes"
}

download_master_to_disk() {
    mkdir -p "$DOWNLOAD_DIR" "$HF_HOME_DIR"
    chmod 700 "$DOWNLOAD_DIR" "$HF_HOME_DIR"

    if [[ -f "$DISK_IMAGE" ]]; then
        local existing_size

        existing_size="$(
            stat -c '%s' "$DISK_IMAGE" \
                2>/dev/null || printf '0'
        )"

        if [[ "$existing_size" == "$EXPECTED_COMPRESSED_BYTES" ]]; then
            set_status "Existing image found"
            return 0
        fi

        rm -f "$DISK_IMAGE"
    fi

    set_status "Downloading with Xet..."

    if ! env \
        HF_TOKEN="$HF_TOKEN" \
        HF_HOME="$HF_HOME_DIR" \
        HF_XET_CACHE="$HF_HOME_DIR/xet" \
        HF_XET_CHUNK_CACHE_SIZE_BYTES=0 \
        HF_XET_FIXED_DOWNLOAD_CONCURRENCY="$XET_CONCURRENCY" \
        HF_HUB_DISABLE_PROGRESS_BARS=1 \
        HF_HUB_DOWNLOAD_TIMEOUT=60 \
        HF_HUB_ETAG_TIMEOUT=30 \
        "$HF_VENV/bin/hf" download \
            "$HF_REPO" \
            "$HF_FILE" \
            --revision "$HF_REVISION" \
            --local-dir "$DOWNLOAD_DIR"; then

        fatal "Hugging Face download failed. Check the token or network connection."
    fi

    [[ -f "$DISK_IMAGE" ]] ||
        fatal "The Windows master was not downloaded."
}

run_download_stage() {
    local step=3
    local label="Downloading Windows"

    : > "$STEP_LOG"
    : > "$STATUS_FILE"

    print_progress_header "$step" "$label"

    download_master_to_disk >"$STEP_LOG" 2>&1 &
    ACTIVE_PID=$!

    local start_time="$SECONDS"
    local start_rx
    local current_rx
    local network_bytes
    local disk_bytes
    local progress_bytes
    local elapsed
    local percent
    local mibps
    local remaining
    local eta_seconds
    local eta
    local detail
    local last_detail=""
    local rc=0

    start_rx="$(get_rx_bytes)"

    while kill -0 "$ACTIVE_PID" 2>/dev/null; do
        elapsed=$(( SECONDS - start_time ))

        (( elapsed > 0 )) ||
            elapsed=1

        current_rx="$(get_rx_bytes)"
        network_bytes=$(( current_rx - start_rx ))

        (( network_bytes < 0 )) &&
            network_bytes=0

        disk_bytes="$(get_download_disk_bytes)"
        progress_bytes="$network_bytes"

        (( disk_bytes > progress_bytes )) &&
            progress_bytes="$disk_bytes"

        percent=$(( progress_bytes * 100 / EXPECTED_COMPRESSED_BYTES ))

        (( percent > 99 )) &&
            percent=99

        (( percent < 0 )) &&
            percent=0

        mibps=$(( network_bytes / elapsed / 1024 / 1024 ))

        if (( network_bytes > 0 &&
             mibps > 0 )); then

            remaining=$(( EXPECTED_COMPRESSED_BYTES - progress_bytes ))

            (( remaining < 0 )) &&
                remaining=0

            eta_seconds=$(( remaining / (mibps * 1024 * 1024) ))
            eta="$(format_eta "$eta_seconds")"
        else
            eta="--"
        fi

        detail="$(get_status)"

        if [[ -n "$detail" &&
              "$detail" != "$last_detail" ]]; then

            clear_active_line
            printf '      %s%s%s\n' \
                "$C_DIM" \
                "$detail" \
                "$C_RESET"

            last_detail="$detail"
        fi

        if (( UI_ENABLED )); then
            render_progress_line \
                "$percent" \
                "$mibps" \
                "$eta"
        fi

        sleep 0.25
    done

    if wait "$ACTIVE_PID"; then
        rc=0
    else
        rc=$?
    fi

    ACTIVE_PID=""

    if (( rc == 0 )); then
        render_progress_line 100 0 ""
        printf '\n'
        render_done "$step" "$label"
        return 0
    fi

    render_failed "$step" "$label"
    show_step_error

    return "$rc"
}

verify_disk_master() {
    local size
    local actual_hash

    set_status "Checking image size..."

    [[ -f "$DISK_IMAGE" ]] ||
        fatal "The downloaded Windows master is missing."

    size="$(
        stat -c '%s' "$DISK_IMAGE" \
            2>/dev/null || printf '0'
    )"

    if [[ "$size" != "$EXPECTED_COMPRESSED_BYTES" ]]; then
        rm -f "$DISK_IMAGE"

        fatal "Windows image size verification failed."
    fi

    set_status "Checking SHA-256..."

    actual_hash="$(
        sha256sum "$DISK_IMAGE" |
            awk '{print $1}'
    )"

    if [[ "$actual_hash" != "$EXPECTED_SHA256" ]]; then
        rm -f "$DISK_IMAGE"

        fatal "Windows image SHA-256 verification failed."
    fi

    set_status "Checking LZ4 archive..."

    if ! lz4 -t "$DISK_IMAGE" >/dev/null 2>&1; then
        rm -f "$DISK_IMAGE"

        fatal "Windows image LZ4 verification failed."
    fi

    set_status "Image verified"
}

final_confirmation() {
    printf '\n%sReady to deploy Windows.%s\n' \
        "$C_BOLD" \
        "$C_RESET"

    printf 'Target: %s\n' "$TARGET_DISK"
    printf 'Windows user: %s\n' "$WIN_USER"

    if [[ "$WIN_PASS" == "$DEFAULT_PASS" ]]; then
        warn "Default Windows password selected."
    fi

    printf '\n'

    local answer

    read -r -p 'Type DEPLOY to continue: ' answer

    [[ "$answer" == "DEPLOY" ]] ||
        fatal "Deployment cancelled."

    printf '\n'
}

available_ram_bytes() {
    awk '/MemAvailable:/ {
        printf "%.0f", $2 * 1024
    }' /proc/meminfo
}

bytes_to_gib() {
    awk -v b="$1" '
        BEGIN {
            printf "%.1f", b / 1073741824
        }
    '
}

prepare_ram_environment() {
    set_status "Freeing Linux memory..."

    swapoff -a 2>/dev/null || true

    sync

    echo 3 > /proc/sys/vm/drop_caches \
        2>/dev/null || true

    local available
    local required
    local required_gib
    local available_gib

    available="$(available_ram_bytes)"
    required=$(( EXPECTED_COMPRESSED_BYTES + RAM_MARGIN_BYTES ))

    if (( available < required )); then
        required_gib="$(bytes_to_gib "$required")"
        available_gib="$(bytes_to_gib "$available")"

        fatal "Not enough currently available RAM. Need about ${required_gib} GiB for safe staging. Available: ${available_gib} GiB."
    fi

    set_status "Creating RAM staging area..."

    mkdir -p "$RAM_MOUNT"

    mount \
        -t tmpfs \
        -o "size=${RAM_SIZE},mode=0700" \
        tmpfs \
        "$RAM_MOUNT"

    mkdir -p \
        "$RAM_MOUNT/staging" \
        "$RAM_MOUNT/bin" \
        "$RAM_MOUNT/sbin" \
        "$RAM_MOUNT/usr/bin" \
        "$RAM_MOUNT/usr/sbin" \
        "$RAM_MOUNT/lib" \
        "$RAM_MOUNT/lib64" \
        "$RAM_MOUNT/etc" \
        "$RAM_MOUNT/dev" \
        "$RAM_MOUNT/proc" \
        "$RAM_MOUNT/sys" \
        "$RAM_MOUNT/oldroot" \
        "$RAM_MOUNT/mnt/windows" \
        "$RAM_MOUNT/mnt/efi"
}

stage_master_to_ram() {
    local ram_image="$RAM_MOUNT/staging/$HF_FILE"
    local ram_hash

    set_status "Copying image to RAM..."

    dd \
        if="$DISK_IMAGE" \
        of="$ram_image" \
        bs=64M \
        status=none \
        conv=fsync

    set_status "Checking RAM copy..."

    ram_hash="$(
        sha256sum "$ram_image" |
            awk '{print $1}'
    )"

    [[ "$ram_hash" == "$EXPECTED_SHA256" ]] ||
        fatal "RAM staging verification failed."

    chmod 600 "$ram_image"

    sync

    echo 3 > /proc/sys/vm/drop_caches \
        2>/dev/null || true
}

write_credentials_to_ram() {
    local cred="$RAM_MOUNT/staging/credentials.txt"

    set_status "Preparing Windows settings..."

    printf 'USER=%s\nPASS=%s\n' \
        "$WIN_USER" \
        "$WIN_PASS" \
        > "$cred"

    chmod 600 "$cred"
}

copy_binary_with_libs() {
    local requested="$1"
    local binary
    local lib

    binary="$(readlink -f "$requested")"

    [[ -x "$binary" ]] ||
        fatal "Required takeover binary not found: $requested"

    mkdir -p "$RAM_MOUNT$(dirname "$binary")"

    cp -f \
        "$binary" \
        "$RAM_MOUNT$binary"

    while IFS= read -r lib; do
        [[ -e "$lib" ]] ||
            continue

        mkdir -p "$RAM_MOUNT$(dirname "$lib")"

        cp -Lf \
            "$lib" \
            "$RAM_MOUNT$lib"

    done < <(
        ldd "$binary" 2>/dev/null |
            awk '{
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^\//) {
                        print $i
                    }
                }
            }' |
            sed 's/(.*$//' |
            sort -u
    )
}

build_takeover_root() {
    local busybox
    local dd_bin
    local lz4_bin
    local sgdisk_bin
    local losetup_bin
    local fsfreeze_bin
    local ntfs3g_bin=""
    local applet

    set_status "Building takeover environment..."

    busybox="$(
        readlink -f "$(command -v busybox)"
    )"

    cp -f \
        "$busybox" \
        "$RAM_MOUNT/bin/busybox"

    for applet in \
        sh \
        sync \
        sleep \
        mount \
        umount \
        mkdir \
        cp \
        rm \
        reboot \
        grep \
        date \
        cat \
        test \
        awk \
        sed \
        tail \
        tr \
        head \
        kill \
        printf; do

        ln -sf \
            busybox \
            "$RAM_MOUNT/bin/$applet"
    done

    dd_bin="$(readlink -f "$(command -v dd)")"
    lz4_bin="$(readlink -f "$(command -v lz4)")"
    sgdisk_bin="$(readlink -f "$(command -v sgdisk)")"
    losetup_bin="$(readlink -f "$(command -v losetup)")"
    fsfreeze_bin="$(readlink -f "$(command -v fsfreeze)")"

    copy_binary_with_libs "$dd_bin"
    copy_binary_with_libs "$lz4_bin"
    copy_binary_with_libs "$sgdisk_bin"
    copy_binary_with_libs "$losetup_bin"
    copy_binary_with_libs "$fsfreeze_bin"

    modprobe ntfs3 2>/dev/null || true
    modprobe vfat 2>/dev/null || true

    if ! grep -qw ntfs3 /proc/filesystems; then
        ntfs3g_bin="$(
            readlink -f "$(command -v ntfs-3g)"
        )"

        copy_binary_with_libs "$ntfs3g_bin"

        [[ -e /dev/fuse ]] ||
            fatal "No usable NTFS write driver is available."
    fi

    grep -qw vfat /proc/filesystems ||
        fatal "Kernel vfat support is required."

    printf '%s\n' "$dd_bin" \
        > "$RAM_MOUNT/staging/path.dd"

    printf '%s\n' "$lz4_bin" \
        > "$RAM_MOUNT/staging/path.lz4"

    printf '%s\n' "$sgdisk_bin" \
        > "$RAM_MOUNT/staging/path.sgdisk"

    printf '%s\n' "$losetup_bin" \
        > "$RAM_MOUNT/staging/path.losetup"

    printf '%s\n' "$fsfreeze_bin" \
        > "$RAM_MOUNT/staging/path.fsfreeze"

    printf '%s\n' "$ntfs3g_bin" \
        > "$RAM_MOUNT/staging/path.ntfs3g"

    ln -sf \
        /proc/mounts \
        "$RAM_MOUNT/etc/mtab"

    if [[ -f /etc/fuse.conf ]]; then
        cp -f \
            /etc/fuse.conf \
            "$RAM_MOUNT/etc/fuse.conf"
    fi
}

create_takeover_helper() {
    cat > "$RAM_MOUNT/takeover.sh" <<EOF_HELPER
#!/bin/sh
set -eu

TARGET_DISK="$TARGET_DISK"
IMAGE="/staging/$HF_FILE"
CREDENTIALS="/staging/credentials.txt"

EFI_OFFSET="$EFI_PARTITION_OFFSET"
EFI_SIZE="$EFI_PARTITION_SIZE"

WINDOWS_OFFSET="$WINDOWS_PARTITION_OFFSET"
WINDOWS_SIZE="$WINDOWS_PARTITION_SIZE"

MASTER_SHA="$EXPECTED_SHA256"
MASTER_REVISION="$HF_REVISION"

DD_BIN="$(cat "$RAM_MOUNT/staging/path.dd")"
LZ4_BIN="$(cat "$RAM_MOUNT/staging/path.lz4")"
SGDISK_BIN="$(cat "$RAM_MOUNT/staging/path.sgdisk")"
LOSETUP_BIN="$(cat "$RAM_MOUNT/staging/path.losetup")"
FSFREEZE_BIN="$(cat "$RAM_MOUNT/staging/path.fsfreeze")"
NTFS3G_BIN="$(cat "$RAM_MOUNT/staging/path.ntfs3g")"

LOG="/staging/takeover.log"
STATUS="/staging/deploy.status"
DD_PROGRESS="/staging/dd.progress"

WRITE_STARTED=0
ROOT_FROZEN=0

WIN_LOOP=""
EFI_LOOP=""

WIN_MOUNTED=0
EFI_MOUNTED=0

exec >>"\$LOG" 2>&1

set_phase() {
    printf '%s\n' "\$1" > "\$STATUS"
}

force_reboot() {
    sync || true

    set_phase "Rebooting into Windows..."

    sleep 2

    reboot -f || {
        echo 1 > /proc/sys/kernel/sysrq \
            2>/dev/null || true

        echo b > /proc/sysrq-trigger
    }
}

on_exit() {
    rc=\$?

    [ "\$rc" -eq 0 ] &&
        return 0

    echo "ERROR: takeover helper failed with exit code \$rc"

    if [ "\$EFI_MOUNTED" -eq 1 ]; then
        umount /mnt/efi \
            2>/dev/null || true
    fi

    if [ "\$WIN_MOUNTED" -eq 1 ]; then
        umount /mnt/windows \
            2>/dev/null || true
    fi

    [ -z "\$EFI_LOOP" ] ||
        "\$LOSETUP_BIN" -d "\$EFI_LOOP" \
            2>/dev/null || true

    [ -z "\$WIN_LOOP" ] ||
        "\$LOSETUP_BIN" -d "\$WIN_LOOP" \
            2>/dev/null || true

    if [ "\$WRITE_STARTED" -eq 0 ] &&
       [ "\$ROOT_FROZEN" -eq 1 ]; then

        "\$FSFREEZE_BIN" -u /oldroot \
            2>/dev/null || true

        ROOT_FROZEN=0

        set_phase "Deployment stopped safely."

        return 0
    fi

    if [ "\$WRITE_STARTED" -eq 1 ]; then
        set_phase "Deployment error. Rebooting..."
        force_reboot
    fi
}

trap on_exit EXIT

set_phase "Freezing Linux..."

sync

"\$FSFREEZE_BIN" -f /oldroot

ROOT_FROZEN=1

set_phase "WRITE"

WRITE_STARTED=1

: > "\$DD_PROGRESS"

"\$LZ4_BIN" -dc "\$IMAGE" 2>>"\$LOG" |
    "\$DD_BIN" \
        of="\$TARGET_DISK" \
        bs=16M \
        iflag=fullblock \
        conv=fsync \
        status=progress \
        2>"\$DD_PROGRESS"

sync

set_phase "Repairing boot configuration..."

"\$SGDISK_BIN" -e "\$TARGET_DISK"
"\$SGDISK_BIN" -v "\$TARGET_DISK"

sync

EFI_LOOP="\$(
    "\$LOSETUP_BIN" \
        --find \
        --show \
        --offset "\$EFI_OFFSET" \
        --sizelimit "\$EFI_SIZE" \
        "\$TARGET_DISK"
)"

mkdir -p /mnt/efi

mount \
    -t vfat \
    -o rw \
    "\$EFI_LOOP" \
    /mnt/efi

EFI_MOUNTED=1

test -f /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi || {
    echo "ERROR: Windows Boot Manager is missing."
    exit 30
}

mkdir -p /mnt/efi/EFI/BOOT

cp \
    /mnt/efi/EFI/Microsoft/Boot/bootmgfw.efi \
    /mnt/efi/EFI/BOOT/BOOTX64.EFI

sync

umount /mnt/efi

EFI_MOUNTED=0

"\$LOSETUP_BIN" -d "\$EFI_LOOP"

EFI_LOOP=""

set_phase "Applying Windows settings..."

WIN_LOOP="\$(
    "\$LOSETUP_BIN" \
        --find \
        --show \
        --offset "\$WINDOWS_OFFSET" \
        --sizelimit "\$WINDOWS_SIZE" \
        "\$TARGET_DISK"
)"

mkdir -p /mnt/windows

if grep -qw ntfs3 /proc/filesystems; then
    mount \
        -t ntfs3 \
        -o rw \
        "\$WIN_LOOP" \
        /mnt/windows
else
    "\$NTFS3G_BIN" \
        "\$WIN_LOOP" \
        /mnt/windows
fi

WIN_MOUNTED=1

test -f /mnt/windows/VastWin/firstboot.ps1 || {
    echo "ERROR: firstboot.ps1 is missing."
    exit 40
}

test -f /mnt/windows/Windows/System32/Tasks/VastWin-FirstBoot || {
    echo "ERROR: VastWin-FirstBoot task is missing."
    exit 41
}

cp \
    "\$CREDENTIALS" \
    /mnt/windows/VastWin/credentials.txt

mkdir -p \
    /mnt/windows/ProgramData/VastWin

cat > /mnt/windows/ProgramData/VastWin/linux-deploy.log <<EOF_DEPLOY
VastWin Linux deployment
Master revision: $HF_REVISION
Master SHA256: $EXPECTED_SHA256
Target disk: $TARGET_DISK
STATUS: SUCCESS
EOF_DEPLOY

set_phase "Finishing deployment..."

sync

umount /mnt/windows

WIN_MOUNTED=0

"\$LOSETUP_BIN" -d "\$WIN_LOOP"

WIN_LOOP=""

rm -f "\$CREDENTIALS"

sync

trap - EXIT

force_reboot
EOF_HELPER

    chmod 700 "$RAM_MOUNT/takeover.sh"
}

create_takeover_monitor() {
    cat > "$RAM_MOUNT/monitor.sh" <<EOF_MONITOR
#!/bin/sh
set +e

trap '' HUP INT TERM

RAW_BYTES="$EXPECTED_RAW_BYTES"

STATUS="/staging/deploy.status"
DD_PROGRESS="/staging/dd.progress"
LOG="/staging/takeover.log"

make_bar() {
    pct="\$1"
    width=10

    filled=\$(( pct * width / 100 ))
    empty=\$(( width - filled ))

    bar=""
    i=0

    while [ "\$i" -lt "\$filled" ]; do
        bar="\${bar}█"
        i=\$((i + 1))
    done

    i=0

    while [ "\$i" -lt "\$empty" ]; do
        bar="\${bar}░"
        i=\$((i + 1))
    done

    printf '%s' "\$bar"
}

spinner() {
    case \$((\$1 % 8)) in
        0) printf '⠋' ;;
        1) printf '⠙' ;;
        2) printf '⠹' ;;
        3) printf '⠸' ;;
        4) printf '⠼' ;;
        5) printf '⠴' ;;
        6) printf '⠦' ;;
        *) printf '⠧' ;;
    esac
}

latest_dd_bytes() {
    [ -f "\$DD_PROGRESS" ] || {
        printf '0'
        return
    }

    tr '\r' '\n' < "\$DD_PROGRESS" |
        awk '/^[0-9]+ bytes/ {
            v=\$1
        }

        END {
            print v+0
        }'
}

/bin/sh /takeover.sh >>"\$LOG" 2>&1 &

PID=\$!

START=\$(date +%s)

I=0
LAST_PHASE=""

printf '[6/6] Deploying Windows\n'

while kill -0 "\$PID" 2>/dev/null; do
    NOW=\$(date +%s)
    ELAPSED=\$((NOW - START))

    [ "\$ELAPSED" -gt 0 ] ||
        ELAPSED=1

    PHASE=""

    [ -s "\$STATUS" ] &&
        PHASE=\$(head -n1 "\$STATUS" 2>/dev/null)

    if [ "\$PHASE" = "WRITE" ]; then
        BYTES=\$(latest_dd_bytes)

        [ -n "\$BYTES" ] ||
            BYTES=0

        PCT=\$(( BYTES * 100 / RAW_BYTES ))

        [ "\$PCT" -gt 99 ] &&
            PCT=99

        SPEED=\$(( BYTES / ELAPSED / 1024 / 1024 ))

        BAR=\$(make_bar "\$PCT")

        printf '\r\033[2K      %s %3d%%' \
            "\$BAR" \
            "\$PCT"

        [ "\$SPEED" -gt 0 ] &&
            printf '  %d MiB/s' "\$SPEED"

    else
        if [ -n "\$PHASE" ] &&
           [ "\$PHASE" != "\$LAST_PHASE" ]; then

            printf '\r\033[2K'
            printf '      %s\n' "\$PHASE"

            LAST_PHASE="\$PHASE"
        fi

        FRAME=\$(spinner "\$I")

        printf '\r\033[2K      %s' "\$FRAME"
    fi

    I=\$((I + 1))

    sleep 0.15
done

wait "\$PID"

RC=\$?

printf '\r\033[2K'

if [ "\$RC" -eq 0 ]; then
    printf '[6/6] Deploying Windows ✓\n'
    exit 0
fi

printf '[6/6] Deploying Windows ✗\n' >&2
printf '[VastWin] ERROR: Windows takeover stopped unexpectedly.\n' >&2

if [ -s "\$LOG" ]; then
    tail -n 12 "\$LOG" >&2
fi

exit "\$RC"
EOF_MONITOR

    chmod 700 "$RAM_MOUNT/monitor.sh"
}

validate_takeover_root() {
    local path_file
    local copied_path

    set_status "Validating takeover environment..."

    [[ -x "$RAM_MOUNT/bin/sh" ]] ||
        fatal "RAM takeover shell is missing."

    for path_file in \
        "$RAM_MOUNT/staging/path.dd" \
        "$RAM_MOUNT/staging/path.lz4" \
        "$RAM_MOUNT/staging/path.sgdisk" \
        "$RAM_MOUNT/staging/path.losetup" \
        "$RAM_MOUNT/staging/path.fsfreeze"; do

        copied_path="$(cat "$path_file")"

        [[ -x "$RAM_MOUNT$copied_path" ]] ||
            fatal "A required RAM takeover binary is missing."
    done

    chroot \
        "$RAM_MOUNT" \
        /bin/sh \
        -n \
        /takeover.sh ||
        fatal "RAM takeover helper validation failed."

    chroot \
        "$RAM_MOUNT" \
        /bin/sh \
        -n \
        /monitor.sh ||
        fatal "RAM takeover monitor validation failed."

    set_status "Takeover environment ready"
}

prepare_takeover_stage() {
    prepare_ram_environment
    stage_master_to_ram
    write_credentials_to_ram
    build_takeover_root
    create_takeover_helper
    create_takeover_monitor
    validate_takeover_root
}

run_ram_stage() {
    local step=5
    local label="Preparing RAM"

    : > "$STEP_LOG"
    : > "$STATUS_FILE"

    printf '%s[%d/%d]%s %s\n' \
        "$C_CYAN" \
        "$step" \
        "$TOTAL_STEPS" \
        "$C_RESET" \
        "$label"

    prepare_takeover_stage >"$STEP_LOG" 2>&1 &
    ACTIVE_PID=$!

    local i=0
    local detail=""
    local last_detail=""
    local copy_start=0
    local bytes=0
    local percent=0
    local elapsed=1
    local mibps=0
    local remaining=0
    local eta_seconds=0
    local eta="--"
    local rc=0
    local ram_image="$RAM_MOUNT/staging/$HF_FILE"

    while kill -0 "$ACTIVE_PID" 2>/dev/null; do
        detail="$(get_status)"

        if [[ -n "$detail" &&
              "$detail" != "$last_detail" ]]; then

            clear_active_line

            printf '      %s%s%s\n' \
                "$C_DIM" \
                "$detail" \
                "$C_RESET"

            last_detail="$detail"

            if [[ "$detail" == "Copying image to RAM..." ]]; then
                copy_start="$SECONDS"
            fi
        fi

        if [[ "$detail" == "Copying image to RAM..." &&
              -f "$ram_image" ]]; then

            bytes="$(
                stat -c '%s' "$ram_image" \
                    2>/dev/null || printf '0'
            )"

            percent=$(( bytes * 100 / EXPECTED_COMPRESSED_BYTES ))

            (( percent > 99 )) &&
                percent=99

            if (( copy_start > 0 )); then
                elapsed=$(( SECONDS - copy_start ))
            else
                elapsed=1
            fi

            (( elapsed > 0 )) ||
                elapsed=1

            mibps=$(( bytes / elapsed / 1024 / 1024 ))

            if (( mibps > 0 )); then
                remaining=$(( EXPECTED_COMPRESSED_BYTES - bytes ))

                (( remaining < 0 )) &&
                    remaining=0

                eta_seconds=$(( remaining / (mibps * 1024 * 1024) ))
                eta="$(format_eta "$eta_seconds")"
            else
                eta="--"
            fi

            if (( UI_ENABLED )); then
                render_progress_line \
                    "$percent" \
                    "$mibps" \
                    "$eta"
            fi

        elif (( UI_ENABLED )); then
            clear_active_line

            printf '      %s%s%s' \
                "$C_YELLOW" \
                "${SPINNER[$((i % ${#SPINNER[@]}))]}" \
                "$C_RESET"

            i=$((i + 1))
        fi

        sleep 0.15
    done

    if wait "$ACTIVE_PID"; then
        rc=0
    else
        rc=$?
    fi

    ACTIVE_PID=""

    clear_active_line

    if (( rc == 0 )); then
        render_done "$step" "$label"
        return 0
    fi

    render_failed "$step" "$label"
    show_step_error

    return "$rc"
}

bind_runtime_filesystems() {
    mount --bind \
        /dev \
        "$RAM_MOUNT/dev"

    mount --bind \
        /proc \
        "$RAM_MOUNT/proc"

    mount --bind \
        /sys \
        "$RAM_MOUNT/sys"

    mount --bind \
        / \
        "$RAM_MOUNT/oldroot"
}

launch_takeover() {
    umount /boot/efi \
        2>/dev/null || true

    sync

    bind_runtime_filesystems

    printf '%sDo not interrupt the VM after this point.%s\n' \
        "$C_DIM" \
        "$C_RESET"

    TAKEOVER_LAUNCHED=1

    exec chroot \
        "$RAM_MOUNT" \
        /bin/sh \
        /monitor.sh

    TAKEOVER_LAUNCHED=0

    fatal "Unable to launch the RAM takeover environment."
}

main() {
    parse_args "$@"

    init_ui
    require_root
    validate_xet_concurrency

    banner
    prompt_settings

    run_stage \
        1 \
        "Checking system" \
        system_check_stage

    print_system_summary

    run_stage \
        2 \
        "Preparing download" \
        prepare_hf_client

    run_download_stage

    unset HF_TOKEN

    run_stage \
        4 \
        "Verifying image" \
        verify_disk_master

    final_confirmation

    run_ram_stage

    unset WIN_PASS

    launch_takeover
}

main "$@"