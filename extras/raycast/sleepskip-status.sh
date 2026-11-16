#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title SleepSkip Status
# @raycast.mode inline
# @raycast.refreshTime 1h
# @raycast.packageName SleepSkip

if ! command -v sleepskip >/dev/null 2>&1; then
  echo "sleepskip CLI not installed"
  exit 1
fi

sleepskip status
