# Solis Control

A bash script to control the Solis Inverter via the Solis Cloud API and MQTT.


> [!CAUTION]
> This script is not officially supported by Solis and may void your warranty. You are writing to the Inverter, which might be very dangerous, use at your own risk. I am not responsible for any damage, loss of live, fire, etc or loss of warranty.

## Usage

```bash
./solis-control.sh --help
```

## Functionality

This bash script connects to MQTT (and can also publish Home Assistant entities to the discovery topic), where it awaits inputs, on reaction of an input it will write to the SolisCloud API. You need to have enabled SolisCloud API write access through Solis support. 

Currently it's supports following topics/functionality:

- $MqttPrefix"battery/OverdischargeSoc/set
- $MqttPrefix"battery/ForcechargeSoc/set
- $MqttPrefix"selfuse/ChargeAndDischarge/set
- $MqttPrefix"selfuse/AllowGridCharging/set

Once it receives info on a `set` topic, it calls the SolisCloud API to write, and reads the written value from the SolisCloud api before writing it back to the MQTT topic. 