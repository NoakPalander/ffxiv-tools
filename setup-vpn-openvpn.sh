#!/bin/bash

OVPN_CONFIG_FILE="$1"

if [ ! -e "$OVPN_CONFIG_FILE" ]; then
    echo "Passed non-existant config file $OVPN_CONFIG_FILE!"
    exit 1
fi

. helpers/error.sh
. helpers/prompt.sh
. helpers/vpn.sh

YES_NO=( Yes No )
YES_NO_ANSWER=""

OVPN_CONFIG_DEST="$HOME/bin/ffxiv-vpn.conf"
OVPN_UP_DEST="$HOME/bin/ffxiv-vpn.up"
OVPN_HELPER_DEST="$HOME/bin/ffxiv-vpn-helper.sh"
OVPN_HELPER_CONFIG_DEST="$HOME/bin/ffxiv-vpn-helper-config.sh"
SCRIPT_RUN_ACT_DEST="$HOME/bin/ffxiv-vpn-run-act.sh"
SCRIPT_RUN_GAME_DEST="$HOME/bin/ffxiv-vpn-run-game.sh"
SCRIPT_RUN_BOTH_DEST="$HOME/bin/ffxiv-vpn-run-both.sh"
SCRIPT_RUN_OTHER_DEST="$HOME/bin/ffxiv-vpn-run-other.sh"
SCRIPT_RESET_VPN_DEST="$HOME/bin/ffxiv-vpn-reset-vpn.sh"

OVPN_CONFIG_CONTENTS="$(cat $OVPN_CONFIG_FILE)"
UP_FILE_CONTENTS=""

echo "Setting up VPN config for OpenVPN with config file at $OVPN_CONFIG_FILE"

echo "Checking for authentication settings in config file..."

HAS_USER_AUTH_PASS="$(echo "$OVPN_CONFIG_CONTENTS" | grep auth-user-pass | sed -re 's/^[ ]+//g' | sed -re 's/[ ]+$//g')"

if [[ "$HAS_USER_AUTH_PASS" != "" ]]; then
    if [[ "$HAS_USER_AUTH_PASS" == "auth-user-pass" ]]; then
        success "Found auth-user-pass authentication setting with no saved credentials."
        echo "Would you like to save your username and password alongside the config file in $HOME/bin?"
        echo "Username and password are saved unencrypted. This is optional, choosing not to save"
        echo "your credentials will result in having to enter them every time."

        PROMPT_IN_ARRAY "YES_NO" "YES_NO_ANSWER" "Save credentials? "

        if [[ "$YES_NO_ANSWER" == "0" ]]; then
            read -p "Username? " UP_USERNAME
            read -p "Password? " UP_PASSWORD
            UP_FILE_CONTENTS="$UP_USERNAME"$'\n'"$UP_PASSWORD"
            OVPN_CONFIG_CONTENTS="$(echo "$OVPN_CONFIG_CONTENTS" | sed -re "s#auth-user-pass#auth-user-pass $OVPN_UP_DEST#g")"
        fi
    else
        warn "Found auth-user-pass authentication with saved credentials or some other password mechanism."
    fi
else
    warn "No authentication settings detected"
fi

echo "Checking active local IP ranges to determine an unused range for the network namespace..."

IP_SUBNET="$(FIND_UNUSED_SUBNET)"

if [[ "$IP_SUBNET" == "1" ]]; then
    error "Could not find an unused subnet (somehow). Aborting install"
fi

OIFS="$IFS"
IFS=$'\n'
NETWORK_INTERFACES=( $(ip link | grep -Po '^\d+: [^:]+' | cut -d' ' -f2-) )
IFS="$OIFS"

PROMPT_IN_ARRAY "NETWORK_INTERFACES" "NETWORK_INTERFACES_ANSWER" "Network Interface? "\
 "Which network interface do you use to connect to the internet?
You can manually change this later by modifying $OVPN_HELPER_CONFIG_DEST"

IP_ADDR="$(ip addr show "${NETWORK_INTERFACES[NETWORK_INTERFACES_ANSWER]}" | grep -Po 'inet \d+\.\d+\.\d+\.\d+/\d+' | sed -e 's/inet //g')"

IP_ADDR_START="$(IP_TO_OCTETS "$(echo "$(GET_IP_RANGE "$IP_ADDR")" | cut -d' ' -f1)")"
IP_ADDR_MASK="$(ifconfig ${NETWORK_INTERFACES[NETWORK_INTERFACES_ANSWER]} | grep -Po 'netmask \d+\.\d+\.\d+\.\d+' | cut -d' ' -f2)"

OVPN_CONFIG_CONTENTS="$OVPN_CONFIG_CONTENTS"$'\n'"route $IP_ADDR_START $IP_ADDR_MASK ${IP_SUBNET}2"$'\n'"route ${IP_SUBNET}0 $IP_ADDR_MASK ${IP_SUBNET}2"

SCRIPT_HELPER_CONFIG=$(cat << EOF
#!/bin/bash

TARGET_USER="$USER"
FFXIV_VPN_NAMESPACE="ffxiv"
FFXIV_VPN_SUBNET="$IP_SUBNET"
TARGET_INTERFACE="${NETWORK_INTERFACES[NETWORK_INTERFACES_ANSWER]}"
OPENVPN="\$(which openvpn)"

EOF
)

SCRIPT_HELPER=$(cat << EOF
#!/bin/bash

if [[ "\$(id -u)" != "0" ]]; then
    echo "This script must be run via sudo"
    exit 1
fi

. "$OVPN_HELPER_CONFIG_DEST"

RUN_NETWORK_NAMESPACE() {
    # Enable IPv4 traffic forwarding
    sysctl -q net.ipv4.ip_forward=1
    # Create the network namespace folder used for resolving IPs
    mkdir -p "/etc/netns/\$FFXIV_VPN_NAMESPACE"
    # Set up DNS resolution to work through VPN by hardcoding to public DNS servers
    echo -e "nameserver 1.1.1.1\\nnameserver 1.0.0.1\\nnameserver 8.8.8.8\\nnameserver 8.8.4.4" > "/etc/netns/\$FFXIV_VPN_NAMESPACE/resolv.conf"
    # Create network namespace
    ip netns add "\$FFXIV_VPN_NAMESPACE"
    # Create Virtual Ethernet (VETH) pair, start them up
    ip link add "veth_a_\$FFXIV_VPN_NAMESPACE" type veth peer name "veth_b_\$FFXIV_VPN_NAMESPACE"
    ip link set "veth_a_\$FFXIV_VPN_NAMESPACE" up
    # Create TAP adapter and bridge, bridge TAP with VETH A
    ip tuntap add "tap_\$FFXIV_VPN_NAMESPACE" mode tap user root
    ip link set "tap_\$FFXIV_VPN_NAMESPACE" up
    ip link add "br_\$FFXIV_VPN_NAMESPACE" type bridge
    ip link set "tap_\$FFXIV_VPN_NAMESPACE" master "br_\$FFXIV_VPN_NAMESPACE"
    ip link set "veth_a_\$FFXIV_VPN_NAMESPACE" master "br_\$FFXIV_VPN_NAMESPACE"
    # Give bridge an IP address, start it up
    ip addr add "\${FFXIV_VPN_SUBNET}1/24" dev "br_\$FFXIV_VPN_NAMESPACE"
    ip link set "br_\$FFXIV_VPN_NAMESPACE" up
    # Assign VETH B to exist in network namespace, give it an IP address, start it up
    ip link set "veth_b_\$FFXIV_VPN_NAMESPACE" netns "\$FFXIV_VPN_NAMESPACE"
    ip netns exec "\$FFXIV_VPN_NAMESPACE" ip addr add "\${FFXIV_VPN_SUBNET}2/24" dev "veth_b_\$FFXIV_VPN_NAMESPACE"
    ip netns exec "\$FFXIV_VPN_NAMESPACE" ip link set "veth_b_\$FFXIV_VPN_NAMESPACE" up
    # Create a loopback interface in network namespace, start it up
    ip netns exec "\$FFXIV_VPN_NAMESPACE" ip link set dev lo up
    # Set up NAT forwarding of traffic so that bridged network can communicate with internet
    iptables -t nat -A POSTROUTING -s "\${FFXIV_VPN_SUBNET}0/24" -o en+ -j MASQUERADE
    # Add default route to network namespace or else traffic won't route properly
    ip netns exec "\$FFXIV_VPN_NAMESPACE" ip route add default via "\${FFXIV_VPN_SUBNET}1"
}

CLOSE_NETWORK_NAMESPACE() {
    # A bit overkill, deleting the network namespace should cascade delete the rest of these interfaces
    # But just in case something went wrong during the creation process
    ip netns delete "\$FFXIV_VPN_NAMESPACE" &> /dev/null
    ip link delete "veth_a_\$FFXIV_VPN_NAMESPACE" &> /dev/null
    ip link delete "veth_b_\$FFXIV_VPN_NAMESPACE" &> /dev/null
    ip link delete "tap_\$FFXIV_VPN_NAMESPACE" &> /dev/null
    ip link delete "br_\$FFXIV_VPN_NAMESPACE" &> /dev/null
    # Clean up the DNS resolver for the network namespace
    rm -rf "/etc/netns/\$FFXIV_VPN_NAMESPACE"
    # Drop the iptables rule for traffic forwarding to the network namespace
    iptables -t nat -D POSTROUTING -s "\${FFXIV_VPN_SUBNET}0/24" -o en+ -j MASQUERADE
}

RUN_VPN() {
    # Run the vpn command within the target network namespace as the target user
    ip netns exec "\$FFXIV_VPN_NAMESPACE" "\$OPENVPN" --suppress-timestamps --nobind --config "$OVPN_CONFIG_DEST" --writepid "/tmp/vpn_ns_\$FFXIV_VPN_NAMESPACE.pid" --syslog "ffxiv_vpn" &> /dev/null &
    # Wait a few seconds for the VPN connection to establish before we proceed
    sleep 3
}

CLOSE_VPN() {
    kill "\$(cat "/tmp/vpn_ns_\$FFXIV_VPN_NAMESPACE.pid")"
}

RUN_COMMAND() {
    ip netns exec "\$FFXIV_VPN_NAMESPACE" sudo -u "\$TARGET_USER" \$@
}

EOF
)

SCRIPT_RUN_COMMON_PRE=$(cat << EOF
#!/bin/bash

. "$OVPN_HELPER_DEST"

RUN_NETWORK_NAMESPACE
RUN_VPN
EOF
)

SCRIPT_RUN_COMMON_POST=$(cat << EOF
CLOSE_VPN
CLOSE_NETWORK_NAMESPACE

EOF
)

SCRIPT_RESET_VPN=$(cat << EOF
#!/bin/bash

. "$OVPN_HELPER_DEST"

CLOSE_VPN
CLOSE_NETWORK_NAMESPACE

EOF
)

SCRIPT_RUN_ACT=$(cat << EOF
$SCRIPT_RUN_COMMON_PRE

RUN_COMMAND "\$(which bash)" "$HOME/bin/ffxiv-run-act.sh"

$SCRIPT_RUN_COMMON_POST
EOF
)

SCRIPT_RUN_GAME=$(cat << EOF
$SCRIPT_RUN_COMMON_PRE

RUN_COMMAND "\$(which bash)" "$HOME/bin/ffxiv-run-game.sh"

$SCRIPT_RUN_COMMON_POST
EOF
)

SCRIPT_RUN_BOTH=$(cat << EOF
$SCRIPT_RUN_COMMON_PRE

RUN_COMMAND "\$(which bash)" "$HOME/bin/ffxiv-run-both.sh"

$SCRIPT_RUN_COMMON_POST
EOF
)

SCRIPT_RUN_OTHER=$(cat << EOF
$SCRIPT_RUN_COMMON_PRE

RUN_COMMAND \$@

$SCRIPT_RUN_COMMON_POST
EOF
)

echo "Scripts built. Writing to $HOME/bin..."

echo "Writing $OVPN_HELPER_CONFIG_DEST"
echo "$SCRIPT_HELPER_CONFIG" > "$OVPN_HELPER_CONFIG_DEST"

echo "Writing $OVPN_HELPER_DEST"
echo "$SCRIPT_HELPER" > "$OVPN_HELPER_DEST"

echo "Writing $OVPN_CONFIG_DEST"
echo "$OVPN_CONFIG_CONTENTS" > "$OVPN_CONFIG_DEST"

if [[ "$UP_FILE_CONTENTS" != "" ]]; then
    echo "Writing $OVPN_UP_DEST and making it user accessible only"
    echo "$UP_FILE_CONTENTS" > "$OVPN_UP_DEST"
    chmod 0600 "$OVPN_UP_DEST"
fi

echo "Writing $SCRIPT_RUN_ACT_DEST"
echo "$SCRIPT_RUN_ACT" > "$SCRIPT_RUN_ACT_DEST"
chmod +x "$SCRIPT_RUN_ACT_DEST"

echo "Writing $SCRIPT_RUN_GAME_DEST"
echo "$SCRIPT_RUN_GAME" > "$SCRIPT_RUN_GAME_DEST"
chmod +x "$SCRIPT_RUN_GAME_DEST"

echo "Writing $SCRIPT_RUN_BOTH_DEST"
echo "$SCRIPT_RUN_BOTH" > "$SCRIPT_RUN_BOTH_DEST"
chmod +x "$SCRIPT_RUN_BOTH_DEST"

echo "Writing $SCRIPT_RUN_OTHER_DEST"
echo "$SCRIPT_RUN_OTHER" > "$SCRIPT_RUN_OTHER_DEST"
chmod +x "$SCRIPT_RUN_OTHER_DEST"

echo "Writing $SCRIPT_RESET_VPN_DEST"
echo "$SCRIPT_RESET_VPN" > "$SCRIPT_RESET_VPN_DEST"
chmod +x "$SCRIPT_RESET_VPN_DEST"

echo "Scripts written. Run $HOME/bin/ffxiv-vpn-run-* to run within the VPN scope"