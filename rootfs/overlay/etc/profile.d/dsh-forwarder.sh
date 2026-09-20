# Point dsh at the host-side model forwarder when we are running inside the
# DSH iOS app.
#
# iOS refuses the guest's own outbound connects, so the app listens on
# 127.0.0.1:31337 and reaches the API through its own network. dsh accepts the
# base-URL variable only from the launching environment (see BOOTSTRAP_NAMES in
# @deepseek-ai/dsh-app-boot), never from a .env file, so a shell needs to export
# it like this.
#
# There is no environment marker to test: the app starts terminal sessions with
# nothing but TERM (TerminalViewController.startSession). The forwarder being
# reachable on loopback is the signal instead -- outside the app nothing is
# listening there, and the probe just fails and this file does nothing.
#
# `dsh-cli` exports the same value itself; this exists so a hand-typed `dsh`
# works too.
if [ -z "$DEEPSEEK_BASE_URL" ] &&
	command -v curl >/dev/null 2>&1 &&
	curl -s -o /dev/null -m 1 "http://127.0.0.1:31337/" 2>/dev/null; then
	DEEPSEEK_BASE_URL=http://127.0.0.1:31337
	export DEEPSEEK_BASE_URL
fi
