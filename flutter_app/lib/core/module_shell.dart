// ═══════════════════════════════════════════════════════════════════════════
// 模块壳 —— R1⑤「模块即独立应用」的落点
//
// 用户原话（2026-09-27）：
//   「连软件的话滑动退出的时候我明明是要返回上一步，你就直接退出整个软件。」
//   「我这个软件他每一个模块都相当于一个独立的模块，就是一个独立的应用一样
//     的东西。也就是说他们里面还可以有他们独立的导航栏。你自己规划好。」
//
// 这一轮**换的不是功能，是拓扑**：以前 65 个模块共用一条根 Navigator，
// 于是"在模块里返回上一级"和"退出整个 App"在系统看来是同一件事 —— 都是
// 根路由的 pop。模块内部再深，系统层也只有一层栈，退到头就退 App。
//
// 现在每个模块拿到一条**属于自己的 Navigator 栈**（ModuleHost）：
//   系统按返回 → 先问这一层能不能 pop（回上一级）
//             → 到底了才问"要不要换模块/退 App"（RootNav 的 PopScope）
// 视觉效果**完全不变**：嵌套 Navigator 的第一条路由就是原来的 Scaffold
// （含 PageView 与底栏），模块内 push 出来的页面依旧是全屏覆盖（照旧盖住底栏）。
// 变的只有"返回"的语义 —— 这正是用户要的那件事。
//
// 三件事必须同时做才叫修好（缺一条就是"改了但没生效"，见笔记 R17 教训）：
//   ① ModuleHost    —— 每个模块一条独立 Navigator 栈（本文件）
//   ② RootNav 拦截  —— canPop:false + 先问嵌套栈、再问模块历史、最后才退 App
//   ③ ModuleBackHook —— 给"模块内部的非路由状态"（分段行/子标签）留一个返回钩子
//                     模块自己注册"我还有一级可以退"，不必改根导航
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';

/// 一个模块的宿主：给**当前模块**一条独立的 Navigator 栈。
///
/// 结构：
/// ```
///   PopScope(canPop:false, ...)        ← 注册在根路由上，拦住系统返回
///     └─ Navigator(key: navKey)        ← 模块自己的栈
///          └─ route#0 = Scaffold(PageView + 底栏)   ← 模块主页（原来的 RootNav 输出）
///             route#1..n = 模块内 push 的页面（全屏覆盖，与改造前一致）
/// ```
/// 因此 `Navigator.of(context).push(...)` 在模块内部自动落在**本模块**这一层，
/// 不需要逐个模块改造调用点 —— 这是"一处改动覆盖全部模块"的关键。
class ModuleHost extends StatelessWidget {
  /// 模块栈的 key。RootNav 用它做 `canPop()/pop()` 判定。
  final GlobalKey<NavigatorState> navKey;

  /// 模块主页（第一条路由的内容）。
  ///
  /// ★刻意做成「每个 build 传进来的当前 widget」，而不是 `WidgetBuilder`：
  /// Navigator 的 `onGenerateRoute` **只在路由被创建时调用一次**，用 builder
  /// 传进来的话，第二次 setState 重建时这条路由仍持有第一次那个 widget 实例
  /// —— 表现为"模块页面冻在打开那一刻，之后再点什么都不刷新"。
  /// 改成 `pages:`（声明式）之后，page 的 child 变了，路由就跟着更新，
  /// 而 `push` 出来的 pageless 路由（模块内子页面）语义完全不变。
  final Widget child;

  const ModuleHost({super.key, required this.navKey, required this.child});

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navKey,
      pages: <Page<dynamic>>[
        MaterialPage<dynamic>(
          key: const ValueKey<String>('__module_root__'),
          child: child,
        ),
      ],
      // 模块主页是这条栈的**底**，正常不会被移除（要退出模块得走根层 PopScope）。
      // 真被移除时什么都不做即可 —— 上面那一层会立刻把它重建回来。
      onDidRemovePage: (Page<dynamic> page) {},
    );
  }
}

/// 模块内部的「非路由」返回钩子。
///
/// 为什么需要它：模块深度并不总是由 Navigator 表达 —— 有很大一部分模块用
/// "分段行 / 子标签 / 内部页面切换"来表示"我在第几层"。那些状态系统看不见，
/// 于是"侧滑返回"到了它们身上就无从判断。
///
/// 用法（模块自己一行注册，不必改根导航）：
/// ```dart
/// ModuleBackHook.set('小说', () {
///   if (view != View.shelf) { setState(() => view = View.shelf); return true; }
///   return false;   // 我已经在模块首页了，交给上层决定
/// });
/// ```
/// 返回 true = 已消费这次返回；false = 交回根导航。
class ModuleBackHook {
  ModuleBackHook._();

  static final Map<String, bool Function()> _byModule = {};

  static void set(String moduleKey, bool Function() handler) {
    _byModule[moduleKey] = handler;
  }

  static void clear(String moduleKey) {
    _byModule.remove(moduleKey);
  }

  /// 问某个模块"你还能退一级吗"。没有注册过就返回 false。
  static bool tryBack(String moduleKey) {
    final h = _byModule[moduleKey];
    if (h == null) return false;
    try {
      return h();
    } catch (_) {
      return false;
    }
  }

  /// 仅用于自检/诊断：当前注册了钩子的模块名。
  static List<String> get registered => _byModule.keys.toList();
}

/// 模块级导航栏：一个模块**自己的**那一排入口。
///
/// 与底部"模块切换栏"是两件东西：
///   - 底栏 = 在 App 的模块之间跳（我的/搜索/小说/...）
///   - 本栏 = 在**当前模块内部**的子入口之间跳（总览/子功能A/子功能B...）
/// 这正是用户说的"他们里面还可以有他们独立的导航栏"。
///
/// 刻意做成横向可滚动而不是等分：一个模块的子入口可能 2 个，也可能 10 个
/// （工具箱就收纳了 10 个），等分会在 10 个时挤到不可读。
class ModuleNavBar extends StatelessWidget {
  /// 已本地化好的标签（调用方负责走 tr()）。
  final List<String> labels;
  final int index;

  /// 每个条目的图标（可空 —— 只有文字也成立）。
  final List<IconData?>? icons;
  final ValueChanged<int> onTap;
  final EdgeInsetsGeometry padding;

  const ModuleNavBar({
    super.key,
    required this.labels,
    required this.index,
    required this.onTap,
    this.icons,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border(
          bottom: BorderSide(color: accent.withValues(alpha: 0.14)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: i == index
                        ? accent.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: i == index
                            ? accent.withValues(alpha: 0.55)
                            : Colors.grey.withValues(alpha: 0.22)),
                  ),
                  child: Row(children: [
                    if (icons != null && i < icons!.length && icons![i] != null) ...[
                      Icon(icons![i],
                          size: 14, color: i == index ? accent : null),
                      const SizedBox(width: 5),
                    ],
                    Text(labels[i],
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight:
                                i == index ? FontWeight.w600 : FontWeight.w400,
                            color: i == index ? accent : null)),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
