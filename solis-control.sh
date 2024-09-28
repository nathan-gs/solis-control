#!/usr/bin/env bash

set -euo pipefail

IsSilent=false
UseMqtt=false
MqttPrefix="solar/"
MqttPublishHaDiscovery=true
MqttHost="localhost"
MqttUser=""
MqttPassword=""

log() {
  if [ "$IsSilent" = false ];
  then
    echo $1
  fi
}

warn() {
  echo "$@" 1>&2;
}

help() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --silent: Silent mode"
  echo "  --mqtt-prefix <prefix> (default: solar/)"
  echo "  --mqtt-publish-ha <true|false> (default: true)"
  echo "  --mqtt-host: MQTT host"
  echo "  --mqtt-user: MQTT user"
  echo "  --mqtt-password: MQTT password"
  echo "  --solis-inverter: Inverter ID"
  echo "  --solis-keyid: Key ID"
  echo "  --solis-secret: Key secret"
  echo " "
  echo "  if --mqtt-user is set, mqtt will be used"

  exit 1
}

OPTS=$(getopt -o h --long 'silent,mqtt-prefix:,mqtt-publish-ha:,mqtt-host:,mqtt-user:,mqtt-password:,solis-inverter:,solis-keyid:,solis-secret:,help' -- "$@")

eval set -- "$OPTS"

while :
do
  case "$1" in
    --silent)
      IsSilent=true
      shift
      ;;
    --mqtt-prefix)
      MqttPrefix=$2
      shift 2
      ;;
    --mqtt-publish-ha)
      MqttPublishHaDiscovery=$2
      shift 2
      ;;
    --mqtt-host)
      MqttHost=$2
      shift 2
      ;;
    --mqtt-user)
      MqttUser=$2
      UseMqtt=true
      shift 2
      ;;
    --mqtt-password)
      MqttPassword=$2
      shift 2
      ;;
    --solis-inverter)
      InverterId=$2
      shift 2
      ;;
    --solis-keyid)
      KeyId=$2
      shift 2
      ;;
    --solis-secret)
      KeySecret=$2
      shift 2
      ;;
    --help)
      help
      shift 1
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      help
      exit 1
      ;;
  esac
done

if [[ -z "$InverterId" || -z "$KeyId" || -z "$KeySecret" ]]; then
  warn "InverterId, KeyId and KeySecret must be set"
  help
  exit 1
fi

if [[ "$UseMqtt" == true && ( -z "$MqttHost" || -z "$MqttUser" || -z "$MqttPassword" ) ]]; then
  warn "MqttHost, MqttUser and MqttPassword must be set"
  help
  exit 1
fi

# https://oss.soliscloud.com/doc/SolisCloud%20Device%20Control%20API%20V2.0.pdf

Battery_OverdischargeSocCid=158
Battery_ForcechargeSocCid=160
Battery_MaxGridPower=676
SelfUse_ChargeAndDischargeCid=4643
SelfUse_AllowGridChargingCid=109

solisApiPost() {
  CanonicalizedResource=$1
  Content=$2
  # Required variables

  
  Content_Type="application/json;charset=UTF-8"      # e.g., application/json, text/plain
  Date=$(date -u +"%a, %d %b %Y %H:%M:%S GMT")
  
  VERB="POST" # e.g., GET, POST, PUT, DELETE

  # Generate the Content-MD5 header
  Content_MD5=$(echo -en "$Content" | openssl dgst -md5 -binary | base64)

  # String to sign
  StringToSign="$VERB\n$Content_MD5\n$Content_Type\n$Date\n$CanonicalizedResource"

  # Generate the HMAC-SHA1 signature and then base64 encode it
  Sign=$(echo -en "$StringToSign" | openssl dgst -sha1 -hmac "$KeySecret" -binary | base64)

  # Authorization header
  Authorization="API $KeyId:$Sign"

  # Example curl command using the generated Authorization header
  curl --silent \
      -H "Authorization: $Authorization" \
      -H "Content-MD5: $Content_MD5" \
      -H "Content-Type: $Content_Type" \
      -H "Date: $Date" \
      --json "$Content"  \
      "https://www.soliscloud.com:13333$CanonicalizedResource"

}

solisReadCid() {
  cid=$1
  content=$(jq -n -c \
    --arg INVERTER "$InverterId" \
    --arg CID "$cid" \
    '{inverterId: $INVERTER, cid: $CID}'
  )

  output=$(solisApiPost "/v2/api/atRead" "$content")
  if [[ $(echo $output | jq -r '.code') == "0" ]];
  then
    echo $output | jq -r '.data.msg'
    return 0
  else
    warn "failed, complete error: "
    warn $output
    return 1
  fi
}

solisWriteCid() {
  cid=$1
  value=$2
  content=$(jq -n -c \
    --arg INVERTER "$InverterId" \
    --arg CID "$cid" \
    --arg VALUE "$value" \
    '{inverterId: $INVERTER, cid: $CID, value: $VALUE}'
  )

  output=$(solisApiPost "/v2/api/control" "$content")
  if [[ $? -ne 0 ]]; then
    warn "solisApiPost did not return 0"
    return 1
  fi  

  code=$(echo "$output" | jq -r '.code' 2>/dev/null)
  if [[ -z "$code" || ! "$code" =~ ^[0-9]+$ ]]; then
    warn "Failed to parse 'code' from output"
    warn "$output"
    return 1
  fi
  
  if [[ "$code" -ne 0 ]]; then
    warn "Failed, complete error: "
    warn "$output"
    return 1  
  fi
  
  return 0
}

checkTime() {
  input=$1
  if [[ $input =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    true
  else
    echo "Invalid date: $input"
    return 1
  fi
}

writeSelfUseChargeAndDischarge() {
  chargeCurrent=$1
  dischargeCurrent=$2
  chargeTimeStart=$3
  chargeTimeEnd=$4
  dischargeTimeStart=$5
  dischargeTimeEnd=$6

  checkTime $chargeTimeStart
  checkTime $chargeTimeEnd 
  checkTime $dischargeTimeStart 
  checkTime $dischargeTimeEnd 
  echo "$chargeCurrent,$dischargeCurrent,$chargeTimeStart-$chargeTimeEnd,$dischargeTimeStart-$dischargeTimeEnd"
}

mqttPublish() {
  topic=$1
  message=$2
  if [[ "$UseMqtt" == false ]]; then
    return 0
  fi
  mosquitto_pub -h $MqttHost -t "$topic" -m "$message" -u $MqttUser -P $MqttPassword --retain 
}

haDiscoverySwitch() {
  topic=$1
  haId="${topic//\//_}"
  
  if [[ "$MqttPublishHaDiscovery" == false ]]; then
    return 0
  fi  

  content=$(jq -n -c \
    --arg COMMAND_TOPIC "$topic/set" \
    --arg NAME "$topic" \
    --arg OBJECT_ID "$haId" \
    --arg STATE_TOPIC "$topic" \
    '{ command_topic: $COMMAND_TOPIC, name: $NAME, object_id: $OBJECT_ID, payload_off: "0", payload_on: "1", state_topic: $STATE_TOPIC }'
  )
  mqttPublish "homeassistant/switch/$haId/switch/config" "$content"
  log "Published Home Assistant discovery for $topic"
}

haDiscoveryNumber() {
  topic=$1
  min=$2
  max=$3

  if [[ "$MqttPublishHaDiscovery" == false ]]; then
    return 0
  fi

  haId="${topic//\//_}"
  content=$(jq -n -c \
    --arg COMMAND_TOPIC "$topic/set" \
    --arg NAME "$topic" \
    --arg OBJECT_ID "$haId" \
    --arg STATE_TOPIC "$topic" \
    --arg min "$min" \
    --arg max "$max" \
    '{ command_topic: $COMMAND_TOPIC, name: $NAME, object_id: $OBJECT_ID, state_topic: $STATE_TOPIC, unit_of_measurement: "%", device_class: "battery", min: $min, max: $max, step: 1, mode: "box" }'
  )
  mqttPublish "homeassistant/number/$haId/number/config" "$content"
  log "Published Home Assistant discovery for $topic"
}

mqttPublishHaDiscovery() {
  

  log "Publishing Home Assistant discovery"

  #haDiscoverySwitch "$MqttPrefix"selfuse/AllowGridCharging
  haDiscoveryNumber "$MqttPrefix"battery/OverdischargeSoc 10 40
  haDiscoveryNumber "$MqttPrefix"battery/ForcechargeSoc 4 20

}

mqttMessageRouter() {
  local topic="$1"
  local message="$2"
    
  log "Reacting to topic: $topic with message: $message"
  case $topic in
    $MqttPrefix"battery/OverdischargeSoc/set")
      if [[ "$message" =~ ^[0-9]+$ && "$message" -le 40 ]]; then
        if solisWriteCid $Battery_OverdischargeSocCid "$message"; then
          value=$(solisReadCid $Battery_OverdischargeSocCid)
          mqttPublish "$MqttPrefix"battery/OverdischargeSoc $value
          if (( value <= 20 )); then
            maxForcechargeSoc=$value
          else
            maxForcechargeSoc=20
          fi
          haDiscoveryNumber "$MqttPrefix"battery/ForcechargeSoc 4 $maxForcechargeSoc
          log "OverdischargeSoc set to $value"
        else
          warn "Failed to set OverdischargeSoc"
        fi
      else
        warn "$MqttPrefix"battery/OverdischargeSoc/set" message must be a number between 0 and 40, received $message"
      fi
      ;;
    $MqttPrefix"battery/ForcechargeSoc/set")
      if [[ "$message" =~ ^[0-9]+$ && "$message" -le 20 ]]; then
        if solisWriteCid $Battery_ForcechargeSocCid "$message"; then
          mqttPublish "$MqttPrefix"battery/ForcechargeSoc $(solisReadCid $Battery_ForcechargeSocCid)          
          log "ForcechargeSoc set to $message"
        else
          warn "Failed to set ForcechargeSoc"
        fi
      else
        warn "$MqttPrefix"battery/ForcechargeSoc/set" message must be a number between 0 and 20, received $message"
      fi
      ;;
    $MqttPrefix"selfuse/ChargeAndDischarge/set")
      warn "ChargeAndDischarge not implemented yet"
      ;;
    $MqttPrefix"selfuse/AllowGridCharging/set")      
      if [[ "$message" == "0" || "$message" == "1" ]]; then
        warn "AllowCharging not implemented yet"
        #solisReadCid $SelfUse_AllowGridChargingCid
        #if solisWriteCid $SelfUse_AllowGridChargingCid "$message"; then
        #  mqttPublish "$MqttPrefix"selfuse/AllowGridCharging $(solisReadCid $SelfUse_AllowGridChargingCid)
        #  log "AllowGridCharging set to $message"
        #else
        #  warn "Failed to set AllowGridCharging"
        #fi
        # Currently the error is
        # {"success":true,"code":"B0218","msg":"This command needs to be read and then set","data":null}
        #
      else
        warn "$MqttPrefix"selfuse/AllowGridCharging/set" message must be 0 or 1, received $message"
      fi
      ;;
    *)
      warn "Unknown topic: $topic"
      ;;
  esac
}


subscribeMqtt() {

  while true; do
    log "Subscribing to the following MQTT topics:"
    log " - $MqttPrefix"battery/OverdischargeSoc/set
    log " - $MqttPrefix"battery/ForcechargeSoc/set
    log " - $MqttPrefix"selfuse/ChargeAndDischarge/set
    log " - $MqttPrefix"selfuse/AllowGridCharging/set


    mosquitto_sub \
      -h $MqttHost \
      -t $MqttPrefix"battery/OverdischargeSoc/set" \
      -t $MqttPrefix"battery/ForcechargeSoc/set" \
      -t $MqttPrefix"selfuse/ChargeAndDischarge/set" \
      -t $MqttPrefix"selfuse/AllowGridCharging/set" \
      -u $MqttUser \
      -P $MqttPassword \
      -v | while read -r line; do
        topic=$(echo "$line" | awk '{print $1}')
        message=$(echo "$line" | cut -d' ' -f2-)
        mqttMessageRouter "$topic" "$message"
      done

    warn "mosquitto_sub exited, restarting in 5 seconds"
    sleep 5
  done
}

initialReadAndPublish() {
  log "Initial reading values and publishing to MQTT"
  value=$(solisReadCid $Battery_OverdischargeSocCid)
  if (( value <= 20 )); then
    maxForcechargeSoc=$value
  else
    maxForcechargeSoc=20
  fi
  haDiscoveryNumber "$MqttPrefix"battery/ForcechargeSoc 4 $maxForcechargeSoc

  mqttPublish "$MqttPrefix"battery/ForcechargeSoc $(solisReadCid $Battery_ForcechargeSocCid)
  #mqttPublish "$MqttPrefix"selfuse/AllowGridCharging $(solisReadCid $SelfUse_AllowGridChargingCid)
}

mqttPublishHaDiscovery
initialReadAndPublish
subscribeMqtt

exit 0




