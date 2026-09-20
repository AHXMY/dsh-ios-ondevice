#!/usr/bin/env bash
# Build the guest root filesystem bundled into the DSH iOS app:
#   Alpine 3.21 (aarch64) + Node.js 22 + @deepseek-ai/dsh (+ rebuilt node-pty)
#
# Everything guest-side runs inside the iSH-ARM64 CLI emulator on macOS, so the
# result is byte-for-byte what the app boots. Output: build/root.tar.gz
#
# Usage: scripts/build-rootfs.sh [--keep-work]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ISH_SRC="${ISH_SRC:-$ROOT/ish-arm64}"
ISH_BUILD="${ISH_BUILD:-$ISH_SRC/build-arm64-release}"
WORK="${WORK:-$ROOT/build/rootfs-work}"
OUT="${OUT:-$ROOT/build/root.tar.gz}"

ALPINE_VER=3.21
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VER}.0-aarch64.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/aarch64/${ALPINE_TARBALL}"
# Pinned dsh release; bump together with package-lock.json under rootfs/staging.
DSH_VERSION="${DSH_VERSION:-0.1.0-rc.7}"
# The terminal surface, installed into the `tui` profile at build time. dsh
# removed its own terminal app (@deepseek-ai/dsh-tui) on 2026-08-04, so the
# terminal is an out-of-tree bundle; dsh-TUI is the Claude Code-style fullscreen
# one: "Claude Code-style interactive terminal UI", five runtime deps, and
# peers on dsh ^0.1.5-rc.1, so it pairs with the newest dsh rather than the pin.
# (@ccchimneyyy/dsh-tui would have been the other pick, but it ships
# `workspace:*` dependencies and no package manager can install it outside its
# own workspace -- npm fails with EUNSUPPORTEDPROTOCOL.)
DSH_TUI_PACKAGE="${DSH_TUI_PACKAGE:-@brianynwu/dsh-tui}"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# The guest node prints this warning on every start; strip it from build logs.
filter() { sed '/expose_wasm/d'; }

ish() {
    # ish <script-on-stdin>; runs /bin/sh inside the fakefs
    "$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh 2>&1 | filter
}

# Every guest phase ends by printing a token, and the host checks for it. A
# guest `exit 1` does not stop this build on its own: phase 3 once printed its
# own "error: ..." and the image was still exported as a success, so a broken
# image could ship with a green build. The token is checked instead, and the
# captured output is printed immediately afterwards so the log still carries it.
guest_phase() {
    local name="$1" token="$2" out
    out=$(ish)
    printf '%s\n' "$out"
    case "$out" in
        *"$token"*) log "  $name ok" ;;
        *) die "$name did not report success (no $token in its output)" ;;
    esac
}

[ -x "$ISH_BUILD/ish" ] || die "iSH CLI not built. Run: (cd $ISH_SRC && meson setup build-arm64-release -Dguest_arch=arm64 --buildtype=release && ninja -C build-arm64-release)"
[ -x "$ISH_BUILD/tools/fakefsify" ] || die "fakefsify not built in $ISH_BUILD/tools"
command -v npm >/dev/null || die "npm is required on the host"

mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$WORK"

log "Alpine minirootfs"
[ -f "$ALPINE_TARBALL" ] || curl -fsSL -o "$ALPINE_TARBALL" "$ALPINE_URL"

log "Create fakefs"
rm -rf fakefs
"$ISH_BUILD/tools/fakefsify" "$ALPINE_TARBALL" fakefs

log "Stage dsh node_modules on the host (linux/arm64/musl)"
rm -rf stage && mkdir stage
cp "$ROOT/rootfs/staging/package.json" stage/
# Install from the manifest with peer resolution kept ON.
#
# The whole @deepseek-ai tree is wired through peerDependencies -- nearly every
# package declares its siblings as peers, and npm's automatic peer installation
# is what actually pulls them in. --legacy-peer-deps turns that off and the tree
# comes up short (guest phase 3 died on
#   Cannot find package '@deepseek-ai/cordis-plugin-group').
#
# A lockfile cannot be used either: the out-of-tree terminal app declares peers
# on @deepseek-ai/* versions the published tree does not carry (its packages sit
# on independent version lines -- dsh-llm ships 0.0.1-rc.x while the app peers on
# ^0.1.5-rc.1), so a plain install refuses to resolve:
#   npm error Conflicting peer dependency: @deepseek-ai/dsh-llm@0.1.5-rc.2
# --force resolves it the other way: it keeps installing peers, and nests the
# conflicting version under the package that asked for it, which is exactly what
# the app needs. Whether the app truly runs against this tree is then decided by
# the `--profile tui --dump-config` check in guest phase 3 -- evidence, not a
# declaration. Whatever the looser resolution adds in size is pruned below.
( cd stage && npm install --os=linux --cpu=arm64 --libc=musl --ignore-scripts \
    --no-audit --no-fund --force 2>&1 | tail -3 )

log "Guest phase 1: packages"
guest_phase "guest phase 1" "DSH-PHASE1-OK" <<'EOF'
set -e
# DNS baked into the shipped image. 8.8.8.8 / 1.1.1.1 are commonly blackholed
# on mainland-China networks, and a guest whose DNS never answers makes every
# model request fail with "DeepSeek API request ... failed" while the app UI
# itself looks fine. Put reachable resolvers first; keep 1.1.1.1 last.
echo "nameserver 223.5.5.5" > /etc/resolv.conf
echo "nameserver 119.29.29.29" >> /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
apk update >/dev/null
apk add --no-progress nodejs npm nodejs-dev python3 make g++ bash git curl openssh-client ca-certificates 2>&1 | tail -1
node -v; npm -v
echo DSH-PHASE1-OK
EOF

log "Guest phase 2: install node_modules + polyfills + overlay"
# Assemble one payload tree rooted at / (staged node_modules, the iSH
# node polyfills, our overlay) and stream it into the guest in a single pass.
rm -rf payload && mkdir -p payload/usr/local/lib payload/lib
mv stage/node_modules payload/usr/local/lib/node_modules
# Only the musl/arm64 pair of sharp's binaries can load in this guest. npm keeps
# every platform's optional build it resolved -- and when the staging step falls
# back to a bare `npm install` (no lockfile to pin the set) that is all 25 of
# them, tens of MB of win32 and wasm payloads that shipped and doubled the image
# to 211 MB. Prune by rule rather than by naming the three that happened to be
# obvious: whatever is not the pair sharp actually selects goes.  Also strip
# macOS AppleDouble files before they become tens of thousands of fakefs entries.
rm -rf payload/usr/local/lib/node_modules/@img/sharp-linux-arm64 \
       payload/usr/local/lib/node_modules/@img/sharp-libvips-linux-arm64 \
       payload/usr/local/lib/node_modules/@img/sharp-wasm32
if [ -d payload/usr/local/lib/node_modules/@img ]; then
    find payload/usr/local/lib/node_modules/@img -mindepth 1 -maxdepth 1 -type d \
        ! -name 'sharp-linuxmusl-arm64' \
        ! -name 'sharp-libvips-linuxmusl-arm64' \
        -exec rm -rf {} + 2>/dev/null || true
    echo "  sharp variants kept: $(ls payload/usr/local/lib/node_modules/@img 2>/dev/null | tr '\n' ' ')"
fi
cp "$ISH_SRC"/app/RootfsPatch.bundle/files/lib/*.js payload/lib/
# Record the overlay version so the app does not re-apply (and downgrade) the
# same RootfsPatch files on first launch.
overlay_ver=$(/usr/libexec/PlistBuddy -c 'Print :version' "$ISH_SRC/app/RootfsPatch.bundle/manifest.plist")
mkdir -p payload/ish && printf '%s\n' "$overlay_ver" > payload/ish/overlay-version
cp -R "$ROOT/rootfs/overlay/." payload/
find payload -name '._*' -delete
# BSD tar otherwise serialises extended attributes as AppleDouble `._*` files
# when this payload is unpacked by the Linux guest.
COPYFILE_DISABLE=1 tar czf payload.tgz -C payload .
"$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c 'cd / && tar xzf -' < payload.tgz 2>&1 | filter
# Phase 2 takes its stdin from the payload tarball rather than a heredoc, so it
# cannot carry a token. The fakefs data directory mirrors the guest, so the
# unpacked result is checked directly on the host instead.
[ -f "$WORK/fakefs/data/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" ] ||
    die "guest phase 2 did not unpack the payload into the fakefs"

log "Guest phase 3: node-pty rebuild for musl, profile, cleanup"
guest_phase "guest phase 3" "DSH-PHASE3-OK" <<EOF
set -e
export HOME=/root
chmod +x /usr/local/bin/* /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js
ln -sf ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh
cd /usr/local/lib/node_modules/node-pty
rm -rf build prebuilds
npx --yes node-gyp rebuild --nodedir=/usr 2>&1 | tail -1
test -f build/Release/pty.node
# Pre-create the web profile so first launch on device does no scaffolding,
# then drop in our patch layer.
node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --dump-config >/dev/null
install -m 0644 /usr/local/share/dsh/cordis.patch.yml /root/.dsh/profiles/web/cordis.patch.yml
# The interactive terminal surface. dsh ships no terminal app of its own -- the
# repository removed @deepseek-ai/dsh-tui on 2026-08-04 -- so the terminal is an
# out-of-tree profile bundle, installed into the guest's global node_modules by
# the staging step above.
#
# The profile directory is written here rather than created with
# `dsh plugin --profile tui add`: that forwards to pnpm, which means installing
# the package a second time inside the emulator over the guest's network. A
# first attempt at it sat on this step for 37 minutes (against a 5.6-minute
# baseline for the whole rootfs build) and had to be cancelled. Nothing about
# the profile needs a package manager -- `dsh plugin` produces exactly this
# package.json plus the bundle in the profile's node_modules, and dsh's own
# bootstrap generates the resolution shims for whatever the bundles name.
mkdir -p /root/.dsh/profiles/tui
cat > /root/.dsh/profiles/tui/package.json <<'TUI_PROFILE_EOF'
{
  "name": "dsh-profile-tui",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@brianynwu/dsh-tui"
      ],
      "patchReload": "startup"
    }
  }
}
TUI_PROFILE_EOF
install -m 0644 /usr/local/share/dsh/tui.patch.yml /root/.dsh/profiles/tui/cordis.patch.yml
# Compose it once here so a broken bundle fails the build, not first launch on a
# device with no way to install anything. The result is collected and reported
# as the phase token at the end: an `exit 1` here would not stop the build.
tui_ok=1
node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
    --profile tui --dump-config >/dev/null 2>&1 || {
    echo "error: the tui profile does not compose"; tui_ok=0
}
test -d "/usr/local/lib/node_modules/$DSH_TUI_PACKAGE" || {
    echo "error: the tui bundle was not staged into the guest"; tui_ok=0
}
echo "tui profile: bundles=\$(node -e 'try{console.log(require("/root/.dsh/profiles/tui/package.json").dsh.profile.bundles.join(","))}catch(e){console.log("?")}')  ok=\$tui_ok"
# Home-level layer: applies to every profile (see rootfs/overlay/.../home.patch.yml).
install -m 0644 /usr/local/share/dsh/home.patch.yml /root/.dsh/cordis.patch.yml
mkdir -p /root/workspace
# Slim down: build tooling is only needed for node-pty.
apk del --no-progress nodejs-dev python3 make g++ >/dev/null 2>&1 || true
apk add --no-progress libstdc++ libgcc >/dev/null
rm -rf /root/.npm /root/.cache /var/cache/apk/* /tmp/* /usr/local/lib/node_modules/node-pty/build/Release/obj.target
echo "guest node: \$(node -v), dsh: \$(dsh --version)"
du -sh /usr/local/lib/node_modules /usr/lib/node_modules 2>/dev/null
[ "\$tui_ok" = "1" ] && echo DSH-PHASE3-OK
EOF

log "Export root.tar.gz"
rm -f "$OUT"
"$ISH_BUILD/tools/unfakefsify" fakefs "$OUT"
ls -lh "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"

if [ "${1:-}" != "--keep-work" ]; then
    rm -rf stage payload payload.tgz
fi
log "Done: $OUT"
