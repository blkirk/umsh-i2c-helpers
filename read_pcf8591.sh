#!/bin/bash
# Read PCF8591 4-channel 8-bit ADC + DAC via umshctl I2C commands
# Usage: ./read_pcf8591.sh [device_path] [bus_number] [i2c_addr] [node_id] [vref]
# Defaults: /dev/ttyACM0 bus 0 0x48 (no node) 3.3
# 
# node_id: optional UMSH node ID for remote I2C (e.g., 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp)
# vref: reference voltage in volts (default 3.3V)

set -euo pipefail

DEVICE="${1:-/dev/ttyACM0}"
BUS="${2:-0}"
ADDR="${3:-0x48}"
NODE="${4:-}"
VREF="${5:-3.3}"

# Build umshctl command with optional --node
UMCTL="/home/blkirk/umsh/target/release/umshctl -p $DEVICE"
if [ -n "$NODE" ]; then
    UMCTL="$UMCTL --node $NODE"
fi

# Control byte bits:
# Bit 7: reserved (0)
# Bit 6: auto-increment flag (1 = enabled for multi-channel read)
# Bit 5: reserved (0)
# Bit 4: analog output enable (1 = enable DAC)
# Bits 3-2: reserved (0)
# Bits 1-0: channel selection (00=AIN0, 01=AIN1, 10=AIN2, 11=AIN3)

# Single channel reads
CH0_CTRL=0x40  # AIN0, single-ended
CH1_CTRL=0x41  # AIN1, single-ended
CH2_CTRL=0x42  # AIN2, single-ended
CH3_CTRL=0x43  # AIN3, single-ended

# Auto-increment mode (read all 4 channels)
AUTO_CTRL=0x04  # Start at AIN0, auto-increment

# DAC enabled single channel reads
CH0_DAC_CTRL=0x50  # AIN0 + DAC enable
CH1_DAC_CTRL=0x51  # AIN1 + DAC enable
CH2_DAC_CTRL=0x52  # AIN2 + DAC enable
CH3_DAC_CTRL=0x53  # AIN3 + DAC enable

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

echo "Reading PCF8591 at address $ADDR on bus $BUS..."
echo "Reference voltage: ${VREF}V"
echo ""

# Read all 4 channels using auto-increment
echo "Reading all 4 channels (auto-increment mode)..."
i2c_write "04" >/dev/null  # Control byte: auto-increment, start at AIN0
sleep 0.01

data=$(i2c_read 5)  # First read is dummy, then 4 channels
if [ -z "$data" ] || [ ${#data} -ne 10 ]; then
    echo "Error: Failed to read auto-increment data (got ${#data} chars, expected 10)"
else
    # First byte is dummy (previous conversion), next 4 are channels 0-3
    DUMMY=${data:0:2}
    CH0_HEX=${data:2:2}
    CH1_HEX=${data:4:2}
    CH2_HEX=${data:6:2}
    CH3_HEX=${data:8:2}

    CH0_RAW=$(hex_to_u8 $CH0_HEX)
    CH1_RAW=$(hex_to_u8 $CH1_HEX)
    CH2_RAW=$(hex_to_u8 $CH2_HEX)
    CH3_RAW=$(hex_to_u8 $CH3_HEX)

    CH0_V=$(awk -v raw="$CH0_RAW" -v vref="$VREF" 'BEGIN { printf "%.3f", raw * vref / 255.0 }')
    CH1_V=$(awk -v raw="$CH1_RAW" -v vref="$VREF" 'BEGIN { printf "%.3f", raw * vref / 255.0 }')
    CH2_V=$(awk -v raw="$CH2_RAW" -v vref="$VREF" 'BEGIN { printf "%.3f", raw * vref / 255.0 }')
    CH3_V=$(awk -v raw="$CH3_RAW" -v vref="$VREF" 'BEGIN { printf "%.3f", raw * vref / 255.0 }')

    echo "Auto-increment results:"
    echo "  Dummy byte: 0x$DUMMY"
    echo "  AIN0: 0x$CH0_HEX ($CH0_RAW) = ${CH0_V}V"
    echo "  AIN1: 0x$CH1_HEX ($CH1_RAW) = ${CH1_V}V"
    echo "  AIN2: 0x$CH2_HEX ($CH2_RAW) = ${CH2_V}V"
    echo "  AIN3: 0x$CH3_HEX ($CH3_RAW) = ${CH3_V}V"
fi

echo ""

# Read individual channels (more reliable for single channel)
echo "Reading individual channels..."
for ch_name in "AIN0" "AIN1" "AIN2" "AIN3"; do
    case $ch_name in
        AIN0) ctrl="40" ;;
        AIN1) ctrl="41" ;;
        AIN2) ctrl="42" ;;
        AIN3) ctrl="43" ;;
    esac
    
    i2c_write $ctrl >/dev/null
    sleep 0.01
    val_hex=$(i2c_read 1)
    
    if [ -z "$val_hex" ] || [ ${#val_hex} -ne 2 ]; then
        echo "  $ch_name: ERROR reading"
    else
        raw=$(hex_to_u8 $val_hex)
        volt=$(awk -v raw="$raw" -v vref="$VREF" 'BEGIN { printf "%.3f", raw * vref / 255.0 }')
        echo "  $ch_name: 0x$val_hex ($raw) = ${volt}V"
    fi
done

echo ""

# DAC test (write to DAC, read back on AIN0 if jumpered AOUT->AIN0)
# NOTE: The PCF8591 outputs DAC on AOUT pin. To read it back with ADC,
# you MUST externally jumper AOUT to AIN0 (or another AIN pin).
# The control byte 0x50 enables DAC and selects AIN0 for NEXT read,
# but it does NOT internally connect DAC to ADC.
echo "DAC test (output 0x80 = ~50% Vref, requires AOUT->AIN0 jumper)..."
i2c_write "5080" >/dev/null  # Enable DAC + AIN0, write 0x80 to DAC
sleep 0.01
i2c_write "40" >/dev/null   # Switch to AIN0 for reading
sleep 0.01
val_hex=$(i2c_read 1)
if [ -z "$val_hex" ] || [ ${#val_hex} -ne 2 ]; then
    echo "  ERROR reading"
else
    raw=$(hex_to_u8 $val_hex)
    volt=$(awk -v raw="$raw" -v vref="$VREF" 'BEGIN { printf "%.3f", raw * vref / 255.0 }')
    expected=$(awk -v vref="$VREF" 'BEGIN { printf "%.3f", 128 * vref / 255.0 }')
    echo "  DAC output (read on AIN0): 0x$val_hex ($raw) = ${volt}V (expected ~${expected}V)"
fi

# Test full range
echo ""
echo "DAC sweep test (read back on AIN0, requires AOUT->AIN0 jumper)..."
for dac_val in 00 40 80 c0 ff; do
    i2c_write "50${dac_val}" >/dev/null  # Write DAC value
    sleep 0.01
    i2c_write "40" >/dev/null           # Switch to AIN0 for reading
    sleep 0.01
    val_hex=$(i2c_read 1)
    if [ -z "$val_hex" ] || [ ${#val_hex} -ne 2 ]; then
        echo "  DAC 0x$dac_val: ERROR"
    else
        raw=$(hex_to_u8 $val_hex)
        volt=$(awk -v raw="$raw" -v vref="$VREF" 'BEGIN { printf "%.3f", raw * vref / 255.0 }')
        echo "  DAC 0x$dac_val: read 0x$val_hex = ${volt}V"
    fi
done

echo ""
echo "Summary (auto-increment):"
echo "  AIN0: ${CH0_V}V"
echo "  AIN1: ${CH1_V}V"
echo "  AIN2: ${CH2_V}V"
echo "  AIN3: ${CH3_V}V"