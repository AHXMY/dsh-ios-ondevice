// tui-pty-check.cjs -- boot the tui profile the way the device does: under a real
// PTY, through node-pty (the same library the app's terminal session uses).
//
// Why this exists: the first version of the boot check ran the terminal app with
// stdin at /dev/null and stdout redirected, which is a pipe. The app guards
// against exactly that and refuses to start:
//
//     ui-tui: both stdin and stdout must be TTYs;
//     use the one-shot @deepseek-ai/dsh-cli-demo app for pipes
//
// That refusal says nothing about the image -- the whole plugin tree had already
// imported and applied by then -- but it made the build fail, because the check
// demanded a clean exit from something that cannot work without a terminal.
//
// Running it here is also the only check that exercises node-pty inside the
// guest, which is the native module this app depends on most.
//
// Output contract (parsed by build-rootfs.sh):
//   PTY-UNAVAILABLE <msg>   node-pty could not be loaded -> caller falls back
//   PTY-SPAWN-FAILED <msg>  the emulator refused to allocate a pty -> fallback
//   PTY-OUTPUT-BYTES <n>    the app ran for <n> bytes of terminal output
//   then the tail of what it rendered, so the log shows the real screen.

const BIN = '/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js'
const HOLD_MS = Number(process.env.TUI_PTY_HOLD_MS || 20000)

let pty
try {
  pty = require('/usr/local/lib/node_modules/node-pty')
} catch (error) {
  console.log('PTY-UNAVAILABLE ' + (error && error.message ? error.message : error))
  process.exit(3)
}

let child
try {
  child = pty.spawn('node', ['--expose-internals', BIN, '--profile', 'tui'], {
    name: 'xterm-256color',
    cols: 100,
    rows: 30,
    cwd: '/root',
    env: process.env,
  })
} catch (error) {
  console.log('PTY-SPAWN-FAILED ' + (error && error.message ? error.message : error))
  process.exit(4)
}

let seen = ''
let exited = null
child.onData((chunk) => { seen += chunk })
child.onExit((e) => { exited = e })

setTimeout(() => {
  try { child.kill() } catch { /* already gone */ }
  console.log('PTY-OUTPUT-BYTES ' + seen.length + (exited ? ' EXIT ' + JSON.stringify(exited) : ''))
  console.log('---- terminal tail ----')
  console.log(seen.slice(-2500))
  console.log('---- end terminal tail ----')
  process.exit(0)
}, HOLD_MS)
