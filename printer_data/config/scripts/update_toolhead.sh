#!/bin/bash
# Update the EBB36 toolhead (CAN, Katapult bootloader) to the Klipper version
# currently checked out in ~/klipper.
#
#   update_toolhead.sh            build + flash if the toolhead is outdated
#   update_toolhead.sh --force    build + flash even if versions already match
#   update_toolhead.sh --detach   run in the background as its own systemd unit
#                                 (used by the UPDATE_TOOLHEAD macro, because
#                                 stopping Klipper would otherwise kill us)
#
# Log: ~/printer_data/logs/update_toolhead.log

KLIPPER_DIR="$HOME/klipper"
KATAPULT_DIR="$HOME/katapult"
KCONFIG="$HOME/firmware-configs/config.ebb36"
OUT_DIR="$HOME/firmware-configs/build-ebb36/"
CAN_IF="can0"
CAN_UUID="9c335318b057"
MCU_NAME="EBBCan"
MOONRAKER="http://localhost:7125"
LOG="$HOME/printer_data/logs/update_toolhead.log"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --detach)
            shift_args=()
            [ "$FORCE" = 1 ] && shift_args+=(--force)
            for a in "$@"; do [ "$a" = "--force" ] && shift_args+=(--force); done
            sudo systemctl reset-failed update-toolhead 2>/dev/null
            sudo systemd-run --unit=update-toolhead --collect --uid="$(id -u)" \
                --setenv=HOME="$HOME" "$(readlink -f "$0")" "${shift_args[@]}"
            echo "Toolhead update started in background, log: $LOG"
            exit 0 ;;
    esac
done

exec > >(tee -a "$LOG") 2>&1
log() { echo "[$(date '+%F %T')] $*"; }
klipper_running=0

start_klipper() {
    if [ "$klipper_running" = 1 ]; then
        log "Starting Klipper"
        sudo systemctl start klipper
    fi
}
fail() { log "ERROR: $*"; start_klipper; exit 1; }

log "=== Toolhead update ==="

[ -f "$KCONFIG" ] || fail "Build config $KCONFIG missing"
ip link show "$CAN_IF" 2>/dev/null | grep -q "state UP\|LOWER_UP" || fail "$CAN_IF is not up"

# Refuse to run while printing
state=$(curl -s "$MOONRAKER/printer/objects/query?print_stats=state" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["status"]["print_stats"]["state"])' 2>/dev/null)
case "$state" in
    printing|paused) fail "Printer is $state - not updating" ;;
esac

host_ver=$(git -C "$KLIPPER_DIR" describe --tags --always --dirty 2>/dev/null)
host_ver_clean=$(git -C "$KLIPPER_DIR" describe --tags --always 2>/dev/null)
mcu_ver=$(curl -s "$MOONRAKER/printer/objects/query?mcu%20$MCU_NAME" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['status']['mcu $MCU_NAME']['mcu_version'])" 2>/dev/null)
log "Klipper host: $host_ver   Toolhead: ${mcu_ver:-unknown}"

if [ "$FORCE" = 0 ] && [ -n "$mcu_ver" ] && [ "$mcu_ver" = "$host_ver_clean" ]; then
    log "Toolhead already up to date - nothing to do (use --force to reflash)"
    exit 0
fi

log "Building firmware"
cd "$KLIPPER_DIR" || fail "No $KLIPPER_DIR"
make olddefconfig KCONFIG_CONFIG="$KCONFIG" OUT="$OUT_DIR" >/dev/null || fail "olddefconfig failed"
make clean KCONFIG_CONFIG="$KCONFIG" OUT="$OUT_DIR" >/dev/null
make -j4 KCONFIG_CONFIG="$KCONFIG" OUT="$OUT_DIR" >/dev/null || fail "Build failed"
[ -f "${OUT_DIR}klipper.bin" ] || fail "No klipper.bin produced"

if systemctl is-active --quiet klipper; then
    klipper_running=1
    log "Stopping Klipper"
    sudo systemctl stop klipper
    sleep 2
fi

log "Flashing $CAN_UUID on $CAN_IF"
if ! python3 "$KATAPULT_DIR/scripts/flashtool.py" -i "$CAN_IF" -u "$CAN_UUID" -f "${OUT_DIR}klipper.bin"; then
    fail "Flashing failed - toolhead may be sitting in Katapult; rerun this script"
fi

start_klipper
log "Done"
