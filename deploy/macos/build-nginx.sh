#!/bin/bash
# Build the nginx that deploy/macos/install.sh puts in front of the node, into
# bin/nginx (with bin/nginx.mime.types). Run as yourself, no sudo.
#
# Why from source: Homebrew on an Intel Mac with macOS 26 is unsupported (Tier 3)
# and needs changes to a shared /usr/local before it installs anything. A pinned,
# checksummed build depends on nothing but the compiler.
#
# The tarballs were checked against their PGP signatures before their SHA-256 was
# pinned here: nginx by Sergey Kandaurov (key D6786CE3…9AF75C0A, nginx.org/keys/
# pluknet.key), PCRE2 by Nicholas Wilson (BACF71F1…FB63B406). To upgrade, verify
# the new release the same way, then change the version and the checksum together.
set -euo pipefail

NGINX_VERSION=1.30.6
NGINX_SHA256=3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8
PCRE2_VERSION=10.49
PCRE2_SHA256=929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae

cd "$(dirname "$0")/../.."
out=$PWD/bin
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fetch() { # URL SHA256
  local file
  file="$work/$(basename "$1")"
  curl -sSfL -o "$file" "$1"
  echo "$2  $file" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $1" >&2; exit 1; }
  tar -xzf "$file" -C "$work"
}
fetch "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" "$NGINX_SHA256"
fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" "$PCRE2_SHA256"

cd "$work/nginx-$NGINX_VERSION"
# TLS ends at Cloudflare, so no OpenSSL. realip takes the client address from
# CF-Connecting-IP. PCRE2 is built in statically (return and map need it); zlib
# comes from the macOS SDK. The prefix only sets defaults: the LaunchDaemon
# passes -p and -c.
./configure --prefix=/opt/eidchain/nginx \
  --with-http_realip_module \
  --with-pcre="$work/pcre2-$PCRE2_VERSION" \
  --without-http_ssi_module --without-http_autoindex_module --without-http_memcached_module \
  >"$work/configure.log" 2>&1 || { tail -30 "$work/configure.log" >&2; exit 1; }
make -j"$(sysctl -n hw.ncpu)" >"$work/make.log" 2>&1 || { tail -30 "$work/make.log" >&2; exit 1; }

mkdir -p "$out"
install -m 755 objs/nginx "$out/nginx"
install -m 644 conf/mime.types "$out/nginx.mime.types"
"$out/nginx" -V 2>&1 | head -1
echo "built $out/nginx"
