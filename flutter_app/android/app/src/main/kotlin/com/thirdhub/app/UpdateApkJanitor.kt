package com.thirdhub.app

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.io.File

/**
 * 安装包清理 —— 「安装后删除安装包」。
 *
 * ## 为什么「拉起安装器之后就删」是错的
 *
 * 拉起系统安装器只是把 `content://` 交给**另一个进程**，安装器随后才去读这个文件。
 * 我们在 `startActivity` 之后立刻 `delete()`，安装器读到的就是空文件 ——
 * 用户看到的是「解析包时出现问题」，这次更新彻底失败。
 *
 * 所以删除必须挂在**能确认安装已经结束**的信号上，这里用两条：
 *
 *  1. **`MY_PACKAGE_REPLACED` 广播**（见 [AppUpdatedReceiver]）—— 覆盖安装成功的
 *     权威信号，系统只发给本应用。收到即代表「新版已经装上」，本应用自己的更新包
 *     全部可以删；而且此刻旧进程早已退出，文件不再被任何进程占用，删除一定成功。
 *  2. **启动时的兜底清理**（[sweep]，在 `MainActivity.onCreate` 调用）—— 兜住
 *     「用户中途取消了安装」「安装成功但广播没到」「下载中断留下残包」这些情况。
 *
 * ## 与旁支（thirdhub-flutter 轻壳）实现的差异 —— 不能照抄
 *
 * 旁支用 Android `DownloadManager` 下载到**固定文件名**，所以它的清理可以简单到
 * 「删掉那一个文件」。本仓库不是：
 *
 *  · 下载走 Dart 侧 `HttpClient`，落点是 `getExternalStorageDirectory()/updates`；
 *  · 文件名带毫秒时间戳（`<产品名>-<ts>.apk`），同一版本可能同时躺着多个包；
 *  · **该目录里还混放着「下载中心」下载的其它产品安装包**（漫画稳定版等）——
 *    它们不是本应用的更新包，绝不能因为「本应用被覆盖安装」就一起删掉。
 *
 * 因此这里靠**读包内 packageName** 区分归属：包名 == 本应用 → 自己的更新包；
 * 否则是其它产品包，只在过期时才动它。
 */
object UpdateApkJanitor {

    /** 与 Dart 侧 `Updater._updateDir()` 必须一致：`getExternalStorageDirectory()/updates`。 */
    private const val DIR_NAME = "updates"

    /** 超过这个时长还没被安装掉的包视为垃圾（用户中途放弃安装）。 */
    private const val STALE_MS = 3L * 24 * 60 * 60 * 1000

    /** 更新包所在目录；外部存储不可用时返回 null（调用方直接跳过）。 */
    fun updateDir(context: Context): File? {
        val files: File = context.getExternalFilesDir(null) ?: return null
        return File(files, DIR_NAME)
    }

    /**
     * 清理安装包。
     *
     * @param ownOnly 只清理**本应用自己的更新包**。`MY_PACKAGE_REPLACED` 路径传 true ——
     *   那一刻能确定新版已装上，自己的包必是垃圾，可以立刻全清；
     *   但绝不碰同目录下用户刚下载的其它产品包。
     *   启动兜底传 false，此时按「版本号」与「时效」两道闸门判断。
     * @return 实际删除的文件数（仅用于日志/调试）。
     */
    fun sweep(context: Context, ownOnly: Boolean = false): Int {
        val dir = updateDir(context) ?: return 0
        if (!dir.exists()) return 0
        val files = dir.listFiles() ?: return 0
        val installedCode = installedVersionCode(context)
        val now = System.currentTimeMillis()
        var removed = 0

        for (f in files) {
            if (!f.isFile) continue
            val name = f.name

            // ① 下载中途留下的临时文件（Dart 侧 `.part` / `.part.meta`）：
            //    未完成的下载不匹配 .apk 分支，这里只在过期后清理，
            //    避免误删「此刻正在续传」的进度。
            if (name.endsWith(".part") || name.endsWith(".part.meta")) {
                if (now - f.lastModified() > STALE_MS && f.delete()) removed++
                continue
            }
            if (!name.endsWith(".apk", ignoreCase = true)) continue

            val info = archiveInfo(context, f)
            val isOwn = info != null && info.first.isNotEmpty() && info.first == context.packageName
            val apkCode = info?.second ?: 0L

            // ② 本应用自己的更新包，且包内版本 ≤ 已装版本 → 这个包已经装过了，纯垃圾
            val ownAlreadyInstalled =
                isOwn && apkCode > 0L && installedCode > 0L && apkCode <= installedCode
            // ③ 放了三天还没被装掉 → 用户早已放弃这次更新（对所有包都成立）
            val stale = now - f.lastModified() > STALE_MS

            if (ownAlreadyInstalled || (ownOnly && isOwn) || stale) {
                if (f.delete()) removed++
            }
        }
        return removed
    }

    /** 当前已安装版本的 versionCode（取不到返回 0，调用方据此跳过判断）。 */
    @Suppress("DEPRECATION")
    fun installedVersionCode(context: Context): Long = try {
        val pi = context.packageManager.getPackageInfo(context.packageName, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pi.longVersionCode
        else pi.versionCode.toLong()
    } catch (_: Exception) {
        0L
    }

    /**
     * 读某个 apk 文件里记的 (packageName, versionCode)。
     * 读不出（文件不完整 / 不是合法 apk）返回 null —— 调用方必须容忍 null，
     * 因为下载中断留下的残包正是这种状态。
     */
    private fun archiveInfo(context: Context, f: File): Pair<String, Long>? = try {
        val pi = context.packageManager.getPackageArchiveInfo(f.absolutePath, PackageManager.GET_META_DATA)
        if (pi == null) {
            null
        } else {
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pi.longVersionCode else legacyCode(pi)
            Pair(pi.packageName ?: "", code)
        }
    } catch (_: Exception) {
        null
    }

    /** 低版本系统上取 versionCode 的兼容分支（单独抽出来，注解只作用在这一处）。 */
    @Suppress("DEPRECATION")
    private fun legacyCode(pi: android.content.pm.PackageInfo): Long = pi.versionCode.toLong()
}
