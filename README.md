# UMSH I2C Helper Scripts

Bash scripts for reading/writing common I2C sensors via `umshctl`. Supports both local and remote (UMSH network) I2C buses.

## Scripts

| Script | Sensor | Description |
|--------|--------|-------------|
| `read_ina219.sh` | INA219 | Current/power monitor (shunt + bus voltage, current, power) |
| `read_bmp085.sh` | BMP085/BMP180 | Barometric pressure + temperature |
| `read_aht30.sh` | AHT30/AHT20/AHT21 | Humidity + temperature |
| `read_pcf8591.sh` | PCF8591 | 4-channel 8-bit ADC + DAC |
| `write_pcf8591.sh` | PCF8591 | Write DAC output (AOUT) |

## Usage

All scripts share the same argument pattern:

```bash
./script.sh [device] [bus] [addr] [node_id] [sensor-specific-args...]
```

### Arguments

| Position | Argument | Default | Description |
|----------|----------|---------|-------------|
| 1 | `device` | `/dev/ttyACM0` | Serial device for umshctl |
| 2 | `bus` | `0` | I2C bus number |
| 3 | `addr` | sensor-specific | I2C address (hex, e.g., `0x40`) |
| 4 | `node_id` | *(none)* | **Optional** UMSH node ID for remote I2C |
| 5+ | sensor-specific | varies | See each script's usage |

### Local I2C (no node_id)

```bash
# Read INA219 on local bus 0, address 0x40
./read_ina219.sh /dev/ttyACM0 0 0x40

# Read BMP085 with defaults (bus 0, addr 0x77)
./read_bmp085.sh

# Read AHT30 at address 0x38
./read_aht30.sh /dev/ttyACM0 0 0x38
```

### Remote I2C (with node_id)

```bash
# Scan remote node first to verify connectivity
umshctl -p /dev/ttyACM0 --node 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp i2c scan 0

# Read INA219 on remote node
./read_ina219.sh /dev/ttyACM0 0 0x40 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp 0.1 3.2

# Read BMP085 on remote node
./read_bmp085.sh /dev/ttyACM0 0 0x77 33Esi6D3bJfqQM4n9LYTirdzecBteAKNvgscfvjBd2Tp
```

The `node_id` is the UMSH node's public key (base58-encoded ed25519). When provided, the scripts automatically add `--node <node_id>` to the `umshctl` command.

## Sensor-Specific Arguments

### read_ina219.sh
```bash
./read_ina219.sh [device] [bus] [addr] [node_id] [shunt_ohms] [max_amps]
# Defaults: shunt=0.1Ω, max_amps=3.2A
```

### read_bmp085.sh
```bash
./read_bmp085.sh [device] [bus] [addr] [node_id]
# addr defaults to 0x77
```

### read_aht30.sh
```bash
./read_aht30.sh [device] [bus] [addr] [node_id]
# addr defaults to 0x38
```

### read_pcf8591.sh
```bash
./read_pcf8591.sh [device] [bus] [addr] [node_id] [vref]
# vref defaults to 3.3V
```

### write_pcf8591.sh
```bash
./write_pcf8591.sh [device] [bus] [addr] [node_id] [dac_value]
# dac_value: 0x00-0xFF (hex) or 0-255 (decimal), defaults to 0x80
```

## Requirements

- `umshctl` binary at `/home/blkirk/umsh/target/release/umshctl`
- Access to serial device (typically `/dev/ttyACM0`)
- For remote: UMSH network connectivity to target node

## Example Output

```
$ ./read_ina219.sh /dev/ttyACM0 0 0x40
Reading INA219 at address 0x40 on bus 0...
Shunt: 0.1Ω, Max current: 3.2A
Configuration:
  Current_LSB = 0.0001 A/LSB
  Calibration register = 4096 (0x1000)
Writing calibration register...
Writing configuration register (0x399f)...

Measurements:
  Shunt voltage:  0.001234 V (1.234 mV)
  Bus voltage:    12.345 V
  Current (reg):  0.0123 A (12.300 mA)
  Current (V/R):  0.0123 A (12.300 mA)
  Power:          0.1523 W (152.300 mW)

Summary:
  Bus Voltage: 12.345 V
  Current:     0.0123 A
  Power:       0.1523 W
```