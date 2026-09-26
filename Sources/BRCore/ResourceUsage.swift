#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Peak resident-set sizes from `getrusage`, normalized to bytes on every platform.
public enum ResourceUsage {
    /// Peak resident set size of this process so far, in bytes (0 if unavailable).
    public static func peakResidentBytes() -> Int { maxRSSBytes(children: false) }

    /// Peak resident set size of the largest finished child process, in bytes (0 if unavailable).
    public static func peakChildResidentBytes() -> Int { maxRSSBytes(children: true) }

    private static func maxRSSBytes(children: Bool) -> Int {
        var usage = rusage()
        #if canImport(Glibc)
        // glibc imports RUSAGE_SELF / RUSAGE_CHILDREN as an enum; getrusage takes its raw value.
        let who = __rusage_who_t(children ? RUSAGE_CHILDREN.rawValue : RUSAGE_SELF.rawValue)
        #else
        let who = children ? RUSAGE_CHILDREN : RUSAGE_SELF
        #endif
        guard getrusage(who, &usage) == 0 else { return 0 }
        #if canImport(Darwin)
        return Int(usage.ru_maxrss)        // bytes on Darwin
        #else
        return Int(usage.ru_maxrss) * 1024 // KiB on Linux
        #endif
    }
}
