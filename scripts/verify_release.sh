#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_metadata.sh"
sleepskip_release_metadata '1.6.0-beta.1' '42'
[[ "$SLEEPSKIP_MARKETING_VERSION" == 1.6.0 && "$SLEEPSKIP_BUILD_NUMBER" == 42 && "$SLEEPSKIP_PRERELEASE" == true ]]
sleepskip_release_metadata '1.10.0' '43'
[[ "$SLEEPSKIP_MARKETING_VERSION" == 1.10.0 && "$SLEEPSKIP_BUILD_NUMBER" == 43 && "$SLEEPSKIP_PRERELEASE" == false ]]
for version in '' '1.6' 'v1.6.0' '1.6.0/' '1.6.0-beta..1' '1.6.0;echo invalid'; do
  if sleepskip_release_metadata "$version" 44 2>/dev/null; then echo "Accepted invalid release version" >&2; exit 1; fi
done
for build in '' '0' '-1' '42-beta1' '1.2'; do
  if sleepskip_release_metadata '1.6.0' "$build" 2>/dev/null; then echo "Accepted invalid build number" >&2; exit 1; fi
done
echo 'RELEASE METADATA CHECKS PASSED'
