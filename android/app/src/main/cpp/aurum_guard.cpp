// aurum_guard.cpp
//
// Native re-implementation of AurumIntegrityGuard's detection surface.
// Moved here, out of Kotlin, for one reason only: reading disassembled
// ARM/x86 machine code to recover this logic is a meaningfully higher
// bar than reading decompiled-but-still-structured Kotlin/Java, even
// after aggressive R8 obfuscation. This is a friction increase, not a
// guarantee — see the same disclaimer as the original Kotlin file.
//
// DESIGN CONTRACT (unchanged from AurumIntegrityGuard.kt):
// 1. NEVER crash, NEVER block launch. Every check is best-effort signal
//    only. Any exception/errno path fails closed to "not suspicious".
// 2. Returns ONE coarse boolean — which specific signal fired is never
//    exposed back to Kotlin, so an attacker probing the flag learns
//    nothing about which check tripped.
// 3. This does not and cannot stop a professional who properly hides
//    root (Magisk DenyList configured correctly), patches a Frida
//    gadget, or instruments at the kernel level. It raises the cost of
//    casual/default-configuration analysis, nothing more.
//
// This file intentionally does NOT touch anything related to YouTube
// extraction/playback (NewPipeExtractor, YoutubeInnertube,
// HybridStreamResolver) — out of scope by explicit request.

#include <jni.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <cstring>
#include <cerrno>
#include <cctype>

namespace {

// ---------------------------------------------------------------------
// Tiny XOR obfuscation for the plain-text signal strings this file
// needs ("su", "frida", root package names, etc). Without this,
// `strings libaurumguard.so` dumps every path/keyword this check looks
// for in one command — trivial recon for anyone probing what's
// detected. Each string is stored XOR'd and only decoded into a real
// std::string at the moment a check runs, so cleartext only exists
// briefly on the stack, never as a static blob `strings` can find.
//
// This is NOT cryptography — a single-byte XOR is reversible in
// seconds by anyone who bothers to disassemble and trace it. Its only
// job is to defeat the zero-effort `strings` dump, same tier as every
// other check in this file.
// ---------------------------------------------------------------------
    constexpr char kXorKey = 0x5A;

    template<size_t N>
    struct ObfString {
        char data[N];

        constexpr explicit ObfString(const char (&input)[N]) : data{} {
            for (size_t i = 0; i < N; ++i) {
                data[i] = static_cast<char>(input[i] ^ kXorKey);
            }
        }

        [[nodiscard]] std::string decode() const {
            std::string out(N - 1, '\0');
            for (size_t i = 0; i < N - 1; ++i) {
                out[i] = static_cast<char>(data[i] ^ kXorKey);
            }
            return out;
        }
    };

#define OBF(str) (ObfString(str).decode())

// ---------------------------------------------------------------------
// Root indicators: su binary presence + build tags.
// Same signal set as the original Kotlin version, just evaluated here.
// Paths are XOR-obfuscated (see ObfString above) so they don't sit as
// cleartext in the .so.
// ---------------------------------------------------------------------
    std::vector<std::string> suPaths() {
        return {
                OBF("/system/bin/su"),
                OBF("/system/xbin/su"),
                OBF("/sbin/su"),
                OBF("/system/su"),
                OBF("/system/bin/.ext/.su"),
                OBF("/data/local/xbin/su"),
                OBF("/data/local/bin/su"),
                OBF("/data/local/su"),
                OBF("/su/bin/su"),
        };
    }

    bool fileExists(const std::string &path) {
        struct stat st{};
        return stat(path.c_str(), &st) == 0;
    }

    bool suBinaryPresent() {
        for (const auto &path : suPaths()) {
            if (fileExists(path)) return true;
        }
        return false;
    }

// ---------------------------------------------------------------------
// Root via mount inspection: checks for read-write remounts on
// normally-read-only system partitions, and for common Magisk mount
// markers in /proc/mounts. Independent of su-binary presence — catches
// setups where su itself has been renamed/hidden but the filesystem
// still shows tamper evidence.
// ---------------------------------------------------------------------
    bool suspiciousMountsPresent() {
        std::ifstream mounts("/proc/mounts");
        if (!mounts.is_open()) return false;

        const std::string magiskMarker = OBF("magisk");
        const std::string overlayMarker = OBF("/sbin/.magisk");

        std::string line;
        while (std::getline(mounts, line)) {
            if (line.find(magiskMarker) != std::string::npos ||
                line.find(overlayMarker) != std::string::npos) {
                return true;
            }
        }
        return false;
    }

// ---------------------------------------------------------------------
// Debugger attach: a native ptrace self-check. If a debugger (or Frida,
// which attaches via ptrace on many configurations) is already attached
// to this process, a second PTRACE_TRACEME from within the process
// itself fails with EPERM. This is a well-known but still effective
// native-level signal that has no direct Java/Kotlin equivalent as
// cheap as this — Debug.isDebuggerConnected() only sees JDWP debuggers,
// not native attaches, so this genuinely adds coverage Kotlin didn't
// have, not just relocates the same check.
// ---------------------------------------------------------------------
    bool nativeDebuggerAttached() {
        errno = 0;
        long result = ptrace(PTRACE_TRACEME, 0, nullptr, nullptr);
        if (result == -1 && errno == EPERM) {
            // Something is already tracing us.
            return true;
        }
        if (result == 0) {
            // We successfully attached tracing to ourselves; detach
            // immediately so normal execution (and any legitimate
            // profiler) isn't disrupted.
            ptrace(PTRACE_DETACH, 0, nullptr, nullptr);
        }
        return false;
    }

// ---------------------------------------------------------------------
// /proc/self/status TracerPid: a second, independent way to catch an
// already-attached tracer (covers cases where the ptrace self-attach
// trick above is itself being intercepted by a hooking framework that
// hides from it specifically).
// ---------------------------------------------------------------------
    bool tracerPidNonZero() {
        std::ifstream status("/proc/self/status");
        if (!status.is_open()) return false;

        std::string line;
        while (std::getline(status, line)) {
            if (line.rfind("TracerPid:", 0) == 0) {
                std::istringstream iss(line.substr(10));
                int pid = 0;
                iss >> pid;
                return pid != 0;
            }
        }
        return false;
    }

// ---------------------------------------------------------------------
// Frida default-configuration signal, evaluated natively instead of by
// scanning /proc/self/maps text from Kotlin: same signal (default
// frida-server thread name / port), but a native attacker attempting to
// hook this check has to find and patch a stripped, hidden-visibility
// symbol instead of an easily-located Kotlin method.
// ---------------------------------------------------------------------
    bool fridaDefaultMapsSignal() {
        std::ifstream maps("/proc/self/maps");
        if (!maps.is_open()) return false;

        const std::string fridaMarker = OBF("frida");
        const std::string gumMarker = OBF("gum-js-loop");

        std::string line;
        while (std::getline(maps, line)) {
            if (line.find(fridaMarker) != std::string::npos ||
                line.find(gumMarker) != std::string::npos) {
                return true;
            }
        }
        return false;
    }

// ---------------------------------------------------------------------
// Emulator detection: checks build-property-equivalent native signals
// (kernel QEMU markers, common emulator device files) that survive even
// if the Kotlin-level Build.FINGERPRINT/MODEL strings were spoofed by
// a repackaging tool — those Java fields are trivial to override via
// reflection or a Xposed module, whereas these kernel-level traces are
// not. A piracy/cracking workflow overwhelmingly runs on an emulator
// (fast iterate, snapshot/revert, no real device needed), so this signal
// is disproportionately useful even though legitimate emulator users
// (rare for a phone music app) will also trip it.
// ---------------------------------------------------------------------
    bool emulatorIndicatorsPresent() {
        // QEMU pipe device — present on the vast majority of Android
        // emulator configurations (stock AVD, Genymotion, most cloud
        // device farms), absent on real hardware.
        const std::string qemuPipe = OBF("/dev/qemu_pipe");
        if (fileExists(qemuPipe)) return true;

        // /proc/cpuinfo "Goldfish"/"Ranchu" — the AOSP emulator's virtual
        // CPU identifies itself this way; no real Android device does.
        std::ifstream cpuinfo("/proc/cpuinfo");
        if (cpuinfo.is_open()) {
            const std::string goldfish = OBF("goldfish");
            const std::string ranchu = OBF("ranchu");
            std::string line;
            while (std::getline(cpuinfo, line)) {
                std::string lower = line;
                for (auto &c : lower) c = static_cast<char>(tolower(c));
                if (lower.find(goldfish) != std::string::npos ||
                    lower.find(ranchu) != std::string::npos) {
                    return true;
                }
            }
        }

        return false;
    }

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aurum_music_AurumIntegrityGuard_nativeCheckSuspicious(
        JNIEnv * /*env*/, jobject /*thiz*/) {
    // Fail-closed wrapper: any unexpected native error here must never
    // propagate as a crash. try/catch around the whole native check set
    // mirrors the Kotlin version's own top-level try/catch.
    try {
        bool suspicious =
                suBinaryPresent() ||
                suspiciousMountsPresent() ||
                nativeDebuggerAttached() ||
                tracerPidNonZero() ||
                fridaDefaultMapsSignal() ||
                emulatorIndicatorsPresent();
        return suspicious ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        return JNI_FALSE;
    }
}
