#if NEXPLAY_MKXP
import Foundation
import Darwin

/// 8.15.8: writes where every thread of the app is (state, CPU use and a call stack) to the App Log. Used by the Ace
/// player's watchdog when the main thread stops answering, so Export Logs shows what the core is doing / waiting for.
/// The stack is read with the frame-pointer chain while the thread is suspended; nothing is allocated or symbolized
/// until it runs again (a suspended thread can hold the malloc or dyld lock).
enum ThreadSampler {
    static func snapshot(label: String) {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let list = threads else {
            AppLog.log("threads (\(label)): the thread list could not be read")
            return
        }
        let me = mach_thread_self()
        AppLog.log("threads (\(label)): \(count) threads")
        for index in 0..<Int(count) {
            let thread = list[index]
            if thread == me { continue }
            describe(thread, number: index)
        }
        mach_port_deallocate(mach_task_self_, me)
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }   // 8.20.1: the thread send rights
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    }

    private static func describe(_ thread: thread_t, number: Int) {
        var info = thread_basic_info()
        var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(infoCount)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), raw, &infoCount)
            }
        }
        var name = "?"
        if let posix = pthread_from_mach_thread_np(thread) {
            var buffer = [CChar](repeating: 0, count: 64)
            if pthread_getname_np(posix, &buffer, 64) == 0, buffer[0] != 0 { name = String(cString: buffer) }
        }
        let states = [1: "running", 2: "stopped", 3: "waiting", 4: "uninterruptible", 5: "halted"]
        let state = result == KERN_SUCCESS ? (states[Int(info.run_state)] ?? "state \(info.run_state)") : "?"
        let cpu = result == KERN_SUCCESS ? Int(Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100) : -1

        var addresses = [UInt](repeating: 0, count: 28)
        var found = 0
        #if arch(arm64) && !arch(arm64e)
        var state64 = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let stateCapacity = Int(stateCount)
        thread_suspend(thread)
        let got = withUnsafeMutablePointer(to: &state64) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: natural_t.self, capacity: stateCapacity) { raw in
                thread_get_state(thread, ARM_THREAD_STATE64, raw, &stateCount)
            }
        }
        if got == KERN_SUCCESS {
            let mask: UInt = 0x0000_7FFF_FFFF_FFFF
            addresses[0] = UInt(state64.__pc) & mask
            found = 1
            if state64.__lr != 0 { addresses[1] = UInt(state64.__lr) & mask; found = 2 }
            var frame = UInt(state64.__fp)
            let floor = UInt(state64.__sp)
            while found < addresses.count, frame > floor, frame & 0xF == 0, frame - floor < 16_000_000 {
                var pair: (UInt, UInt) = (0, 0)
                var read: vm_size_t = 0
                let ok = withUnsafeMutablePointer(to: &pair) { pointer in
                    vm_read_overwrite(mach_task_self_, vm_address_t(frame), 16,
                                      vm_address_t(UInt(bitPattern: pointer)), &read)
                }
                if ok != KERN_SUCCESS || read != 16 || pair.1 == 0 { break }
                addresses[found] = pair.1 & mask
                found += 1
                if pair.0 <= frame { break }
                frame = pair.0
            }
        }
        thread_resume(thread)
        #endif

        AppLog.log("thread \(number) \"\(name)\": \(state), cpu \(cpu)%")
        for i in 0..<found {
            AppLog.log("   \(symbol(addresses[i]))")
        }
    }

    private static func symbol(_ address: UInt) -> String {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else {
            return String(address, radix: 16)
        }
        let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
        let base = info.dli_saddr.map { UInt(bitPattern: $0) } ?? UInt(bitPattern: info.dli_fbase)
        let offset = address &- base
        if let name = info.dli_sname {
            return "\(String(cString: name)) +\(offset)  [\(image)]"
        }
        return "\(image) +\(String(address &- UInt(bitPattern: info.dli_fbase), radix: 16))"
    }
}
#endif
