#!/bin/bash

if [[ -e "/etc/gentoo-release" ]]; then
    . "$(dirname "${BASH_SOURCE[0]}")/gentoo.sh"
    return
fi

. "$(dirname "$0")/default.sh"