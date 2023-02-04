#!/bin/bash

BIN=$(basename "${0}" | sed 's/\..*//')
DIR=$(dirname $(readlink -f "${0}"))

for FILE in $(find "${DIR}" -name "[0-9]*.sh" | sort -n); do
    sudo "${FILE}"
done

