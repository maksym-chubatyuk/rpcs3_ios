"""lldb script: the Mac plays the JIT debugger for the app on a connected iPhone.

Loaded by scripts/run.sh:  lldb -o "command script import jit_host.py" -o "jit_host <device> <pid>"

The app asks with `brk #0xf00d`, command in x16 (rpcs3/JIT/JITPool.c):
  x16 = 1  prepare region: x0 = address (0: allocate), x1 = size; the address goes back in x0
  x16 = 0  detach
On iOS 26 (TXM) a page becomes executable once the debugger has written into it, so every
16 KiB page of the region gets a write. Writes straddle page boundaries: one round trip to the
device covers two pages, and round trips are what this costs.

Other stops (signals, faults) are passed back to the app untouched.
"""

import time

import lldb

BRK_JIT = 0xD43E01A0
PAGE = 0x4000


def log(text):
    print(f"[jit_host] {text}", flush=True)


def reg(frame, name):
    return frame.FindRegister(name).GetValueAsUnsigned()


def set_reg(frame, name, value):
    error = lldb.SBError()
    frame.FindRegister(name).SetValueFromCString(hex(value), error)
    if error.Fail():
        raise RuntimeError(f"cannot set {name}: {error}")


def prepare_region(process, address, size):
    error = lldb.SBError()
    size = (size + PAGE - 1) & ~(PAGE - 1)

    if address == 0:
        address = process.AllocateMemory(size, lldb.ePermissionsReadable | lldb.ePermissionsExecutable, error)
        if error.Fail() or not address:
            log(f"allocation of {size >> 20} MiB failed: {error}")
            return 0

    started = time.monotonic()
    offset = 0
    while offset < size:
        if offset + PAGE < size:
            # last byte of this page and first byte of the next
            target, data, step = address + offset + PAGE - 1, b"\0\0", 2 * PAGE
        else:
            target, data, step = address + offset, b"\0", PAGE
        process.WriteMemory(target, data, error)
        if error.Fail():
            log(f"write at {target:#x} failed: {error}")
            return 0
        offset += step

    log(f"prepared {size >> 20} MiB at {address:#x} ({size // PAGE} pages) in {time.monotonic() - started:.1f} s")
    return address


def stopped_thread(process):
    for thread in process:
        if thread.GetStopReason() not in (lldb.eStopReasonNone, lldb.eStopReasonInvalid):
            return thread
    return None


def serve(process):
    error = lldb.SBError()
    while True:
        process.Continue()
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
            log(f"process {lldb.SBDebugger.StateAsCString(state)} (exit status {process.GetExitStatus()})")
            return

        thread = stopped_thread(process)
        if thread is None:
            continue

        frame = thread.GetFrameAtIndex(0)
        pc = frame.GetPC()
        insn = process.ReadUnsignedFromMemory(pc, 4, error)

        if error.Fail() or insn != BRK_JIT:
            # Not ours: let the app's own handlers see it on the next Continue
            log(f"passing stop at {pc:#x}: {thread.GetStopDescription(120)}")
            continue

        command = reg(frame, "x16")
        frame.SetPC(pc + 4)

        if command == 0:
            log("app asked to detach")
            process.Detach()
            return
        if command == 1:
            set_reg(frame, "x0", prepare_region(process, reg(frame, "x0"), reg(frame, "x1")))
        else:
            log(f"unknown request {command}")
            set_reg(frame, "x0", 0)


def jit_host(debugger, command, result, internal_dict):
    device, pid = command.split()
    pid = int(pid)
    debugger.SetAsync(False)
    interp = debugger.GetCommandInterpreter()

    # Right after a launch CoreDevice can take a while to answer; retry the attach.
    for attempt in range(10):
        problems = []
        for line in ("device list", f"device select {device}", f"device process attach --pid {pid}"):
            out = lldb.SBCommandReturnObject()
            interp.HandleCommand(line, out)
            if out.GetError():
                problems.append(f"{line}: {out.GetError().strip()}")
        process = debugger.GetSelectedTarget().GetProcess()
        if process.IsValid() and process.GetProcessID() == pid:
            break
        log(f"attach attempt {attempt + 1} failed: {' | '.join(problems)}")
        time.sleep(4)
    else:
        result.SetError("could not attach")
        return

    log(f"attached to pid {pid}")
    serve(process)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.jit_host jit_host")
