#!/bin/bash
# Join a chain from a Mac as a validating node of your own: fetch Go if needed,
# build, pull the chain, make a node key, write the registration record for your
# eID card, and run the node in the foreground. Run as yourself, no sudo.
#
#   curl -sSfL https://raw.githubusercontent.com/stepanic/eidchain/main/deploy/macos/join.sh | bash
#
# Then open SERVER/validator.html, paste the printed record and sign it with your
# card. Each node gets its own key: never copy one to a second node, or both sign
# at once. All the keys you register count as one person.
#
# Settings (environment): SERVER, GENESIS_HASH, DATA (default ~/eidchain-data),
# REPO (default ~/git/stepanic/eidchain), LISTEN (default 127.0.0.1:8097). The
# defaults join eidchain.domovina.ai.
set -euo pipefail

SERVER=${SERVER:-https://eidchain.domovina.ai/chain}
GENESIS_HASH=${GENESIS_HASH:-70659df25175f4f0da5fe0800393c5a0176ca0acbef7a9f3d3cb8cf7763beec8}
DATA=${DATA:-$HOME/eidchain-data}
REPO=${REPO:-$HOME/git/stepanic/eidchain}
# Loopback, because the node has no limits of its own and must not face the
# network directly (deploy/macos/install.sh puts nginx and a tunnel in front).
# Not :8080, the node's default: on a desktop Mac that port is often taken.
LISTEN=${LISTEN:-127.0.0.1:8097}

# Fail now rather than after the download and build.
if lsof -nP -iTCP:"${LISTEN##*:}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port ${LISTEN##*:} is taken; set LISTEN=127.0.0.1:<free port>" >&2
  exit 1
fi

# Go from go.dev, pinned and checksummed: the system Go is often too old, and
# Homebrew is not always usable.
GO_VERSION=1.27.3
case $(uname -m) in
  arm64) GO_ARCH=arm64 GO_SHA256=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2 ;;
  x86_64) GO_ARCH=amd64 GO_SHA256=b6f8e931e4ab497fcde6da8ae4499a58f9d258e55c8a80824a516eae5950a750 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
GO=$HOME/sdk/go$GO_VERSION/bin/go
if [[ ! -x $GO ]]; then
  tgz=$(mktemp)
  curl -sSfL -o "$tgz" "https://go.dev/dl/go$GO_VERSION.darwin-$GO_ARCH.tar.gz"
  echo "$GO_SHA256  $tgz" | shasum -a 256 -c - >/dev/null || { echo "Go download: checksum mismatch" >&2; exit 1; }
  mkdir -p "$HOME/sdk/go$GO_VERSION"
  tar -xzf "$tgz" -C "$HOME/sdk/go$GO_VERSION" --strip-components=1
  rm -f "$tgz"
fi

if [[ -d $REPO/.git ]]; then
  git -C "$REPO" pull -q --ff-only
else
  mkdir -p "$(dirname "$REPO")"
  git clone -q https://github.com/stepanic/eidchain "$REPO"
fi
cd "$REPO"
"$GO" build -o bin/eidchain ./cmd/eidchain

[[ -f $DATA/genesis.json ]] || bin/eidchain pull --data "$DATA" --genesis-hash "$GENESIS_HASH" "$SERVER"
[[ -f $DATA/keys/validator.key ]] || bin/eidchain keygen --data "$DATA"
bin/eidchain validator request --data "$DATA" --server "$SERVER" --out "$DATA/registration.json"
echo
echo "Running the node (Ctrl-C stops it). Its key signs blocks once the record above is on the chain."
exec bin/eidchain node --data "$DATA" --listen "$LISTEN"
