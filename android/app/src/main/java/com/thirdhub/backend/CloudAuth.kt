package com.thirdhub.backend

// ThirdHub 账号体系: Supabase 登录 + 设备注册(th_devices)
// 后端登录后把 局域网地址+密钥+指纹 写入配对表, 前端/引擎登录同账号即可自动发现并连接
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

object CloudAuth {
    const val BASE = "https://mxvxlgjzeboktufumxbp.supabase.co"
    const val ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im14dnhsZ2p6ZWJva3R1ZnVteGJwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQzODM5OTcsImV4cCI6MjA5OTk1OTk5N30.QjSLfYAFhwX72YSeAcbTN5O2_PDLaNcv76HhdGJsqpo"

    var token = ""; var uid = ""; var email = ""
    val loggedIn get() = token.isNotEmpty()

    fun restore(ctx: Context) {
        val p = ctx.getSharedPreferences("cloud", 0)
        token = p.getString("token", "") ?: ""; uid = p.getString("uid", "") ?: ""; email = p.getString("email", "") ?: ""
    }
    private fun save(ctx: Context) {
        ctx.getSharedPreferences("cloud", 0).edit()
            .putString("token", token).putString("uid", uid).putString("email", email).apply()
    }
    fun signOut(ctx: Context) { token = ""; uid = ""; email = ""; save(ctx) }

    private fun post(path: String, body: JSONObject, auth: Boolean = false): Pair<Int, String> {
        val c = URL("$BASE$path").openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.setRequestProperty("apikey", ANON)
        c.setRequestProperty("Content-Type", "application/json")
        if (auth) c.setRequestProperty("Authorization", "Bearer $token")
        c.doOutput = true; c.connectTimeout = 10000; c.readTimeout = 10000
        OutputStreamWriter(c.outputStream).use { it.write(body.toString()) }
        val code = c.responseCode
        val txt = (if (code in 200..299) c.inputStream else c.errorStream)?.bufferedReader()?.readText() ?: ""
        c.disconnect()
        return code to txt
    }

    fun signIn(mail: String, pass: String): String? {
        val (code, txt) = post("/auth/v1/token?grant_type=password",
            JSONObject().put("email", mail).put("password", pass))
        if (code != 200) return try { JSONObject(txt).optString("error_description", "登录失败($code)") } catch (e: Exception) { "登录失败($code)" }
        val j = JSONObject(txt)
        token = j.optString("access_token"); uid = j.optJSONObject("user")?.optString("id") ?: ""; email = mail
        return null
    }

    fun signUp(mail: String, pass: String): String? {
        val (code, txt) = post("/auth/v1/signup",
            JSONObject().put("email", mail).put("password", pass))
        if (code != 200) return try { JSONObject(txt).optString("error_description", "注册失败($code)") } catch (e: Exception) { "注册失败($code)" }
        val j = JSONObject(txt)
        if (j.has("access_token")) { token = j.optString("access_token"); uid = j.optJSONObject("user")?.optString("id") ?: ""; email = mail }
        else return signIn(mail, pass)
        return null
    }

    // 注册/更新设备到配对表(前端与引擎按账号发现)
    fun registerDevice(ctx: Context, lanUrl: String, secret: String, fingerprint: String): String? {
        if (!loggedIn) return "未登录"
        val body = JSONObject()
            .put("user_id", uid)
            .put("device_type", "backend")
            .put("lan_url", lanUrl)
            .put("secret", secret)
            .put("fingerprint", fingerprint)
            .put("ipv6_url", "").put("tunnel_url", "")
            .put("updated_at", System.currentTimeMillis() / 1000)
        val c = URL("$BASE/rest/v1/th_devices").openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.setRequestProperty("apikey", ANON)
        c.setRequestProperty("Authorization", "Bearer $token")
        c.setRequestProperty("Content-Type", "application/json")
        c.setRequestProperty("Prefer", "resolution=merge-duplicates,return=minimal")
        c.doOutput = true; c.connectTimeout = 10000; c.readTimeout = 10000
        OutputStreamWriter(c.outputStream).use { it.write(JSONArray().put(body).toString()) }
        val code = c.responseCode
        c.disconnect()
        return if (code in 200..299) null else "注册失败($code)"
    }

    // 证书指纹(SHA-256, 纯Java计算, 不依赖系统openssl)
    fun certFingerprint(certFile: File): String {
        return try {
            val der = certFile.readBytes()
            // PEM → DER
            val pem = String(der)
            val b64 = pem.replace("-----BEGIN CERTIFICATE-----", "").replace("-----END CERTIFICATE-----", "")
                .replace("\\s".toRegex(), "")
            val raw = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
            val md = MessageDigest.getInstance("SHA-256").digest(raw)
            md.joinToString(":") { "%02X".format(it) }
        } catch (e: Exception) { "" }
    }
}
