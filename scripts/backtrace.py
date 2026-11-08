"""lldb script: attach to the app on the iPhone, print every thread's backtrace, detach.

  xcrun lldb --batch -o "command script import scripts/backtrace.py" -o "backtrace_all <device> <pid> [frames]"
"""

import time

import lldb


def backtrace_all(debugger, command, result, internal_dict):
    args = command.split()
    device, pid = args[0], int(args[1])
    frames = int(args[2]) if len(args) > 2 else 16
    debugger.SetAsync(False)
    interp = debugger.GetCommandInterpreter()

    for attempt in range(10):
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

    for thread in process:
        name = thread.GetName() or ""
        print(f"thread #{thread.GetIndexID()} tid={thread.GetThreadID():#x} '{name}'")
        for i, frame in enumerate(thread):
            if i >= frames:
                break
            module = frame.GetModule().GetFileSpec().GetFilename() or "?"
            print(f"    {i:2} {module:24} {frame.GetFunctionName() or hex(frame.GetPC())}")
    process.Detach()


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(f"command script add -f {__name__}.backtrace_all backtrace_all")
