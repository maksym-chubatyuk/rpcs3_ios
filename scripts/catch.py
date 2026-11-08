"""lldb script: attach to the running app and stop at a function, then print the stopped
thread's backtrace and registers. Signals RPCS3 handles itself are passed through.

  xcrun lldb --batch -o "command script import scripts/catch.py" -o "catch_at <device> <pid> <function> [condition]"
"""

import time

import lldb


def catch_at(debugger, command, result, internal_dict):
    args = command.split(maxsplit=3)
    device, pid, function = args[0], int(args[1]), args[2]
    condition = args[3] if len(args) > 3 else None
    debugger.SetAsync(False)
    interp = debugger.GetCommandInterpreter()

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

    target = debugger.GetSelectedTarget()
    bp = target.BreakpointCreateByName(function)
    if condition:
        bp.SetCondition(condition)
    print(f"[catch] breakpoint on {function} ({bp.GetNumLocations()} locations) condition={condition}", flush=True)
    for sig in ("SIGSEGV", "SIGBUS", "SIGUSR1", "SIGUSR2", "SIGPIPE", "SIGILL"):
        interp.HandleCommand(f"process handle {sig} -s false -p true -n false", lldb.SBCommandReturnObject())

    for _ in range(2000):
        process.Continue()
        state = process.GetState()
        if state in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
            print(f"[catch] process {lldb.SBDebugger.StateAsCString(state)}", flush=True)
            return
        thread = next((t for t in process if t.GetStopReason() == lldb.eStopReasonBreakpoint), None)
        if thread is None:
            continue
        print(f"[catch] hit in thread '{thread.GetName()}'", flush=True)
        for i, frame in enumerate(thread):
            if i > 12:
                break
            regs = ""
            if i < 3:
                XX
            print(f"  {i:2} {frame.GetFunctionName()}  {regs}", flush=True)
        process.Kill()
        return


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.catch_at catch_at")
