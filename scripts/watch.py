"""lldb script: attach to the running app and catch writes to given addresses with hardware
watchpoints. Prints the writing thread's name, backtrace and registers for the first hits.

  xcrun lldb --batch -o "command script import scripts/watch.py" -o "watch_writes <device> <pid> <hits> <addr> [addr...]"

Signals RPCS3 handles itself (SIGSEGV/SIGBUS for MMIO and memory tracking) are passed through.
"""

import time

import lldb


def watch_writes(debugger, command, result, internal_dict):
    args = command.split()
    device, pid, hits = args[0], int(args[1]), int(args[2])
    addrs = [int(a, 16) for a in args[3:]]
    debugger.SetAsync(False)
    interp = debugger.GetCommandInterpreter()

    # RPCS3 relies on its own SIGSEGV/SIGBUS handler for memory tracking; keep debugserver from
    # catching the Mach exception first (it would loop on the faulting instruction).
    interp.HandleCommand("settings set platform.plugin.darwin.ignored-exceptions EXC_BAD_ACCESS", lldb.SBCommandReturnObject())
    for _ in range(10):
        for line in ("device list", f"device select {device}", f"device process attach --pid {pid}"):
            interp.HandleCommand(line, lldb.SBCommandReturnObject())
        process = debugger.GetSelectedTarget().GetProcess()
        if process.IsValid() and process.GetProcessID() == pid:
            break
        time.sleep(3)
    else:
        result.SetError("could not attach")
        return

    for _ in range(50):
        if process.GetState() == lldb.eStateStopped:
            break
        time.sleep(0.2)

    target = debugger.GetSelectedTarget()
    for sig in ("SIGSEGV", "SIGBUS", "SIGUSR1", "SIGUSR2", "SIGPIPE", "SIGILL", "SIGTRAP"):
        out = lldb.SBCommandReturnObject()
        interp.HandleCommand(f"process handle {sig} -s false -p true -n false", out)

    for a in addrs:
        error = lldb.SBError()
        wp = target.WatchAddress(a, 4, False, True, error)
        print(f"[watch] {a:#x}: {'ok' if error.Success() else error}", flush=True)

    seen = 0
    deadline = time.time() + 300
    for _ in range(100000):
        process.Continue()
        while process.GetState() in (lldb.eStateRunning, lldb.eStateStepping) and time.time() < deadline:
            time.sleep(0.02)
        if time.time() >= deadline:
            print("[watch] time limit reached", flush=True)
            process.Stop()
            break
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
            print(f"[watch] process {lldb.SBDebugger.StateAsCString(state)}", flush=True)
            return
        thread = next((t for t in process if t.GetStopReason() == lldb.eStopReasonWatchpoint), None)
        if thread is None:
            others = [(t.GetName(), t.GetStopDescription(80)) for t in process if t.GetStopReason() not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid)]
            if others and _ < 50:
                print(f"[watch] other stop: {others[:3]}", flush=True)
            continue
        seen += 1
        frame0 = thread.GetFrameAtIndex(0)
        print(f"[watch] hit {seen} in thread '{thread.GetName()}' pc={frame0.GetPC():#x} reason={thread.GetStopDescription(100)}", flush=True)
        regs = " ".join(f"x{n}={frame0.FindRegister(f'x{n}').GetValueAsUnsigned():#x}" for n in range(0, 31))
        print(f"    {regs}", flush=True)
        for i, frame in enumerate(thread):
            if i > 14:
                break
            module = frame.GetModule().GetFileSpec().GetFilename() or "?"
            print(f"    {i:2} {module:20} {frame.GetFunctionName() or hex(frame.GetPC())}", flush=True)
        if seen >= hits:
            break

    process.Detach()


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.watch_writes watch_writes")
