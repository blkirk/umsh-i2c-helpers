#!/bin/bash
# Read INA219 current/power sensor via umshctl I2C commands
# Usage: ./read_ina219.sh [device_path] [bus_number] [i2c_addr] [node_id] [shunt_ohms] [max_amps]
# Defaults: /dev/ttyACM0 bus 0 0x40 (no node) 0.1 3.2
# 
# node_id: optional UMSH node ID for remote I2C (e.g., 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp)
# shunt_ohms: shunt resistor value in ohms (e.g., 0.1 for 100mΩ)
# max_amps: maximum expected current in amps (for calibration calculation)

set -euo pipefail

DEVICE="${1:-/dev/ttyACM0}"
BUS="${2:-0}"
ADDR="${3:-0x40}"
NODE="${4:-}"
SHUNT_OHMS="${5:-0.1}"
MAX_AMPS="${6:-3.2}"

# Build umshctl command with optional --node
UMCTL="/home/blkirk/umsh/target/release/umshctl -p $DEVICE"
if [ -n "$NODE" ]; then
    UMCTL="$UMCTL --node $NODE"
fi

# Register addresses
REG_CONFIG=0x00
REG_SHUNT_V=0x01
REG_BUS_V=0x02
REG_POWER=0x03
REG_CURRENT=0x04
REG_CALIB=0x05

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

# Convert hex string to signed 16-bit integer
hex_to_i16() {
    local hex=$1
    local val=$((16#$hex))
    if [ $val -ge 32768 ]; then
        val=$((val - 65536))
    fi
    echo $val
}

# Convert hex string to unsigned 16-bit integer
hex_to_u16() {
    echo $((16#$1))
}

echo "Reading INA219 at address $ADDR on bus $BUS..."
echo "Shunt: ${SHUNT_OHMS}Ω, Max current: ${MAX_AMPS}A"

# Calculate calibration register value
# Cal = trunc(0.04096 / (Current_LSB * R_shunt))
# Current_LSB = 0.0001 A/LSB (100µA resolution)
CURRENT_LSB=0.0001

# Use awk for floating point math (more reliable than bc)
CALIB=$(awk -v cl="$CURRENT_LSB" -v rs="$SHUNT_OHMS" 'BEGIN { printf "%.0f", 0.04096 / (cl * rs) }')
CALIB_HEX=$(printf "0x%04x" $CALIB)

echo "Configuration:"
echo "  Current_LSB = ${CURRENT_LSB} A/LSB"
echo "  Calibration register = ${CALIB} (${CALIB_HEX})"

# Write calibration register
echo "Writing calibration register..."
i2c_write "05${CALIB_HEX#0x}" >/dev/null

# Write configuration register for continuous shunt+bus, 12-bit, PGA=/8 (320mV range)
# Config: 0x399F = 0011 1001 1001 1111
# RST=0, BRNG=1 (32V), PG=11 (/8), BADC=1001 (12-bit, 1 sample), SADC=1001 (12-bit, 1 sample), MODE=111 (continuous shunt+bus)
CONFIG_VAL="399f"
echo "Writing configuration register (0x$CONFIG_VAL)..."
i2c_write "00$CONFIG_VAL" >/dev/null

# Wait for conversion (max 532µs per conversion at 12-bit, plus averaging)
# For continuous mode with 1 sample, wait ~1ms
sleep 0.01

# Read registers individually (INA219 doesn't support sequential multi-reg read well)
SHUNT_HEX=$($UMCTL i2c read $BUS $ADDR 2 --reg 01 2>&1 | tr -d ' \n')
BUS_HEX=$($UMCTL i2c read $BUS $ADDR 2 --reg 02 2>&1 | tr -d ' \n')
POWER_HEX=$($UMCTL i2c read $BUS $ADDR 2 --reg 03 2>&1 | tr -d ' \n')
CURRENT_HEX=$($UMCTL i2c read $BUS $ADDR 2 --reg 04 2>&1 | tr -d ' \n')
CALIB_READ_HEX=$($UMCTL i2c read $BUS $ADDR 2 --reg 05 2>&1 | tr -d ' \n')

# Check if any read failed
for reg in "$SHUNT_HEX" "$BUS_HEX" "$POWER_HEX" "$CURRENT_HEX" "$CALIB_READ_HEX"; do
    if [ -z "$reg" ] || [ ${#reg} -ne 4 ]; then
        echo "Error: Failed to read registers properly"
        echo "  Shunt: '$SHUNT_HEX' Bus: '$BUS_HEX' Power: '$POWER_HEX' Current: '$CURRENT_HEX' Calib: '$CALIB_READ_HEX'"
        exit 1
    fi
done

SHUNT_RAW=$(hex_to_i16 $SHUNT_HEX)
BUS_RAW=$(hex_to_u16 $BUS_HEX)
POWER_RAW=$(hex_to_u16 $POWER_HEX)
CURRENT_RAW=$(hex_to_i16 $CURRENT_HEX)
CALIB_READ=$(hex_to_u16 $CALIB_READ_HEX)

# Shunt voltage: LSB = 10µV, sign-extended based on PGA
# For PGA=/8, the sign bits are bits 15-13
SHUNT_V=$(awk -v raw="$SHUNT_RAW" 'BEGIN { printf "%.6f", raw * 0.00001 }')

# Bus voltage: register shifted right by 3, LSB = 4mV
BUS_V_RAW=$((BUS_RAW >> 3))
BUS_V=$(awk -v raw="$BUS_V_RAW" 'BEGIN { printf "%.3f", raw * 0.004 }')

# Current: Current = CurrentReg * Current_LSB
CURRENT_A=$(awk -v raw="$CURRENT_RAW" -v lsb="$CURRENT_LSB" 'BEGIN { printf "%.6f", raw * lsb }')

# Power: Power = PowerReg * 20 * Current_LSB
POWER_W=$(awk -v raw="$POWER_RAW" -v lsb="$CURRENT_LSB" 'BEGIN { printf "%.6f", raw * 20 * lsb }')

# Also calculate current from shunt voltage directly for verification
# I = Vshunt / Rshunt
CURRENT_FROM_SHUNT=$(awk -v sv="$SHUNT_V" -v rs="$SHUNT_OHMS" 'BEGIN { printf "%.6f", sv / rs }')

echo ""
echo "Raw register values:"
echo "  Shunt voltage reg:  0x$SHUNT_HEX ($SHUNT_RAW)"
echo "  Bus voltage reg:    0x$BUS_HEX ($BUS_RAW >> 3 = $BUS_V_RAW)"
echo "  Power reg:          0x$POWER_HEX ($POWER_RAW)"
echo "  Current reg:        0x$CURRENT_HEX ($CURRENT_RAW)"
echo "  Calibration reg:    0x$CALIB_READ_HEX ($CALIB_READ)"
echo ""
echo "Measurements:"
echo "  Shunt voltage:  ${SHUNT_V} V ($(echo "scale=3; $SHUNT_V * 1000" | bc -l) mV)"
echo "  Bus voltage:    ${BUS_V} V"
echo "  Current (reg):  ${CURRENT_A} A ($(echo "scale=3; $CURRENT_A * 1000" | bc -l) mA)"
echo "  Current (V/R):  ${CURRENT_FROM_SHUNT} A ($(echo "scale=3; $CURRENT_FROM_SHUNT * 1000" | bc -l) mA)"
echo "  Power:          ${POWER_W} W ($(echo "scale=3; $POWER_W * 1000" | bc -l) mW)"
echo ""
echo "Summary:"
echo "  Bus Voltage: ${BUS_V} V"
echo "  Current:     ${CURRENT_A} A"
echo "  Power:       ${POWER_W} W"