# Point dsh at the host-side model forwarder when we are running inside the
# DSH iOS app. The guest's own sockets cannot leave the sandbox on iOS, so the
# app listens on 127.0.0.1:31337 and reaches the API through its own network.
#
# dsh only accepts the base-URL variable from the launching environment (see
# BOOTSTRAP_NAMES in @deepseek-ai/dsh-app-boot), never from a .env file, so a
# shell started in the app's terminal has to export it like this. The host
# bridge variables are set by the app and by nothing else, which is how this
# stays inert in a plain CLI emulator or in the CI rootfs test.
if [ -n "$DSH_HOST_BRIDGE_URL" ] && [ -z "$DEEPSEEK_BASE_URL" ]; then
	DEEPSEEK_BASE_URL=http://127.0.0.1:31337
	export DEEPSEEK_BASE_URL
fi
