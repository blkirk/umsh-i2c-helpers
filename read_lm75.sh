#!/bin/bash
# Read LM75 temperature sensor via umshctl I2C commands
# Usage: ./read_lm75.sh [device_path] [bus_number] [i2c_addr] [node_id]
# Defaults: /dev/ttyACM0 bus 0 0x48 (no node)
#
# node_id: optional UMSH node ID for remote I2C (e.g., 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp)

set -euo pipefail

DEVICE="${1:-/dev/ttyACM0}"
BUS="${2:-0}"
ADDR="${3:-0x48}"
NODE="${4:-}"

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
REG_TEMP=0x00
REG_CONFIG=0x01
REG_THYST=0x02
REG_TOS=0x03

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

# Convert hex string to signed 16-bit integer
hex_to_i16() {
    local hex=$1
    local val=$((16#$hex))
    if [ $val -ge 32768 ]; then
        val=$((val - 65536))
    fi
    echo $val
}

echo "Reading LM75 at address $ADDR on bus $BUS..."

# Read temperature register (0x00): write pointer byte, then read 2 bytes (MSB, LSB)
temp_data=$(i2c_xfer "w:00 r:2")
if [ -z "$temp_data" ] || [ ${#temp_data} -ne 4 ]; then
    echo "Error: Failed to read temperature register (got ${#temp_data} chars, expected 4)"
    exit 1
fi

TEMP_RAW=$(hex_to_i16 $temp_data)
echo "Raw temperature register: 0x$temp_data ($TEMP_RAW)"

# LM75: 9-bit two's complement in upper 9 bits, 0.5 deg C per LSB
# Temperature (deg C) = signed 16-bit register value / 256
TEMP_C=$(awk -v raw="$TEMP_RAW" 'BEGIN { printf "%.2f", raw / 256.0 }')

# Fahrenheit
TEMP_F=$(awk -v c="$TEMP_C" 'BEGIN { printf "%.2f", c * 9.0 / 5.0 + 32.0 }')

echo ""
echo "Measurements:"
echo "  Temperature: ${TEMP_C}°C / ${TEMP_F}°F"
