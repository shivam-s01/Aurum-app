package com.aurum.music

import android.util.Base64

/**
 * Runtime string de-obfuscation for hardcoded secrets (API keys, base
 * URLs, tokens) that would otherwise sit as cleartext in the APK's
 * strings table, visible to a simple `strings` dump or a quick look at
 * decompiled resources/bytecode — no reverse-engineering skill needed
 * to find them, they're just... there.
 *
 * NOT ENCRYPTION. XOR is trivially reversible by anyone who actually
 * disassembles this class — the point is only to stop the zero-effort
 * case (a plain strings/grep dump on the APK), same tier as every
 * other check in this security pass. If a secret is genuinely
 * sensitive (e.g. a private signing key, not a client-side API key
 * every app inherently ships), it belongs on a server, not in the APK
 * at all — no amount of client-side obfuscation changes that.
 *
 * USAGE — replace a hardcoded secret like this:
 *
 *   const val API_KEY = "sk_live_abc123..."
 *
 * with:
 *
 *   private val API_KEY_OBF = "..." // see HOW TO GENERATE below
 *   val apiKey: String by lazy { AurumSecretObfuscator.reveal(API_KEY_OBF) }
 *
 * HOW TO GENERATE an obfuscated value for a NEW secret: use
 * AurumSecretObfuscator.conceal("your-real-secret-here") once (e.g. in
 * a scratch unit test or a temporary main() call), copy the printed
 * Base64 string into your code as the _OBF constant, then delete the
 * plaintext. conceal() is included below specifically so this can be
 * done without any external tool.
 */
internal object AurumSecretObfuscator {

    // Per-app XOR key. This constant itself is technically visible in
    // decompiled output too — there is no way to fully hide a key that
    // must ship inside the app that uses it. Changing this invalidates
    // every previously-generated _OBF value, so pick it once.
    private val KEY = byteArrayOf(
        0x4B, 0x72, 0x69, 0x73, 0x68, 0x2D, 0x41, 0x75,
        0x72, 0x75, 0x6D, 0x2D, 0x32, 0x30, 0x32, 0x36,
    )

    /** Decode an obfuscated value produced by [conceal] back to plaintext. */
    fun reveal(obfuscatedBase64: String): String {
        val bytes = Base64.decode(obfuscatedBase64, Base64.NO_WRAP)
        val out = ByteArray(bytes.size)
        for (i in bytes.indices) {
            out[i] = (bytes[i].toInt() xor KEY[i % KEY.size].toInt()).toByte()
        }
        return String(out, Charsets.UTF_8)
    }

    /**
     * One-time helper to generate an _OBF constant from a real secret.
     * Not meant to run in the shipped app — call it from a scratch
     * test/script, copy the result, then remove the call site and the
     * plaintext that produced it.
     */
    fun conceal(plaintext: String): String {
        val bytes = plaintext.toByteArray(Charsets.UTF_8)
        val out = ByteArray(bytes.size)
        for (i in bytes.indices) {
            out[i] = (bytes[i].toInt() xor KEY[i % KEY.size].toInt()).toByte()
        }
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }
}
