#!/bin/bash

set -uo pipefail

SSH_USER="${SSH_USER:-root}"
SSH_OPTS="-o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o LogLevel=error"

usage() {
    echo "Usage: $0 [-u user] [-f file] [ip1] [ip2] ..."
    echo "  -u <user>   SSH username (default: root)"
    echo "  -f <file>   Read IP list from file"
    echo "  -h          Show help"
    exit 1
}

IPS=()
LIST_FILE=""
while getopts ":u:f:h" opt; do
    case $opt in
        u) SSH_USER="$OPTARG" ;;
        f) LIST_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [[ -n "$LIST_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        IPS+=("$line")
    done < "$LIST_FILE"
elif [[ $# -gt 0 ]]; then
    IPS=("$@")
else
    usage
fi

# DNS tool selection (local machine)
HAVE_DIG=0; HAVE_NSLOOKUP=0
command -v dig &>/dev/null && HAVE_DIG=1
command -v nslookup &>/dev/null && HAVE_NSLOOKUP=1

ptr_query() {
    local ip="$1"
    if [[ $HAVE_DIG -eq 1 ]]; then
        dig +short -x "$ip" 2>/dev/null | sed 's/\.$//' | head -1
    elif [[ $HAVE_NSLOOKUP -eq 1 ]]; then
        nslookup "$ip" 2>/dev/null | awk -F'name = ' '/name = /{gsub(/\.$/,"",$2); print $2; exit}'
    fi
}

a_query() {
    local host="$1"
    if [[ $HAVE_DIG -eq 1 ]]; then
        dig +short "$host" 2>/dev/null | head -1
    elif [[ $HAVE_NSLOOKUP -eq 1 ]]; then
        nslookup "$host" 2>/dev/null | awk '/^Address: / && !/#/ {print $2; exit}'
    fi
}

for IP in "${IPS[@]}"; do
    # Get short hostname from remote server
    SHORT_HOST=$(ssh $SSH_OPTS "${SSH_USER}@${IP}" "hostname -s 2>/dev/null" || true)
    [[ -z "$SHORT_HOST" ]] && SHORT_HOST="unknown"

    echo "=================================================="
    echo " IP: $IP  |  Host: $SHORT_HOST"
    echo "=================================================="

    # Collect interfaces and IPs from remote server
    echo ""
    echo "[Interfaces]"

    IFACE_RAW=$(ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "ip -brief addr show 2>/dev/null | awk 'NR>1 {split(\$3,a,\"/\"); printf \"%s|%s\n\", \$1, a[1]}'" \
        || true)

    if [[ -z "$IFACE_RAW" ]]; then
        # switch to ifconfig if ip is not found
        IFACE_RAW=$(ssh $SSH_OPTS "${SSH_USER}@${IP}" \
            "/sbin/ifconfig -a 2>/dev/null | awk '/^[a-z0-9]/ {iface=\$1} /inet / {split(\$2,a,\":\"); printf \"%s|%s\n\", iface, a[2]}'" \
            || true)
    fi

    declare -a IFACES=()
    declare -a ADDRS=()

    if [[ -z "$IFACE_RAW" ]]; then
        echo "  (Interfaces information not found)"
    else
        while IFS='|' read -r iface addr; do
            IFACES+=("$iface")
            [[ -z "$addr" ]] && addr="-"
            ADDRS+=("$addr")
            printf "  %-12s : %s\n" "$iface" "$addr"
        done <<< "$IFACE_RAW"
    fi

    # Default gateway
    echo ""
    echo "[Default GW]"

    GW_RAW=$(ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "ip route | grep '^default' | head -1" \
        || true)

    if [[ -z "$GW_RAW" ]]; then
        echo "  Default GW Not Found"
    else
        GW=$(echo "$GW_RAW" | awk '{print $3}')
        GW_IFACE=$(echo "$GW_RAW" | awk '{print $5}')
        [[ -z "$GW" ]] && GW="-"
        [[ -z "$GW_IFACE" ]] && GW_IFACE="-"
        echo "  GW: $GW  |  Interface: $GW_IFACE"
    fi

    # DNS records: for ALL IP addresses on remote server
    echo ""
    echo "[DNS Records]"

    DNS_FOUND=0
    for i in "${!ADDRS[@]}"; do
        IP_ADDR="${ADDRS[$i]}"
        [[ "$IP_ADDR" == "-" ]] && continue

        DNS_FOUND=1
        echo "  Target IP: $IP_ADDR (${IFACES[$i]})"

        PTR=$(ptr_query "$IP_ADDR")
        [[ -z "$PTR" ]] && PTR="-"
        echo "    PTR : $PTR"

        if [[ "$PTR" != "-" ]]; then
            A=$(a_query "$PTR")
            [[ -z "$A" ]] && A="-"
            echo "    A   : $A ($PTR)"
        else
            echo "    A   : -"
        fi
        echo ""
    done

    if [[ $DNS_FOUND -eq 0 ]]; then
        echo "  No resolvable IP address found."
    fi

    echo ""
done
