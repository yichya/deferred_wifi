#!/bin/sh
logger -t killall_usr2_odhcp6c.sh invoked
killall -USR2 odhcp6c
