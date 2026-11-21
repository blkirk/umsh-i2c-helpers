#!/bin/bash
# Set LM75 shutdown mode via umshctl I2C commands
# Usage: ./shutdown_lm75.sh enable|disable [device_path] [bus_number] [i2c_addr] [node_id]
# Defaults: /dev/ttyACM0 bus 0 0x48 (no node)
#
# node_id: optional UMSH node ID for remote I2C (e.g., 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp)
# enable  = shutdown mode (low current)
# disable = normal operation

set -euo pipefail

ACTION="${1:-}"
DEVICE="${2:-/dev/ttyACM0}"
BUS="${3:-0}"
ADDR="${4:-0x48}"
NODE="${5:-}"

if [ "$ACTION" != "enable" ] && [ "$ACTION" != "disable" ]; then
    echo "Usage: $0 enable|disable [device] [bus] [addr] [node_id]" >&2
    echo "  enable  = shutdown mode (low current)" >&2
    echo "  disable = normal operation" >&2
    exit 1
fi

# Determine umshctl path: env var UMSHCTL > PATH > common build locations
if [ -n "${UMSHCTL:-}" ]; then
    UMCTL="${UMSHCTL} -p $DEVICE"
elif command -v umshctl &>/dev/null; then
    UMCTL="umshctl -p $DEVICE"
else
    for candidate in \
        "$HOME/umsh/target/release/umshctl" \
        "/usr/local/bin/umshctl" \
        "/opt/umsh/target/release/umshctl"; do
        if [ -x "$candidate" ]; then
            UMCTL="$candidate -p $DEVICE"
            break
        fi
    done
fi

if [ -z "${UMCTL:-}" ]; then
    echo "Error: umshctl not found. Set UMSHCTL env var or ensure umshctl is in PATH" >&2
    exit 1
fi

# Add optional --node for remote I2C
if [ -n "$NODE" ]; then
    UMCTL="$UMCTL --node $NODE"
fi

# Register addresses
REG_CONFIG=0x01

# Helper: run umshctl i2c xfer for combined write+read
i2c_xfer() {
    local ops=$1
    $UMCTL i2c xfer $BUS $ADDR $ops 2>&1 | tr -d ' \n'
}

# Helper: run umshctl i2c write command
i2c_write() {
    local data=$1
    $UMCTL i2c write $BUS $ADDR $data 2>&1
}

# Helper: run umshctl i2c read command
i2c_read() {
    local len=$1
    $UMCTL i2c read $BUS $ADDR $len 2>&1 | tr -d ' \n'
}

# Convert hex string to unsigned 8-bit integer
hex_to_u8() {
    echo $((16#$1))
}

echo "Setting LM75 shutdown mode to: $ACTION"

# Read current config register (0x01)
config_data=$(i2c_xfer "w:01 r:1")
if [ -z "$config_data" ] || [ ${#config_data} -ne 2 ]; then
    echo "Error: Failed to read config register (got ${#config_data} chars, expected 2)"
    exit 1
fi

CONFIG_OLD=$(hex_to_u8 $config_data)
echo "Current config register: 0x$config_data ($CONFIG_OLD)"

# Bit 0 = shutdown mode (1 = shutdown/low power, 0 = normal)
if [ "$ACTION" = "enable" ]; then
    # Set bit 0 for shutdown mode
    CONFIG_NEW=$((CONFIG_OLD | 0x01))
else
    # Clear bit 0 for normal operation
    CONFIG_NEW=$((CONFIG_OLD & ~0x01))
fi

CONFIG_NEW_HEX=$(printf "%02x" $CONFIG_NEW)
echo "New config register: 0x$CONFIG_NEW_HEX ($CONFIG_NEW)"

# Write new config
i2c_write "01$CONFIG_NEW_HEX" >/dev/null

# Verify write
sleep 0.01
config_data=$(i2c_xfer "w:01 r:1")
if [ -z "$config_data" ] || [ ${#config_data} -ne 2 ]; then
    echo "Error: Failed to verify config register"
    exit 1
fi

CONFIG_VERIFY=$(hex_to_u8 $config_data)
echo "Verified config register: 0x$config_data ($CONFIG_VERIFY)"

if [ $CONFIG_VERIFY -ne $CONFIG_NEW ]; then
    echo "Error: Config verification failed (expected 0x$CONFIG_NEW_HEX, got 0x$config_data)"
    exit 1
fi

if [ "$ACTION" = "enable" ]; then
    echo "LM75 shutdown mode ENABLED (low current)"
else
    echo "LM75 shutdown mode DISABLED (normal operation)"
fi