#!/bin/sh
logger -t watchcat_restart.sh running /sbin/ifup for $1
uci show network | sed -n "s/network.\(\S*\).device='$1'/\1/p" | xargs /sbin/ifup
