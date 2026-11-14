#if os(Windows)
import CRT
import Foundation
@testable import AIManagerCore

// On Windows the tests see two of each POSIX name: the C runtime's, and the core's shim from POSIXCompat.swift
// (through @testable). A declaration in this module wins over both, so these forward to the core's shims and the
// test files compile unchanged.

typealias stat = AIManagerCore.stat
typealias pollfd = AIManagerCore.pollfd
let S_IFMT = AIManagerCore.S_IFMT
let S_IFREG = AIManagerCore.S_IFREG
let S_IFDIR = AIManagerCore.S_IFDIR
let S_IFLNK = AIManagerCore.S_IFLNK
let POLLIN = AIManagerCore.POLLIN
let SIGKILL = AIManagerCore.SIGKILL
let S_IRWXU: Int32 = 0o700

func lstat(_ path: UnsafePointer<CChar>, _ info: UnsafeMutablePointer<stat>) -> Int32 { AIManagerCore.lstat(path, info) }
func fstat(_ descriptor: Int32, _ info: UnsafeMutablePointer<stat>) -> Int32 { AIManagerCore.fstat(descriptor, info) }
func open(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { AIManagerCore.open(path, flags, mode) }
@discardableResult
func flock(_ descriptor: Int32, _ operation: Int32) -> Int32 { AIManagerCore.flock(descriptor, operation) }
@discardableResult
func kill(_ pid: Int32, _ signal: Int32) -> Int32 { AIManagerCore.kill(pid, signal) }
func getuid() -> uid_t { AIManagerCore.getuid() }
func getpid() -> Int32 { AIManagerCore.getpid() }
func realpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    AIManagerCore.realpath(path, resolved)
}
func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: UInt32, _ milliseconds: Int32) -> Int32 {
    AIManagerCore.poll(descriptors, count, milliseconds)
}
func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { AIManagerCore.read(descriptor, buffer, count) }
func rename(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32 { AIManagerCore.rename(source, destination) }
#endif
