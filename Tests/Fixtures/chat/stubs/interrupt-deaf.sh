#!/bin/bash
# Takes the user line and then ignores everything, including the interrupt and SIGTERM, until it is killed.
trap '' TERM HUP
read -r user
for _ in $(seq 900); do sleep 1; done   # gone after 15 min even when a failed or crashed test never stops it
