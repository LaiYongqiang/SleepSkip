#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Toggle SleepSkip
# @raycast.mode silent
# @raycast.packageName SleepSkip

if ! command -v sleepskip >/dev/null 2>&1; then
  echo "sleepskip CLI not installed"
  exit 1
fi

sleepskip toggle && sleepskip status
