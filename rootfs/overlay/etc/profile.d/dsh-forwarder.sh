# Point dsh at the host-side model forwarder when we are running inside the
# DSH iOS app.
#
# iOS refuses the guest's own outbound connects, so the app listens on
# 127.0.0.1:31337 and reaches the API through its own network. dsh accepts the
# base-URL variable only from the launching environment (see BOOTSTRAP_NAMES in
# @deepseek-ai/dsh-app-boot), never from a .env file, so a shell has to export
# it like this.
#
# There is no environment marker to test: the app starts terminal sessions with
# nothing but TERM (TerminalViewController.startSession). The bridge file the
# app writes into the guest at boot exists only inside the app, so its presence
# is the signal -- outside it, a plain CLI emulator has working network and
# needs no forwarding.
#
# `dsh-cli` reads the same file; this exists so a hand-typed `dsh` works too.
if [ -z "$DEEPSEEK_BASE_URL" ] && [ -r /root/.dsh/.host-bridge.env ]; then
	DEEPSEEK_BASE_URL=http://127.0.0.1:31337
	export DEEPSEEK_BASE_URL
fi
