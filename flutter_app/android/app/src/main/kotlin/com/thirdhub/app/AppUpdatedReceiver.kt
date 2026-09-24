package com.thirdhub.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 「本应用已被新版覆盖安装」广播接收器 —— **「安装后删除安装包」的权威钩子**。
 *
 * 为什么必须是这个广播：更新包的删除时机只有一个可靠信号，就是**新版本真的装上了**。
 * 系统在覆盖安装成功后会把 `ACTION_MY_PACKAGE_REPLACED` 只发给本应用（其它应用收不到），
 * 这一刻：
 *  · 新版本已经在运行，之前下载的更新包再也没有用处；
 *  · 旧进程早已退出，文件不再被任何进程占用，删除一定成功
 *    —— 这正是「拉起安装器后立刻删」做不到的事（那时文件还被安装器等着读）。
 *
 * 传 `ownOnly = true`：此刻只清本应用自己的更新包。下载目录里可能还躺着用户
 * 刚下载、尚未安装的其它产品安装包（漫画稳定版等），那些不能一起删掉。
 */
class AppUpdatedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        UpdateApkJanitor.sweep(context, ownOnly = true)
    }
}
