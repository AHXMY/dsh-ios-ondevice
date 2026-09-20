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
# Its scope directory, for the resolution redirects guest phase 3 writes.
TUI_SCOPE="${DSH_TUI_PACKAGE%%/*}"

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
#
# The emulator's own exit status is captured too. `set -o pipefail` means a
# non-zero emulator status would otherwise abort the build from *inside* the
# command substitution -- reported at the call site, with the phase output never
# printed -- so phase 3 died once as a bare "did not report success" next to a
# completely empty log. Now the status is reported and an empty capture says so.
guest_phase() {
    local name="$1" token="$2" out rc=0
    set +e
    out=$(ish); rc=$?
    set -e
    if [ -z "$out" ]; then
        printf '\033[1;33mWARN\033[0m %s produced no output at all (emulator exit %s)\n' "$name" "$rc"
    else
        printf '%s\n' "$out"
    fi
    case "$out" in
        *"$token"*) log "  $name ok" ;;
        *) die "$name did not report success (no $token in its output; emulator exit $rc)" ;;
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
    # Only the platform binaries are pruned. @img also holds plain-JavaScript
    # packages that the platform builds depend on -- @img/colour is imported by
    # sharp/dist/colour.mjs -- and deleting those took the whole tree down on the
    # device with "Cannot find package '@img/colour'". Match sharp's own binary
    # naming and leave everything else alone.
    find payload/usr/local/lib/node_modules/@img -mindepth 1 -maxdepth 1 \
        \( -name 'sharp-linux*' -o -name 'sharp-darwin*' -o -name 'sharp-win32*' \
           -o -name 'sharp-freebsd*' -o -name 'sharp-webcontainers*' -o -name 'sharp-wasm32' \
           -o -name 'sharp-libvips-linux*' -o -name 'sharp-libvips-darwin*' \) \
        -exec rm -rf {} + 2>/dev/null || true
    echo "  @img kept: $(ls payload/usr/local/lib/node_modules/@img 2>/dev/null | tr '\n' ' ')"
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
# First line of the body on purpose: when a phase dies silently, an empty capture
# cannot tell "the shell never started" from "the output went missing". This
# marker settles it, and each later stage announces itself in the same way.
echo "step: entry"
export HOME=/root
chmod +x /usr/local/bin/* /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js || echo "warn: chmod on /usr/local/bin failed"
ln -sf ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh || echo "warn: the dsh launcher symlink could not be written"
cd /usr/local/lib/node_modules/node-pty
rm -rf build prebuilds
echo "step: node-pty"
npx --yes node-gyp rebuild --nodedir=/usr 2>&1 | tail -1
test -f build/Release/pty.node || { echo "error: node-pty did not build pty.node"; exit 1; }
# Pre-create the web profile so first launch on device does no scaffolding,
# then drop in our patch layer. Non-fatal on purpose: this app boots the tui
# profile, and a dsh release that scaffolds its web profile differently must not
# take the terminal down with it.
echo "step: web-profile"
if node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --dump-config >/dev/null; then
    install -m 0644 /usr/local/share/dsh/cordis.patch.yml /root/.dsh/profiles/web/cordis.patch.yml
else
    echo "warn: the web profile does not compose on this dsh release; the tui profile is unaffected"
fi
# The interactive terminal surface. dsh ships no terminal app of its own -- the
# repository removed @deepseek-ai/dsh-tui on 2026-08-04 -- so the terminal is an
# out-of-tree profile bundle, installed into the guest's global node_modules by
# the staging step above.
#
# The profile directory is written here rather than created with
# \`dsh plugin --profile tui add\`: that forwards to pnpm, which means installing
# the package a second time inside the emulator over the guest's network. A
# first attempt at it sat on this step for 37 minutes (against a 5.6-minute
# baseline for the whole rootfs build) and had to be cancelled. Nothing about
# the profile needs a package manager -- \`dsh plugin\` produces exactly this
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
# dsh's profile bootstrap writes resolution redirects for a bundle's dependency
# closure but not for the bundle itself, so the terminal app cannot be resolved
# from its own profile. On the device the whole tree died with:
#   Cannot find package '@brianynwu/dsh-tui' imported from /root/.dsh/profiles/tui/
# The chain it builds for everything else is
#   <profile>/node_modules/<pkg>
#     -> <profile>/.dsh-module-fallback/node_modules/<pkg>
#       -> /usr/local/lib/node_modules/<pkg>
# so the missing pair is written here, in the same shape.
mkdir -p "/root/.dsh/profiles/tui/node_modules/$TUI_SCOPE" \
         "/root/.dsh/profiles/tui/.dsh-module-fallback/node_modules/$TUI_SCOPE"
printf '%s\n' "/root/.dsh/profiles/tui/.dsh-module-fallback/node_modules/$DSH_TUI_PACKAGE" \
    > "/root/.dsh/profiles/tui/node_modules/$DSH_TUI_PACKAGE"
printf '%s\n' "/usr/local/lib/node_modules/$DSH_TUI_PACKAGE" \
    > "/root/.dsh/profiles/tui/.dsh-module-fallback/node_modules/$DSH_TUI_PACKAGE"
# Compose it, then actually boot it.
#
# --dump-config only composes the configuration; it does not import a single
# module, so it reported success on a tree that could not load at all on the
# device. Booting with stdin at /dev/null makes the loader import every plugin
# and then lets the terminal app exit on its own, which is the check that would
# have caught both failures. The result is reported as the phase token at the
# end: an \`exit 1\` here would not stop the build on its own.
# Progress markers: when this phase fails, the captured output is all the log
# gets, and a phase that dies mid-way used to show nothing at all. Each step
# announces itself so the next failure names itself instead of needing a rerun.
echo "step: tui-compose"
tui_ok=1
node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
    --profile tui --dump-config >/dev/null 2>&1 || {
    echo "error: the tui profile does not compose"; tui_ok=0
}
test -d "/usr/local/lib/node_modules/$DSH_TUI_PACKAGE" || {
    echo "error: the tui bundle was not staged into the guest"; tui_ok=0
}
echo "step: tui-boot"
node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
    --profile tui </dev/null >/dev/null 2>/tmp/tui-boot.err || true
if grep -qE "plugin tree failed to load|ERR_MODULE_NOT_FOUND|Cannot find package" /tmp/tui-boot.err; then
    echo "error: the tui profile loaded but its plugin tree could not be imported:"
    grep -E "Cannot find package|failed to import loader entry" /tmp/tui-boot.err | head -n 6
    tui_ok=0
fi
# A failed boot must leave evidence behind. The first version of this check only
# printed for those three patterns and then deleted the file, so any other way of
# failing produced a bare "did not report success" with nothing to read.
if [ "\$tui_ok" != "1" ]; then
    echo "--- tui boot stderr (tail) ---"
    tail -n 20 /tmp/tui-boot.err
    echo "--- end tui boot stderr ---"
fi
rm -f /tmp/tui-boot.err
echo "tui profile: bundles=\$(node -e 'try{console.log(require("/root/.dsh/profiles/tui/package.json").dsh.profile.bundles.join(","))}catch(e){console.log("?")}')  ok=\$tui_ok"
# Home-level layer: applies to every profile (see rootfs/overlay/.../home.patch.yml).
install -m 0644 /usr/local/share/dsh/home.patch.yml /root/.dsh/cordis.patch.yml
mkdir -p /root/workspace
# Slim down: build tooling is only needed for node-pty.
echo "step: slim"
apk del --no-progress nodejs-dev python3 make g++ >/dev/null 2>&1 || true
apk add --no-progress libstdc++ libgcc >/dev/null
rm -rf /root/.npm /root/.cache /var/cache/apk/* /tmp/* /usr/local/lib/node_modules/node-pty/build/Release/obj.target
# Never call the launcher by its bare name. The guest shell's PATH is not
# guaranteed to carry /usr/local/bin, and under set -e a command-not-found
# raised inside this substitution ended the whole phase: the 0.1.5-rc.2 build
# died here with "scripts/build-rootfs.sh: line 161: dsh: command not found" and
# no phase token, which reads exactly like a tui regression. Report what is
# actually on disk instead, and never let a diagnostic end the phase.
echo "step: report"
dsh_launcher=/usr/local/bin/dsh
dsh_version="not executable"
if [ -x "\$dsh_launcher" ]; then
    dsh_version=\$("\$dsh_launcher" --version 2>&1 | head -n 1 || true)
fi
echo "guest node: \$(node -v), dsh: \$dsh_version"
ls -l /usr/local/bin/dsh /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js 2>&1 || true
du -sh /usr/local/lib/node_modules /usr/lib/node_modules 2>/dev/null || true
[ "\$tui_ok" = "1" ] && echo DSH-PHASE3-OK
exit 0
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
