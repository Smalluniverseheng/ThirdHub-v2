// 通用对话框工具（2026-10-12）—— 危险操作确认的**统一规范**。
//
// 为什么单独一个文件：删除 / 清空 / 取消订阅这类**不可逆或影响面大**的操作，
// 此前各页的确认框各写各的（标题叫「确认」、按钮是蓝色主色）。
// 统一成：**红色主按钮 + 危险图标 + 后果写在正文**——让"误触成本"可感知。
// 轻微/可撤销的操作不要用这个（那会训练用户"见红就点"）。
library;

import 'package:flutter/material.dart';

/// 危险操作确认（删除 / 清空类）。
/// 返回 true = 用户确认；false / null = 取消。
Future<bool> confirmDanger(
  BuildContext c, {
  required String title,
  required String content,
  String okLabel = '删除',
  String cancelLabel = '取消',
}) async {
  final r = await showDialog<bool>(
      context: c,
      builder: (c2) => AlertDialog(
              icon: const Icon(Icons.warning_amber_rounded,
                  color: Colors.redAccent, size: 28),
              title: Text(title),
              content: Text(content),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c2, false),
                    child: Text(cancelLabel)),
                FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent),
                    onPressed: () => Navigator.pop(c2, true),
                    child: Text(okLabel)),
              ]));
  return r ?? false;
}
