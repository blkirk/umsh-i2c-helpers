#!/bin/bash
# Read AHT30/AHT20/AHT21 humidity and temperature sensor via umshctl I2C commands
# Usage: ./read_aht30.sh [device_path] [bus_number] [i2c_addr] [node_id]
# Defaults: /dev/ttyACM0 bus 0 0x38 (no node)
#
# node_id: optional UMSH node ID for remote I2C (e.g., 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp)

set -euo pipefail

DEVICE="${1:-/dev/ttyACM0}"
BUS="${2:-0}"
ADDR="${3:-0x38}"
NODE="${4:-}"

# Build umshctl command with optional --node
UMCTL="/home/blkirk/umsh/target/release/umshctl -p $DEVICE"
if [ -n "$NODE" ]; then
    UMCTL="$UMCTL --node $NODE"
fi

# Register addresses
REG_STATUS=0x00
REG_DATA=0x00
CMD_INIT=0xBE
CMD_TRIGGER=0xAC
CMD_SOFTRESET=0xBA

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

# Convert hex string to unsigned 32-bit integer
hex_to_u32() {
    echo $((16#$1))
}

echo "Reading AHT30 at address $ADDR on bus $BUS..."

# Check status first
status=$(i2c_read 1)
status_val=$(hex_to_u32 $status)
echo "Initial status: 0x$status (${status_val})"

# Check if calibrated (bit 3)
if [ $((status_val & 0x08)) -eq 0 ]; then
    echo "Sensor not calibrated, sending init command..."
    i2c_write "be0800" >/dev/null
    sleep 0.01
    status=$(i2c_read 1)
    status_val=$(hex_to_u32 $status)
    echo "Status after init: 0x$status (${status_val})"
fi

# Soft reset if needed (bit 7 is busy)
if [ $((status_val & 0x80)) -ne 0 ]; then
    echo "Sensor busy, sending soft reset..."
    i2c_write "ba" >/dev/null
    sleep 0.02
    status=$(i2c_read 1)
    status_val=$(hex_to_u32 $status)
    echo "Status after reset: 0x$status (${status_val})"
fi

# Trigger measurement: 0xAC 0x33 0x00
echo "Triggering measurement..."
i2c_write "ac3300" >/dev/null

# Wait for measurement (max 80ms per datasheet)
sleep 0.08

# Read 7 bytes: status + 3 bytes humidity + 3 bytes temperature + 1 byte CRC
echo "Reading data..."
data=$(i2c_xfer "r:7")
if [ -z "$data" ] || [ ${#data} -ne 14 ]; then
    echo "Error: Failed to read data (got ${#data} chars, expected 14)"
    exit 1
fi

# Parse bytes
STATUS_HEX=${data:0:2}
HUM_MSB=${data:2:2}
HUM_MID=${data:4:2}
HUM_LSB=${data:6:2}
TEMP_MSB=${data:8:2}
TEMP_MID=${data:10:2}
TEMP_LSB=${data:12:2}
CRC_HEX=${data:14:2}

echo "Raw data: $data"
echo "  Status: 0x$STATUS_HEX"
echo "  Humidity bytes: $HUM_MSB $HUM_MID $HUM_LSB"
echo "  Temp bytes: $TEMP_MSB $TEMP_MID $TEMP_LSB"
echo "  CRC: 0x$CRC_HEX"

# Calculate 20-bit humidity value
HUM_RAW=$(( (16#$HUM_MSB << 12) | (16#$HUM_MID << 4) | (16#$HUM_LSB >> 4) ))

# Calculate 20-bit temperature value
TEMP_RAW=$(( ((16#$HUM_LSB & 0x0F) << 16) | (16#$TEMP_MSB << 8) | 16#$TEMP_MID ))

echo "  Humidity raw: $HUM_RAW"
echo "  Temp raw: $TEMP_RAW"

# Convert to physical values
# Humidity = raw / 2^20 * 100%
# Temperature = raw / 2^20 * 200 - 50
HUMIDITY=$(awk -v raw="$HUM_RAW" 'BEGIN { printf "%.2f", raw / 1048576.0 * 100.0 }')
TEMP_C=$(awk -v raw="$TEMP_RAW" 'BEGIN { printf "%.2f", raw / 1048576.0 * 200.0 - 50.0 }')

# Also calculate Fahrenheit
TEMP_F=$(awk -v c="$TEMP_C" 'BEGIN { printf "%.2f", c * 9.0 / 5.0 + 32.0 }')

# Verify CRC (CRC8 with polynomial 0x31, init 0xFF)
# CRC covers status + humidity[2:0] + temp[2:0] (6 bytes)
# Skip CRC verification for now (would need proper implementation)

echo ""
echo "Measurements:"
echo "  Humidity: ${HUMIDITY}% RH"
echo "  Temperature: ${TEMP_C}°C / ${TEMP_F}°F"
echo ""
echo "Status bits:"
echo "  Busy (bit 7): $(( (status_val >> 7) & 1 ))"
echo "  Calibrated (bit 3): $(( (status_val >> 3) & 1 ))"
echo "  Mode (bit 2:0): $(( status_val & 0x07 ))"