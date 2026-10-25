#!/bin/sh
# Installs Meki for this user, in ~/Applications (release spec 2026-10-21 §10). No sudo.
#
#   curl -fsSL https://get.mekiphoto.com/install.sh | sh                        latest Regular release
#   curl -fsSL https://get.mekiphoto.com/install.sh | sh -s -- --beta           latest Beta (Beta includes Regular)
#   curl -fsSL https://get.mekiphoto.com/install.sh | sh -s -- --version 1.2.0  a specific release
#   … --force       reinstall even when that version is already installed
#   … --no-launch   don't open Meki afterwards
#
# Before anything is replaced it checks the download's SHA-256, that Meki is signed by its developer (Team ID
# K66532Q4ZD, bundle id com.mekiphoto.app) and that Gatekeeper accepts it. Running it again is safe: an installed copy
# of the same version is left alone. The whole script is functions; the last line runs `main`, so a download cut
# short runs nothing.
#
# Overrides (tests and mirrors; a release is accepted only when it passes the checks above):
#   MEKI_INSTALL_BASE   where install/<channel>.json lives (default: the releases repository's gh-pages branch)
#   MEKI_RELEASES_BASE  where release assets live (default: the releases repository's GitHub Releases)
#   MEKI_INSTALL_LIB=1  define the functions only (tools/release/test/install.test.sh)
set -eu

MEKI_TEAM_ID="K66532Q4ZD"
MEKI_BUNDLE_ID="com.mekiphoto.app"
MEKI_MIN_MACOS=26
MEKI_INSTALL_BASE="${MEKI_INSTALL_BASE:-https://raw.githubusercontent.com/smo-key/meki-releases/gh-pages}"
MEKI_RELEASES_BASE="${MEKI_RELEASES_BASE:-https://github.com/smo-key/meki-releases/releases/download}"

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }
die() { err "$1"; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
Installs Meki in ~/Applications for your user.

  sh install.sh [--beta] [--version X.Y.Z[-beta.N]] [--force] [--no-launch]

  --beta       the latest Beta release (Meki then offers Beta updates)
  --version V  a specific release
  --force      reinstall even when that version is already installed
  --no-launch  don't open Meki afterwards
EOF
}

is_version() {
  printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$'
}

parse_args() {
  CHANNEL=regular
  WANT_VERSION=""
  FORCE=0
  LAUNCH=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --beta) CHANNEL=beta ;;
      --version)
        [ "$#" -ge 2 ] || die "--version needs a version, e.g. --version 1.2.0" 2
        WANT_VERSION="$2"
        shift
        ;;
      --version=*) WANT_VERSION="${1#--version=}" ;;
      --force) FORCE=1 ;;
      --no-launch) LAUNCH=0 ;;
      -h | --help) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
    shift
  done
  if [ -n "$WANT_VERSION" ]; then
    WANT_VERSION="${WANT_VERSION#v}"
    # shellcheck disable=SC1111 # curly quotes are the copy, not shell quoting
    is_version "$WANT_VERSION" || die "“${WANT_VERSION}” is not a Meki version (X.Y.Z or X.Y.Z-beta.N)." 2
    case "$WANT_VERSION" in *-beta.*) CHANNEL=beta ;; esac
  fi
}

check_user() {
  [ "$(id -u)" != 0 ] || die "Run this as yourself, not as root: Meki installs in your own ~/Applications, without sudo."
}

check_mac() {
  [ "$(uname -s)" = Darwin ] || die "Meki needs a Mac with Apple silicon."
  if [ "$(uname -m)" != arm64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]; then
    die "Meki needs a Mac with Apple silicon."
  fi
  os="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  major="${os%%.*}"
  case "$major" in '' | *[!0-9]*) major=0 ;; esac
  [ "$major" -ge "$MEKI_MIN_MACOS" ] || die "Meki needs macOS $MEKI_MIN_MACOS or later. This Mac has $os."
}

fetch() { # url file
  curl -fsSL --retry 3 -o "$2" "$1"
}

json_get() { # file key → the value, or nothing
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

plist_get() { # bundle key → the value, or nothing
  plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# Sets REL_VERSION, REL_URL, REL_SHA256 and REL_SIZE (empty when unknown) for the release to install.
resolve_release() {
  if [ -n "$WANT_VERSION" ]; then
    asset="Meki_${WANT_VERSION}_aarch64.app.tar.gz"
    base="$MEKI_RELEASES_BASE/v$WANT_VERSION"
    fetch "$base/SHA256SUMS" "$WORK/SHA256SUMS" || die "Meki $WANT_VERSION isn't a published release (or the release list can't be reached)."
    REL_VERSION="$WANT_VERSION"
    REL_URL="$base/$asset"
    REL_SHA256="$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1; exit }' "$WORK/SHA256SUMS")"
    REL_SIZE=""
  else
    manifest="$MEKI_INSTALL_BASE/install/$CHANNEL.json"
    fetch "$manifest" "$WORK/manifest.json" || die "Couldn't reach the list of Meki releases ($manifest). Check your connection and try again."
    REL_VERSION="$(json_get "$WORK/manifest.json" version)"
    REL_URL="$(json_get "$WORK/manifest.json" url)"
    REL_SHA256="$(json_get "$WORK/manifest.json" sha256)"
    REL_SIZE="$(json_get "$WORK/manifest.json" size)"
  fi
  if ! is_version "$REL_VERSION" || [ -z "$REL_URL" ]; then
    die "The list of Meki releases is unreadable. Nothing was changed."
  fi
  printf '%s\n' "$REL_SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "Meki $REL_VERSION has no checksum to check the download against. Nothing was changed."
  case "$REL_SIZE" in *[!0-9]*) REL_SIZE="" ;; esac
}

bundle_version() { # bundle → its Meki version (MekiVersion when the plist keeps the prerelease there, spike S1)
  v="$(plist_get "$1" MekiVersion)"
  [ -n "$v" ] || v="$(plist_get "$1" CFBundleShortVersionString)"
  printf '%s\n' "$v"
}

# Signed by Meki's developer and accepted by Gatekeeper.
verify_signature() { # bundle
  codesign --verify --deep --strict "$1" >/dev/null 2>&1 || return 1
  info="$(codesign -dv "$1" 2>&1)" || return 1
  printf '%s\n' "$info" | grep -qx "TeamIdentifier=$MEKI_TEAM_ID" || return 1
  printf '%s\n' "$info" | grep -qx "Identifier=$MEKI_BUNDLE_ID" || return 1
  spctl --assess --type execute "$1" >/dev/null 2>&1 || return 1
}

already_installed() {
  [ -d "$DEST" ] && [ "$(bundle_version "$DEST")" = "$REL_VERSION" ] && verify_signature "$DEST"
}

download() {
  if [ -n "$REL_SIZE" ]; then
    say "Downloading Meki $REL_VERSION ($((REL_SIZE / 1000000)) MB)…"
  else
    say "Downloading Meki ${REL_VERSION}…"
  fi
  fetch "$REL_URL" "$WORK/Meki.app.tar.gz" || die "The download failed ($REL_URL). Nothing was changed."
  if [ -n "$REL_SIZE" ]; then
    got="$(wc -c <"$WORK/Meki.app.tar.gz" | tr -d ' ')"
    [ "$got" = "$REL_SIZE" ] || die "The download did not match its checksum. Nothing was changed."
  fi
  sum="$(shasum -a 256 "$WORK/Meki.app.tar.gz" | awk '{ print $1 }')"
  [ "$sum" = "$REL_SHA256" ] || die "The download did not match its checksum. Nothing was changed."
}

unpack() {
  mkdir "$WORK/unpacked"
  tar -xzf "$WORK/Meki.app.tar.gz" -C "$WORK/unpacked" 2>/dev/null || die "The download could not be unpacked. Nothing was changed."
  NEW_APP="$WORK/unpacked/Meki.app"
  [ -d "$NEW_APP" ] || die "The download has no Meki.app inside. Nothing was changed."
}

clear_quarantine() { # curl sets none; a proxy tool or a managed Mac might
  if xattr -p com.apple.quarantine "$NEW_APP" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$NEW_APP"
  fi
}

meki_running() {
  [ "$(osascript -e "application id \"$MEKI_BUNDLE_ID\" is running" 2>/dev/null || echo false)" = true ]
}

quit_meki() {
  say "Meki is open. Quitting it so it can be replaced — running tasks continue when it opens again."
  osascript -e "tell application id \"$MEKI_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  n=0
  while meki_running; do
    n=$((n + 1))
    [ "$n" -le 60 ] || die "Quit Meki, then run this again."
    sleep 1
  done
}

mv_bundle() { mv "$1" "$2"; }

# New bundle → ~/Applications/.Meki.app.new; the old one → .Meki.app.old; the new one → Meki.app; the old one is
# deleted. A failure (or an interrupt, see cleanup) between the moves puts the old bundle back.
swap_in() { # new bundle
  apps="$(dirname "$DEST")"
  staged="$apps/.Meki.app.new"
  OLD="$apps/.Meki.app.old"
  mkdir -p "$apps"
  rm -rf "$staged" "$OLD"
  mv_bundle "$1" "$staged" || { rm -rf "$staged"; die "Couldn't copy Meki into ~/Applications. Nothing was changed."; }
  if [ -e "$DEST" ]; then
    mv_bundle "$DEST" "$OLD" || { rm -rf "$staged"; die "Couldn't move the installed Meki aside. Nothing was changed."; }
  fi
  SWAPPING=1
  if ! mv_bundle "$staged" "$DEST"; then
    restore_old
    rm -rf "$staged"
    die "Couldn't put Meki in ~/Applications. The previous copy is back in place."
  fi
  SWAPPING=0
  rm -rf "$OLD"
}

restore_old() {
  if [ -n "${OLD:-}" ] && [ -e "$OLD" ] && [ ! -e "$DEST" ]; then
    mv_bundle "$OLD" "$DEST" || true
  fi
}

system_copy_exists() { [ -d /Applications/Meki.app ]; }

launch() {
  [ "$LAUNCH" = 1 ] || return 0
  open "$DEST" || err "Couldn't open Meki. Open it from ~/Applications."
}

cleanup() {
  [ "${SWAPPING:-0}" = 0 ] || restore_old
  [ -z "${WORK:-}" ] || rm -rf "$WORK"
}

main() {
  parse_args "$@"
  check_user
  check_mac
  DEST="$HOME/Applications/Meki.app"
  SWAPPING=0
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/meki-install.XXXXXX")"
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  resolve_release
  if [ "$FORCE" = 0 ] && already_installed; then
    say "Meki $REL_VERSION is already installed."
    launch
    return 0
  fi
  if system_copy_exists; then
    say "Meki is also in /Applications. Remove that copy so macOS opens the one in ~/Applications."
  fi
  download
  unpack
  [ "$(bundle_version "$NEW_APP")" = "$REL_VERSION" ] || die "The download is not Meki $REL_VERSION. Nothing was changed."
  verify_signature "$NEW_APP" || die "This copy of Meki is not signed by Meki's developer. Nothing was changed."
  clear_quarantine
  if meki_running; then quit_meki; fi
  swap_in "$NEW_APP"
  launch
  say "Installed Meki $REL_VERSION in ~/Applications."
  if [ "$CHANNEL" = beta ]; then say "Meki will offer Beta updates. Change this in Settings › About."; fi
}

if [ "${MEKI_INSTALL_LIB:-}" != 1 ]; then main "$@"; fi
