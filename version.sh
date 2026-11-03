#!/bin/bash
# Single source of truth for build metadata. Sourced by build.sh and install.sh.
#
# This fork ships no releases, so there is no feed URL, no Sparkle signing key
# and no repo slug here any more -- the scripts that needed them are gone.

APP_NAME="Touchdown"
BUNDLE_ID="com.bencolson.touchdown"

# Marketing version (CFBundleShortVersionString). Bump by hand when the fork
# gains or loses something a user would notice.
#
# 1.6.0 is the first version that is this fork's rather than inherited: 1.5.0
# was upstream's, and claiming it after removing the updater, adding an icon
# and an About panel and fixing five bugs made two very different builds
# indistinguishable by version.
#
# This namespace now overlaps upstream's -- if they ever ship a 1.6.0 it will
# not be this one. That is tolerable because nothing compares versions
# mechanically any more (no appcast, no updater); the build number and source
# commit that build.sh stamps are what actually identify a build.
VERSION="1.6.0"
