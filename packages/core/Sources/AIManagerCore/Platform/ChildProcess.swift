import Foundation
#if os(Windows)
import WinSDK
#endif

/// The one place the core starts a child process.
/// Windows: the child goes into its own Job Object with kill-on-close, and the job closes when the child exits.
/// So a stop, timeout or cancel that ends the child (for a `.cmd` wrapper, cmd.exe) also ends what it started
/// (node, bash), and nothing is left holding the child's pipes. POSIX: `Process.run()` unchanged.
enum ChildProcess {
    static func run(_ process: Process) throws {
        try process.run()
#if os(Windows)
        guard containTree(of: process.processIdentifier) else {
            // Fail closed: a child whose tree cannot be contained is stopped now, not left to outlive a timeout.
            let code = GetLastError()
            process.terminate()
            throw AIManagerError.operationFailed("Could not contain a child process in a job object (\(code)).")
        }
#endif
    }

#if os(Windows)
    /// Puts `pid` in a new kill-on-close job that closes once `pid` exits. True also when `pid` already exited.
    // shortcut: the child joins its job just after it starts, so a grandchild started in that first instant stays
    // outside; upgrade to CreateProcessW with CREATE_SUSPENDED if a tool is seen to escape.
    static func containTree(of pid: Int32) -> Bool {
        let access = DWORD(PROCESS_SET_QUOTA) | DWORD(PROCESS_TERMINATE) | DWORD(SYNCHRONIZE)
        guard let child = OpenProcess(access, false, DWORD(pid)) else { return false }
        guard let job = CreateJobObjectW(nil, nil) else { CloseHandle(child); return false }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        guard SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                      DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)),
              AssignProcessToJobObject(job, child) else {
            let exited = WaitForSingleObject(child, 0) == 0 // WAIT_OBJECT_0: signaled, so it already exited
            CloseHandle(job)
            CloseHandle(child)
            return exited
        }
        let handles = (job: UInt(bitPattern: job), child: UInt(bitPattern: child))
        Thread.detachNewThread {
            guard let child = HANDLE(bitPattern: handles.child), let job = HANDLE(bitPattern: handles.job) else { return }
            WaitForSingleObject(child, INFINITE)
            CloseHandle(job) // kill-on-close ends every process still in the tree
            CloseHandle(child)
        }
        return true
    }
#endif
}
