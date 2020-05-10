#!/usr/bin/with-contenv bash
# shellcheck shell=bash

###################################
## CREATE INFLUXDB DB IF ENABLED ##
###################################

if [[ ${INFLUXDB_ENABLED} == "true" ]]; then
    if result=$(curl -fsSL -XPOST "${INFLUXDB_HOST}/query" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-urlencode "q=SHOW DATABASES"); then
        [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Connection to [${INFLUXDB_HOST}] succeeded!"
        if echo "${result}" | jq -erc ".results[].series[].values[] | select(. == [\"${INFLUXDB_DB}\"])" > /dev/null; then
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Database [${INFLUXDB_DB}] found!"
        else
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Database [${INFLUXDB_DB}] not found! Creating database..."
            curl -fsSL -XPOST "${INFLUXDB_HOST}/query" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-urlencode "q=CREATE DATABASE ${INFLUXDB_DB}" > /dev/null
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Adding sample data..."
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "domains,host=sample-generator,domain=ipv4.cloudflare.com,recordtype=A ip=\"1.1.1.1\""
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "domains,host=sample-generator,domain=ipv6.cloudflare.com,recordtype=AAAA ip=\"2606:4700:4700::1111\""
        fi
    fi
fi

###################
## CONFIGURATION ##
###################

cfuser="${CF_USER}"
cfapikey="${CF_APIKEY}"
cfapitoken="${CF_APITOKEN}"
cfapitokenzone="${CF_APITOKEN_ZONE}"

DEFAULTIFS="${IFS}"
IFS=';'
read -r -a cfzone <<< "${CF_ZONES}"
read -r -a cfhost <<< "${CF_HOSTS}"
read -r -a cftype <<< "${CF_RECORDTYPES}"
IFS="${DEFAULTIFS}"

regexv4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
regexv6='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'

if [[ -z $1 ]]; then
    cache_location="/dev/shm"
else
    cache_location="$1"
fi

rm -f "${cache_location}"/*.cache

#################
## UPDATE LOOP ##
#################

while true; do

    ## CHECK FOR NEW IP ##
    newipv4="disabled"
    newipv6="disabled"
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Trying to get IP..."
    case "${DETECTION_MODE}" in
        dig-google.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(dig -6 TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')
            ;;
        dig-opendns.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(dig -4 A +short myip.opendns.com @resolver1.opendns.com)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(dig -6 AAAA +short myip.opendns.com @resolver1.opendns.com)
            ;;
        dig-whoami.cloudflare)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(dig -4 TXT +short whoami.cloudflare @1.1.1.1 ch | tr -d '"')
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(dig -6 TXT +short whoami.cloudflare @2606:4700:4700::1111 ch | tr -d '"')
            ;;
        curl-icanhazip.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 icanhazip.com)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 icanhazip.com)
            ;;
        curl-wtfismyip.com)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 wtfismyip.com/text)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 wtfismyip.com/text)
            ;;
        curl-showmyip.ca)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 showmyip.ca/ip.php)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 showmyip.ca/ip.php)
            ;;
        curl-da.gd)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 da.gd/ip)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 da.gd/ip)
            ;;
        curl-seeip.org)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 ip.seeip.org)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 ip.seeip.org)
            ;;
        curl-ifconfig.co)
            [[ ${CHECK_IPV4} == "true" ]] && newipv4=$(curl -fsL -4 ifconfig.co)
            [[ ${CHECK_IPV6} == "true" ]] && newipv6=$(curl -fsL -6 ifconfig.co)
            ;;
    esac
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - IPv4 is: [$newipv4]"
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - IPv6 is: [$newipv6]"

    ## LOG CONNECTION STATUS TO INFLUXDB IF ENABLED ##
    if [[ ${INFLUXDB_ENABLED} == "true" ]]; then
        [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Writing connection status to InfluxDB..."
        if [[ $newipv4 =~ $regexv4 ]]; then
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv4 status=1,ip=\"$newipv4\""
        else
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv4 status=0,ip=\"no ipv4\""
        fi

        if [[ $newipv6 =~ $regexv6 ]]; then
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv6 status=1,ip=\"$newipv6\""
        else
            curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "connection,host=$(hostname),type=ipv6 status=0,ip=\"no ipv6\""
        fi
    fi

    ## UPDATE DOMAINS ##
    for index in ${!cfhost[*]}; do

        if [[ -z ${cfzone[$index]} ]] || [[ -z ${cftype[$index]} ]]; then
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - MISCONFIGURATION DETECTED! Missing value for [CF_ZONES] or [CF_RECORDTYPES]."
            break
        fi

        cache="${cache_location}/cf-ddns-${cfhost[$index]}-${cftype[$index]}.cache"

        case "${cftype[$index]}" in
            A)
                regex="${regexv4}"
                newip="${newipv4}"
                ;;
            AAAA)
                regex="${regexv6}"
                newip="${newipv6}"
                ;;
        esac

        curl_header() {
            if [[ -n $cfapitokenzone ]] && [[ $* != *dns_records* ]]; then
                curl -s -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $cfapitokenzone" "$@"
            elif [[ -n $cfapitoken ]]; then
                curl -s -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $cfapitoken" "$@"
            else
                curl -s -H "Accept: application/json" -H "Content-Type: application/json" -H "X-Auth-Email: $cfuser" -H "X-Auth-Key: $cfapikey" "$@"
            fi
        }
        auth_log() {
            if [[ -n $cfapitokenzone ]] && [[ $* != *DNS* ]]; then
                [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - [${cftype[$index]}] -" "$@" "- Using [CF_APITOKEN_ZONE=$cfapitokenzone] to authenticate..."
            elif [[ -n $cfapitoken ]]; then
                [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - [${cftype[$index]}] -" "$@" "- Using [CF_APITOKEN=$cfapitoken] to authenticate..."
            else
                [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - [${cftype[$index]}] -" "$@" "- Using [CF_USER=$cfuser & CF_APIKEY=$cfapikey] to authenticate..."
            fi
        }
        verbose_debug_log() {
            [[ ${LOG_LEVEL} -gt 3 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - [${cftype[$index]}] -" "$@"
        }
        debug_log() {
            [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - [${cftype[$index]}] -" "$@"
        }
        verbose_log() {
            [[ ${LOG_LEVEL} -gt 1 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - [${cftype[$index]}] -" "$@"
        }
        log() {
            [[ ${LOG_LEVEL} -gt 0 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - [${DETECTION_MODE}] - [${cfhost[$index]}] - [${cftype[$index]}] -" "$@"
        }

        if ! [[ $newip =~ $regex ]]; then
            log "Returned IP by [${DETECTION_MODE}] is not valid! Check your connection."
        else
            if [[ ! -f "$cache" ]]; then
                zoneid=""
                dnsrecords=""
                if [[ ${cfzone[$index]} == *.* ]]; then
                    auth_log "Reading zone list from [Cloudflare]"
                    response=$(curl_header -X GET "https://api.cloudflare.com/client/v4/zones")
                    if [[ $(echo "${response}" | jq -r .success) == false ]]; then
                        log "Error response from [Cloudflare]:"
                        [[ ${LOG_LEVEL} -gt 0 ]] && echo "${response}" | jq
                    else
                        verbose_debug_log "Response from [Cloudflare]:"
                        [[ ${LOG_LEVEL} -gt 3 ]] && echo "${response}" | jq
                        zoneid=$(echo "${response}" | jq -r '.result[] | select (.name == "'"${cfzone[$index]}"'") | .id') && \
                        debug_log "Zone ID returned by [Cloudflare] is: $zoneid"
                    fi
                else
                    zoneid=${cfzone[$index]} && \
                    debug_log "Zone ID supplied by [CF_ZONES] is: $zoneid"
                fi
                if [[ -n $zoneid ]]; then
                    auth_log "Reading DNS records from [Cloudflare]"
                    response=$(curl_header -X GET "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records")
                    if [[ $(echo "${response}" | jq -r .success) == false ]]; then
                        log "Error response from [Cloudflare]:"
                        [[ ${LOG_LEVEL} -gt 0 ]] && echo "${response}" | jq
                    else
                        verbose_debug_log "Response from [Cloudflare]:"
                        [[ ${LOG_LEVEL} -gt 3 ]] && echo "${response}" | jq
                        dnsrecords=$(echo "${response}" | jq -r '.result[] | {name, id, zone_id, zone_name, content, type, proxied, ttl} | select (.name == "'"${cfhost[$index]}"'") | select (.type == "'"${cftype[$index]}"'")') && \
                        echo "$dnsrecords" > "$cache" && \
                        debug_log "Wrote DNS records to cache file: $cache"
                    fi
                fi
            else
                dnsrecords=$(cat "$cache") && \
                debug_log "Read back DNS records from cache file: $cache"
            fi
            if [[ -n ${dnsrecords} ]]; then
                zoneid=$(echo "$dnsrecords" | jq -r '.zone_id' | head -1)
                id=$(echo "$dnsrecords" | jq -r '.id' | head -1)
                proxied=$(echo "$dnsrecords" | jq -r '.proxied' | head -1)
                ttl=$(echo "$dnsrecords" | jq -r '.ttl' | head -1)
                ip=$(echo "$dnsrecords" | jq -r '.content' | head -1)
                if ! [[ $ip =~ $regex ]]; then
                    log "Returned IP by [Cloudflare] is not valid! Check your connection or configuration."
                else
                    if [[ "$ip" != "$newip" ]]; then
                        auth_log "Updating DNS record"
                        response=$(curl_header -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneid/dns_records/$id" --data '{"id":"'"$id"'","type":"'"${cftype[$index]}"'","name":"'"${cfhost[$index]}"'","content":"'"$newip"'","ttl":'"$ttl"',"proxied":'"$proxied"'}')
                        if [[ $(echo "${response}" | jq -r .success) == false ]]; then
                            log "Error response from [Cloudflare]:"
                            [[ ${LOG_LEVEL} -gt 0 ]] && echo "${response}" | jq
                        else
                            verbose_debug_log "Response from [Cloudflare]:"
                            [[ ${LOG_LEVEL} -gt 3 ]] && echo "${response}" | jq
                            log "Updating IP [$ip] to [$newip]: OK"
                            [[ ${INFLUXDB_ENABLED} == "true" ]] && curl -fsSL -XPOST "${INFLUXDB_HOST}/write?db=${INFLUXDB_DB}" -u "${INFLUXDB_USER}:${INFLUXDB_PASS}" --data-binary "domains,host=$(hostname),domain=${cfhost[$index]},recordtype=${cftype[$index]} ip=\"$newip\"" && \
                            debug_log "Wrote IP update to InfluxDB."
                            rm "$cache" && \
                            debug_log "Deleted cache file: $cache"
                        fi
                    else
                        verbose_log "Updating IP [$ip] to [$newip]: NO CHANGE"
                    fi
                fi
            else
                log "Reading DNS records failed!"
            fi
        fi

    done

    ## SLEEP ##
    [[ ${LOG_LEVEL} -gt 2 ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') - Going to sleep for ${INTERVAL} seconds..."
    sleep "${INTERVAL}"

done
