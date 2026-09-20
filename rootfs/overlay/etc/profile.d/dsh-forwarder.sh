# Two things every dsh run inside the app needs set, and that nothing else can
# set for it.
#
# 1. The model base URL. iOS refuses the guest's own outbound connects, so the
#    app listens on 127.0.0.1:31337 and reaches the API through its own network.
#    dsh accepts this variable only from the launching environment (see
#    BOOTSTRAP_NAMES in @deepseek-ai/dsh-app-boot), never from a .env file.
#
# 2. The permission mode. dsh-base defaults to sandbox `workspace-write` plus
#    approval `ask`, and neither half can work in this guest: the confining
#    executors need bwrap or Landlock (the guest kernel has neither, and an
#    unusable runner fails closed with SANDBOX_UNAVAILABLE rather than running
#    unconfined), and approval is answered only by a UI channel or the ACP
#    bridge, so `ask` fails closed to `unavailable` with no one to ask.
#    `danger-full-access` resolves the sandbox mode and, in the same expression,
#    the approval policy to `never`. The browser profile reaches the same place
#    through rootfs/overlay/usr/local/share/dsh/cordis.patch.yml.
#
# There is no environment marker to test: the app starts terminal sessions with
# nothing but TERM (TerminalViewController.startSession). The bridge file the
# app writes into the guest at boot exists only inside the app, so its presence
# is the signal -- outside it, a plain CLI emulator has working network and a
# real kernel, and needs neither.
if [ -r /root/.dsh/.host-bridge.env ]; then
	if [ -z "$DEEPSEEK_BASE_URL" ]; then
		DEEPSEEK_BASE_URL=http://127.0.0.1:31337
		export DEEPSEEK_BASE_URL
	fi
	: "${DSH_PERMISSION_MODE:=danger-full-access}"
	export DSH_PERMISSION_MODE
fi
