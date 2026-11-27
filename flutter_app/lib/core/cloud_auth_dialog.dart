// ThirdHub 账号登录 / 注册弹窗（4.81.96 抽出统一实现）
//
// 为什么要抽成一处：原来只有「我的」页里那一份，账号中心、首启引导各自再写一遍，
// 三份必然漂移 —— 而这个项目已经吃过「改一处漏三处」的亏。
//
// ★和旧实现的三个关键差别（正是用户报「登录一大堆问题」的直接来源）：
//   ① 出错**不关窗**：密码打错时窗口留着、红字就地提示，用户直接改；
//      旧实现先关窗再弹 SnackBar，一条 3 秒就消失的提示，等于什么都没说。
//   ② 提交期间禁用按钮并显示转圈：旧实现点第二下会发第二次请求，
//      两次响应回来时先到的那个把 loading 关掉，看起来像「闪一下没反应」。
//   ③ 服务端英文错误码翻成人话（见 Cloud.friendlyAuthError）。
import 'package:flutter/material.dart';

import 'brand_orb.dart';
import 'cloud.dart';
import 'i18n.dart';

/// 弹出登录/注册。返回 true 表示这次操作后**确实登录上了**。
Future<bool> showCloudAuthDialog(BuildContext c, {bool isLogin = true}) async {
  final mailC = TextEditingController();
  final passC = TextEditingController();
  var loginMode = isLogin;
  var obscure = true;
  var busy = false;
  String? tip;
  String? notice;

  final ok = await showDialog<bool>(
    context: c,
    barrierDismissible: false,
    builder: (dCtx) => StatefulBuilder(
      builder: (dCtx2, setSt) {
        Future<void> submit() async {
          if (busy) return;
          final mail = mailC.text.trim();
          final pass = passC.text;
          if (!mail.contains('@') || mail.length < 5) {
            setSt(() => tip = tr('邮箱格式看起来不对'));
            return;
          }
          if (pass.length < 6) {
            setSt(() => tip = tr('密码至少 6 位'));
            return;
          }
          setSt(() {
            busy = true;
            tip = null;
          });
          try {
            if (loginMode) {
              await Cloud.signIn(mail, pass);
            } else {
              await Cloud.signUp(mail, pass);
            }
            // 注册后若要邮箱确认，Cloud 会把话放 lastNotice 并「不算登录成功」
            final n = Cloud.lastNotice;
            if (n.isNotEmpty) {
              setSt(() {
                busy = false;
                notice = n;
                loginMode = true; // 转成登录页，让用户确认完直接登
              });
              return;
            }
            if (dCtx2.mounted) Navigator.pop(dCtx2, true);
          } catch (e) {
            setSt(() {
              busy = false;
              tip = '$e'.replaceFirst('Exception: ', '');
            });
          }
        }

        return AlertDialog(
          title: Text(loginMode ? tr('登录 ThirdHub 账号') : tr('注册 ThirdHub 账号')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 品牌一致性（4.81.116）：登录弹窗与开屏用同一个立体商标，
              // 小尺寸关掉自转（弹窗里转圈会跟"正在登录"的转圈打架，读者分不清哪个是进度）。
              const Center(child: BrandOrb(size: 72, anim: false)),
              const SizedBox(height: 10),
              TextField(
                controller: mailC,
                autofocus: true,
                enabled: !busy,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (tip != null) setSt(() => tip = null);
                },
                decoration:
                    InputDecoration(labelText: tr('邮箱'), isDense: true),
              ),
              TextField(
                controller: passC,
                enabled: !busy,
                obscureText: obscure,
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (tip != null) setSt(() => tip = null);
                },
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: tr('密码(至少6位)'),
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: obscure ? tr('显示密码') : tr('隐藏密码'),
                    icon: Icon(
                        obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18),
                    onPressed: () => setSt(() => obscure = !obscure),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (tip != null && tip!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(tip!,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.redAccent)),
                ),
              if (notice != null && notice!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(notice!,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.orangeAccent)),
                ),
              Text(tr('前后端登录同一账号即可自动配对连接, 无需填地址'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final mail = mailC.text.trim();
                      if (!mail.contains('@') || mail.length < 5) {
                        setSt(() => tip = tr('请先填邮箱'));
                        return;
                      }
                      setSt(() {
                        busy = true;
                        tip = null;
                      });
                      try {
                        await Cloud.resetPassword(mail);
                        setSt(() {
                          busy = false;
                          notice = tr('重置邮件已发出，去邮箱点链接后回来登录');
                        });
                      } catch (e) {
                        setSt(() {
                          busy = false;
                          tip = '$e'.replaceFirst('Exception: ', '');
                        });
                      }
                    },
              child: Text(tr('忘记密码'), style: const TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setSt(() {
                        loginMode = !loginMode;
                        tip = null;
                        notice = null;
                      }),
              child: Text(loginMode ? tr('没有账号？去注册') : tr('已有账号？去登录')),
            ),
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dCtx2, false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: busy ? null : submit,
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(loginMode ? tr('登录') : tr('注册')),
            ),
          ],
        );
      },
    ),
  );

  mailC.dispose();
  passC.dispose();
  return ok == true;
}
