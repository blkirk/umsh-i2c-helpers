#!/bin/bash
# Read BMP085/BMP180 pressure and temperature via umshctl I2C commands
# Usage: ./read_bmp085.sh [device_path] [bus_number] [i2c_addr] [node_id]
# Default: /dev/ttyACM0 bus 0 0x77 (no node)
#
# node_id: optional UMSH node ID for remote I2C (e.g., 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp)

set -euo pipefail

DEVICE="${1:-/dev/ttyACM0}"
BUS="${2:-0}"
ADDR="${3:-0x77}"
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

# Helper: run umshctl i2c read command and parse hex output
i2c_read() {
    local reg=$1
    local len=$2
    $UMCTL i2c read $BUS $ADDR $len --reg $reg 2>&1 | tr -d ' \n'
}

# Helper: run umshctl i2c write command
i2c_write() {
    local data=$1
    $UMCTL i2c write $BUS $ADDR $data 2>&1
}

# Helper: run umshctl i2c xfer for combined write+read
i2c_xfer() {
    local ops=$1
    $UMCTL i2c xfer $BUS $ADDR $ops 2>&1 | tr -d ' \n'
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

# Convert hex string to unsigned 32-bit integer (from 3 bytes)
hex_to_u24() {
    echo $((16#$1))
}

echo "Reading BMP085 calibration data..."

# Read all 22 bytes of calibration data from registers 0xAA-0xBE
cal_data=$(i2c_xfer "w:aa r:22")
if [ -z "$cal_data" ] || [ ${#cal_data} -ne 44 ]; then
    echo "Error: Failed to read calibration data (got ${#cal_data} chars, expected 44)"
    exit 1
fi

# Parse calibration coefficients (big-endian, 16-bit each)
AC1=$(hex_to_i16 ${cal_data:0:4})
AC2=$(hex_to_i16 ${cal_data:4:4})
AC3=$(hex_to_i16 ${cal_data:8:4})
AC4=$(hex_to_u16 ${cal_data:12:4})
AC5=$(hex_to_u16 ${cal_data:16:4})
AC6=$(hex_to_u16 ${cal_data:20:4})
B1=$(hex_to_i16 ${cal_data:24:4})
B2=$(hex_to_i16 ${cal_data:28:4})
MB=$(hex_to_i16 ${cal_data:32:4})
MC=$(hex_to_i16 ${cal_data:36:4})
MD=$(hex_to_i16 ${cal_data:40:4})

echo "Calibration coefficients:"
echo "  AC1=$AC1  AC2=$AC2  AC3=$AC3  AC4=$AC4  AC5=$AC5  AC6=$AC6"
echo "  B1=$B1  B2=$B2  MB=$MB  MC=$MC  MD=$MD"

# Read temperature
echo "Reading temperature..."
i2c_write "f42e" >/dev/null  # Write 0x2E to register 0xF4 (start temp conversion)
sleep 0.005  # Wait 4.5ms minimum

temp_data=$(i2c_xfer "w:f6 r:2")
if [ -z "$temp_data" ] || [ ${#temp_data} -ne 4 ]; then
    echo "Error: Failed to read temperature data"
    exit 1
fi

UT=$(hex_to_u16 $temp_data)
echo "  Raw temperature (UT) = $UT"

# Calculate true temperature
# X1 = (UT - AC6) * AC5 / 2^15
# X2 = MC * 2^11 / (X1 + MD)
# B5 = X1 + X2
# T = (B5 + 8) / 16  (in 0.1°C units)

X1=$(( (UT - AC6) * AC5 / 32768 ))
X2=$(( (MC * 2048) / (X1 + MD) ))
B5=$(( X1 + X2 ))
TEMP=$(( (B5 + 8) / 16 ))  # Temperature in 0.1°C

TEMP_C=$(echo "scale=1; $TEMP / 10" | bc -l)
TEMP_F=$(echo "scale=1; $TEMP_C * 9 / 5 + 32" | bc -l)
echo "  Temperature = ${TEMP_C}°C / ${TEMP_F}°F"

# Read pressure (OSS = 0, ultra low power)
echo "Reading pressure..."
i2c_write "f434" >/dev/null  # Write 0x34 to register 0xF4 (start pressure conversion, OSS=0)
sleep 0.005  # Wait 4.5ms minimum for OSS=0

press_data=$(i2c_xfer "w:f6 r:3")
if [ -z "$press_data" ] || [ ${#press_data} -ne 6 ]; then
    echo "Error: Failed to read pressure data"
    exit 1
fi

# Pressure is 24-bit: MSB, LSB, XLSB
UP=$(( (16#${press_data:0:2} << 16) | (16#${press_data:2:2} << 8) | 16#${press_data:4:2} ))
UP=$(( UP >> 8 ))  # For OSS=0, shift right by 8 (we only use MSB and LSB effectively)

echo "  Raw pressure (UP) = $UP"

# Calculate true pressure
# B6 = B5 - 4000
# X1 = (B2 * (B6 * B6 / 2^12)) / 2^11
# X2 = AC2 * B6 / 2^11
# X3 = X1 + X2
# B3 = ((AC1 * 4 + X3) + 2) / 4
# X1 = AC3 * B6 / 2^13
# X2 = (B1 * (B6 * B6 / 2^12)) / 2^16
# X3 = (X1 + X2 + 2) / 4
# B4 = AC4 * (X3 + 32768) / 2^15
# B7 = (UP - B3) * (50000 >> OSS)
# if B7 < 0x80000000: P = (B7 * 2) / B4 else P = (B7 / B4) * 2
# X1 = (P / 2^8)^2
# X1 = (X1 * 3038) / 2^16
# X2 = (-7357 * P) / 2^16
# P = P + (X1 + X2 + 3791) / 2^4

B6=$(( B5 - 4000 ))

# X1 = (B2 * (B6^2 / 4096)) / 2048
B6_sq=$(( B6 * B6 ))
X1=$(( (B2 * (B6_sq / 4096)) / 2048 ))

# X2 = AC2 * B6 / 2048
X2=$(( AC2 * B6 / 2048 ))

X3=$(( X1 + X2 ))
B3=$(( ((AC1 * 4 + X3) + 2) / 4 ))

# X1 = AC3 * B6 / 8192
X1=$(( AC3 * B6 / 8192 ))

# X2 = (B1 * (B6^2 / 4096)) / 65536
X2=$(( (B1 * (B6_sq / 4096)) / 65536 ))

X3=$(( (X1 + X2 + 2) / 4 ))
B4=$(( (AC4 * (X3 + 32768)) / 32768 ))

B7=$(( (UP - B3) * 50000 ))  # OSS=0, so 50000 >> 0 = 50000

if [ $B7 -lt 2147483648 ]; then  # 0x80000000
    P=$(( (B7 * 2) / B4 ))
else
    P=$(( (B7 / B4) * 2 ))
fi

# Second order compensation
X1=$(( (P / 256) * (P / 256) ))
X1=$(( (X1 * 3038) / 65536 ))
X2=$(( (-7357 * P) / 65536 ))
P=$(( P + (X1 + X2 + 3791) / 16 ))

# Pressure in Pa, convert to hPa (mbar)
PRESSURE_HPA=$(echo "scale=2; $P / 100" | bc -l)

echo "  Pressure = ${PRESSURE_HPA} hPa (${P} Pa)"

# Also output in inches of mercury
PRESSURE_INHG=$(echo "scale=2; $PRESSURE_HPA * 0.02953" | bc -l)
echo "  Pressure = ${PRESSURE_INHG} inHg"

echo ""
echo "Summary:"
echo "  Temperature: ${TEMP_C}°C / ${TEMP_F}°F"
echo "  Pressure:    ${PRESSURE_HPA} hPa / ${PRESSURE_INHG} inHg"