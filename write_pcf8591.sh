#!/bin/bash
# Write PCF8591 DAC (AOUT) via umshctl I2C commands
# Usage: ./write_pcf8591.sh [device_path] [bus_number] [i2c_addr] [node_id] [dac_value] [vref]
# Defaults: /dev/ttyACM0 bus 0 0x48 (no node) 0x80 3.3
# dac_value: 0x00 to 0xFF (0 to 255), hex or decimal
# vref: reference voltage in volts (default 3.3V)
#
# node_id: optional UMSH node ID for remote I2C (e.g., 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp)
#
#Examples:
#./write_pcf8591.sh /dev/ttyACM0 0 0x48 0x00   # 0V
#./write_pcf8591.sh /dev/ttyACM0 0 0x48 0x80   # ~1.66V (mid-scale)
#./write_pcf8591.sh /dev/ttyACM0 0 0x48 0xFF   # ~3.3V (full-scale)
#./write_pcf8591.sh /dev/ttyACM0 0 0x48 128    # decimal also works

set -euo pipefail

DEVICE="${1:-/dev/ttyACM0}"
BUS="${2:-0}"
ADDR="${3:-0x48}"
NODE="${4:-}"
DAC_VAL="${5:-0x80}"
VREF="${6:-3.3}"

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

# Helper: run umshctl i2c write command
i2c_write() {
    local data=$1
    $UMCTL i2c write $BUS $ADDR $data 2>&1
}

# Parse DAC value (hex or decimal)
if [[ "$DAC_VAL" =~ ^0x ]]; then
    DAC_HEX="${DAC_VAL#0x}"
else
    DAC_HEX=$(printf "%02x" "$DAC_VAL")
fi

# Validate range
DAC_DEC=$((16#$DAC_HEX))
if [ $DAC_DEC -lt 0 ] || [ $DAC_DEC -gt 255 ]; then
    echo "Error: DAC value must be 0-255 (0x00-0xFF)"
    exit 1
fi

# Control byte: bit 4 = DAC enable (1), bits 1-0 = channel (00 = AIN0, but ignored for DAC)
# 0x40 = DAC enabled, read AIN0 next (but we're writing DAC)
# Actually for DAC write: control byte has bit 4 set, then DAC value follows
# Format: [control_byte][dac_value]
CTRL_BYTE="40"

echo "Writing PCF8591 DAC at address $ADDR on bus $BUS..."
echo "DAC value: 0x$DAC_HEX ($DAC_DEC / 255)"

# Write control byte + DAC value
i2c_write "${CTRL_BYTE}${DAC_HEX}" >/dev/null

echo "Done. AOUT voltage ≈ $(awk -v v="$DAC_DEC" -v vref="$VREF" 'BEGIN { printf "%.3f", v * vref / 255.0 }')V (at ${VREF}V Vref)"