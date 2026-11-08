# StikJIT 1.9.0

Prebuilt `StikJIT.xcframework`, used by `rpcs3JITHelper` (the app extension that enables JIT on
the iPhone itself, through LocalDevVPN and the device's pairing file).

- StikJIT: MPL-2.0 (`LICENSE-MPL-2.0.txt`). Source: https://github.com/StikDebug/StikJIT/tree/1.9.0
- It contains idevice, Copyright 2026 Jackson Coxson, MIT (`LICENSE-MIT-idevice.txt`).
  Source: https://github.com/jkcoxson/idevice

The helper runs StikJIT's bundled `universal.js`. It answers the requests that
`rpcs3/JIT/JITPool.c` sends (`brk #0xf00d`, x16 = 1 to prepare a region, x16 = 0 to detach),
the same way `scripts/jit_host.py` answers them from a Mac.
