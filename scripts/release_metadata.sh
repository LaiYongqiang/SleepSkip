#!/usr/bin/env bash
# Shared validation for local packaging and CI. Sourcing has no side effects.
sleepskip_release_metadata() {
  local release_version="${1:-}"
  local build_number="${2:-}"
  if [[ ! "$release_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z]+)([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "Invalid release version: expected X.Y.Z or X.Y.Z-beta.N" >&2
    return 2
  fi
  SLEEPSKIP_MARKETING_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid build number: expected a positive integer" >&2
    return 2
  fi
  SLEEPSKIP_BUILD_NUMBER="$build_number"
  SLEEPSKIP_PRERELEASE=false
  if [[ "$release_version" == *-* ]]; then SLEEPSKIP_PRERELEASE=true; fi
}
