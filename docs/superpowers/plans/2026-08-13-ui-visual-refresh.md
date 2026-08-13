# UI 视觉焕新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按已批准的 spec 完成暗色主题提亮（深海蓝调）、圆角柔化与 6 处微动效，零新依赖。

**Architecture:** 所有色值与圆角集中在 `app_theme.dart`；三个通用动画 widget（`HoverLift`/`PressScale`/`AppearIn`）放 `lib/core/widgets/`，页面只做薄接入；全局页面过渡通过 `PageTransitionsTheme` 一次性生效。

**Tech Stack:** Flutter 内置动画（AnimatedSwitcher / TweenAnimationBuilder / AnimatedContainer / AnimationController），不引入任何包。

**Spec:** `docs/superpowers/specs/2026-08-13-ui-visual-refresh-design.md`

---

### Task 1: 方案 A 配色替换

**Files:**
- Modify: `apps/client_flutter/lib/core/theme/app_theme.dart:4-15`
- Modify: `DESIGN.md:6-20`

- [ ] **Step 1: 替换 AppColors 十二个色值**

将 `apps/client_flutter/lib/core/theme/app_theme.dart` 中 `AppColors` 类整体替换为：

```dart
abstract final class AppColors {
  static const canvas = Color(0xFF0F1722);
  static const surface = Color(0xFF16202D);
  static const surfaceRaised = Color(0xFF1E2B3B);
  static const surfaceInteractive = Color(0xFF26384E);
  static const border = Color(0xFF2E435C);
  static const text = Color(0xFFF2F7FB);
  static const muted = Color(0xFF93A8BD);
  static const accent = Color(0xFF4AD4C0);
  static const accentInk = Color(0xFF052422);
  static const info = Color(0xFF6FB6FF);
  static const warning = Color(0xFFF5C56B);
  static const danger = Color(0xFFFF8B84);
}
```

- [ ] **Step 2: 同步 DESIGN.md colors 段**

将 `DESIGN.md` 顶部 frontmatter 的 `colors:` 块替换为：

```yaml
colors:
  canvas: '#0F1722'
  surface: '#16202D'
  surfaceRaised: '#1E2B3B'
  surfaceInteractive: '#26384E'
  border: '#2E435C'
  text: '#F2F7FB'
  muted: '#93A8BD'
  accent: '#4AD4C0'
  accentInk: '#052422'
  info: '#6FB6FF'
  warning: '#F5C56B'
  danger: '#FF8B84'
```

- [ ] **Step 3: 验证**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

Run: `cd apps/client_flutter && flutter test`
Expected: `All tests passed!`

- [ ] **Step 4: 提交**

```powershell
cd D:\self\training-book
git add apps/client_flutter/lib/core/theme/app_theme.dart DESIGN.md
git commit -m "ui: apply deep-blue palette (spec plan A)"
```

---

### Task 2: 圆角系统柔化

**Files:**
- Modify: `apps/client_flutter/lib/core/theme/app_theme.dart:47-80`
- Modify: `apps/client_flutter/lib/features/workout/presentation/workout_session_page.dart:347`
- Modify: `DESIGN.md:21-24`

- [ ] **Step 1: 主题层圆角调整**

在 `app_theme.dart` 的 `AppTheme.dark()` 中：

1. `cardTheme` 的 `borderRadius` 改为 `BorderRadius.all(Radius.circular(16))`；
2. 两处 `inputDecorationTheme` 的 `borderRadius` 改为 `BorderRadius.circular(12)`；
3. `filledButtonTheme` 的 `shape` 改为 `RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))`；
4. 两个导航主题的 `indicatorShape` 改为圆角 12：

`navigationRailTheme` 与 `navigationBarTheme` 两块替换为：

```dart
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.surfaceInteractive,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.surfaceInteractive,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
```

5. 在 `navigationBarTheme` 块之后追加 `bottomSheetTheme` 与 `chipTheme`：

```dart
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      chipTheme: const ChipThemeData(
        shape: StadiumBorder(),
        side: BorderSide(color: AppColors.border),
      ),
```

- [ ] **Step 2: 训练页组记录大卡片 radius 20**

`workout_session_page.dart` 中 `_WorkoutSessionPageState.build` 的组列表面板 Card（约 347 行 `Card(child: Padding(...`，其下是 `_SetRow` 循环）改为：

```dart
                  Card(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                      side: const BorderSide(color: AppColors.border),
                    ),
                    child: Padding(
```

注意保留原有 `child: Padding(padding: const EdgeInsets.all(18), ...` 内容不变，只替换 `Card(` 这一层。

- [ ] **Step 3: DESIGN.md radii 段**

`DESIGN.md` frontmatter 的 `radii:` 替换为：

```yaml
radii:
  small: 12
  medium: 16
  large: 20
  xlarge: 24
```

- [ ] **Step 4: 验证与提交**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

Run: `cd apps/client_flutter && flutter test`
Expected: `All tests passed!`

```powershell
cd D:\self\training-book
git add apps/client_flutter/lib/core/theme/app_theme.dart apps/client_flutter/lib/features/workout/presentation/workout_session_page.dart DESIGN.md
git commit -m "ui: soften corner radii (cards 16, controls 12, workout panel 20)"
```

---

### Task 3: 动效常量 + 全局页面过渡

**Files:**
- Modify: `apps/client_flutter/lib/core/theme/app_theme.dart`（追加 AppMotion 与 pageTransitionsTheme）

- [ ] **Step 1: 追加 AppMotion 常量与过渡构建器**

在 `app_theme.dart` 的 `AppTheme` 类之前插入：

```dart
/// Motion vocabulary: short, ease-out, state-change only.
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 280);
  static const easeOut = Curves.easeOutCubic;
}

/// Fade + slight upward slide for every MaterialPageRoute.
class _FadeSlideTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeSlideTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: AppMotion.easeOut);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
```

- [ ] **Step 2: 挂入主题**

在 `AppTheme.dark()` 返回的 `ThemeData(...)` 参数中（`useMaterial3: true,` 之后）加入：

```dart
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.windows: _FadeSlideTransitionsBuilder(),
        TargetPlatform.iOS: _FadeSlideTransitionsBuilder(),
        TargetPlatform.macOS: _FadeSlideTransitionsBuilder(),
      }),
```

- [ ] **Step 3: 验证与提交**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

Run: `cd apps/client_flutter && flutter test`
Expected: `All tests passed!`

```powershell
cd D:\self\training-book
git add apps/client_flutter/lib/core/theme/app_theme.dart
git commit -m "ui: motion constants and fade-slide page transitions"
```

---

### Task 4: 三个通用动效 widget

**Files:**
- Create: `apps/client_flutter/lib/core/widgets/hover_lift.dart`
- Create: `apps/client_flutter/lib/core/widgets/press_scale.dart`
- Create: `apps/client_flutter/lib/core/widgets/appear_in.dart`

- [ ] **Step 1: HoverLift（桌面悬停上浮 + 边框提亮，可注入 border 色）**

```dart
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Desktop hover feedback: lifts the child 2px and exposes the hovered
/// state so callers can brighten the card border.  No-op on touch devices.
class HoverLift extends StatefulWidget {
  const HoverLift({super.key, required this.builder});
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.easeOut,
      transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
      child: widget.builder(context, _hovered),
    ),
  );
}

/// Border color for a hoverable card: accent-tinted while hovered.
Color hoverBorder(bool hovered) =>
    hovered ? AppColors.accent.withValues(alpha: 0.45) : AppColors.border;
```

- [ ] **Step 2: PressScale（按下缩放回弹）**

```dart
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Scales the child to 0.97 while pressed; wraps primary CTAs.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child});
  final Widget child;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => setState(() => _pressed = true),
    onPointerUp: (_) => setState(() => _pressed = false),
    onPointerCancel: (_) => setState(() => _pressed = false),
    child: AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: AppMotion.fast,
      curve: AppMotion.easeOut,
      child: widget.child,
    ),
  );
}
```

- [ ] **Step 3: AppearIn（首次出现淡入 + 上滑 8px，仅播一次）**

```dart
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Plays a one-shot fade + 8px slide-up when the widget first appears.
/// State is kept across rebuilds, so scrolling back and forth does not
/// replay the entrance.
class AppearIn extends StatefulWidget {
  const AppearIn({super.key, this.delay = Duration.zero, required this.child});
  final Duration delay;
  final Widget child;

  @override
  State<AppearIn> createState() => _AppearInState();
}

class _AppearInState extends State<AppearIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
  )..forward();
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: AppMotion.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    if (widget.delay > Duration.zero) {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: SlideTransition(position: _slide, child: widget.child),
  );
}
```

- [ ] **Step 4: 验证与提交**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

```powershell
cd D:\self\training-book
git add apps/client_flutter/lib/core/widgets
git commit -m "ui: add HoverLift, PressScale and AppearIn motion widgets"
```

---

### Task 5: 训练页动效接入

**Files:**
- Modify: `apps/client_flutter/lib/features/workout/presentation/workout_session_page.dart`

- [ ] **Step 1: 对勾完成弹入（AnimatedSwitcher）**

`_SetRow.build` 中 IconButton 的 `icon` 参数（约 484 行）替换为：

```dart
      icon: saving
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : AnimatedSwitcher(
              duration: AppMotion.fast,
              transitionBuilder: (child, animation) => ScaleTransition(scale: CurvedAnimation(parent: animation, curve: AppMotion.easeOut), child: child),
              child: Icon(
                entry.done ? Icons.check_circle : Icons.check_circle_outline,
                key: ValueKey(entry.done),
                color: entry.done ? AppColors.accent : null,
              ),
            ),
```

- [ ] **Step 2: 顶部进度条平滑滚动**

`build` 方法顶部（约 305 行）的 `LinearProgressIndicator(value: _totalSets == 0 ? 0 : _completedSets / _totalSets, minHeight: 7, ...)` 替换为：

```dart
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: _totalSets == 0 ? 0 : _completedSets / _totalSets),
                          duration: AppMotion.slow,
                          curve: AppMotion.easeOut,
                          builder: (context, value, _) => LinearProgressIndicator(
                            value: value,
                            minHeight: 7,
                            backgroundColor: AppColors.surfaceInteractive,
                          ),
                        ),
```

原 `ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(...))` 的外层 ClipRRect 保留，只替换其 child。

- [ ] **Step 3: "完成训练"按钮按压缩放**

`build` 中 `bottomSheet` 的 `FilledButton.icon(...)` 外包一层：

```dart
        child: PressScale(
          child: FilledButton.icon(
            onPressed: _isCompleting ? null : _complete,
            icon: _isCompleting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check_circle_outline),
            label: const Text('完成训练'),
          ),
        ),
```

（`SizedBox(width: double.infinity, child: ...)` 外层保留。）

同时在文件头部 import 区（`import '../../../core/theme/app_theme.dart';` 之后）加入：

```dart
import '../../../core/widgets/press_scale.dart';
```

- [ ] **Step 4: 验证与提交**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

Run: `cd apps/client_flutter && flutter test`
Expected: `All tests passed!`

```powershell
cd D:\self\training-book
git add apps/client_flutter/lib/features/workout/presentation/workout_session_page.dart
git commit -m "ui: workout page check-in pop, smooth progress, press-scaled CTA"
```

---

### Task 6: 今日页与进度页接入

**Files:**
- Modify: `apps/client_flutter/lib/features/today/presentation/today_page.dart`
- Modify: `apps/client_flutter/lib/features/progress/presentation/progress_page.dart`

- [ ] **Step 1: 今日页主卡片——AppearIn + HoverLift + 按钮缩放**

`today_page.dart` import 区加：

```dart
import '../../../core/widgets/appear_in.dart';
import '../../../core/widgets/hover_lift.dart';
import '../../../core/widgets/press_scale.dart';
```

`_TodayPageState.build` 中 `FutureBuilder` 的 builder（当前代码约 42-55 行）整段替换。原文是：

```dart
      FutureBuilder<Map<String, dynamic>?>(future: _active, builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Card(child: Padding(padding: EdgeInsets.all(24), child: LinearProgressIndicator()));
        final workout = snapshot.data;
        if (workout == null) return _StartCard(onOpenPlans: widget.onOpenPlans);
        final name = (workout['plan_name'] as String?)?.trim();
        return Card(color: AppColors.surfaceRaised, child: Padding(padding: const EdgeInsets.all(24), child: Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.play_arrow_rounded, color: AppColors.accentInk)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name?.isNotEmpty == true ? name! : '正在进行的训练', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 4), const Text('继续完成，或明确放弃本次训练', style: TextStyle(color: AppColors.muted))])),
          TextButton(onPressed: () => _abandon(workout), child: const Text('放弃')),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => _resume(workout), child: const Text('继续训练')),
        ])));
      }),
```

替换为：

```dart
      FutureBuilder<Map<String, dynamic>?>(future: _active, builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Card(child: Padding(padding: EdgeInsets.all(24), child: LinearProgressIndicator()));
        final workout = snapshot.data;
        if (workout == null) return AppearIn(child: _StartCard(onOpenPlans: widget.onOpenPlans));
        final name = (workout['plan_name'] as String?)?.trim();
        return AppearIn(
          child: HoverLift(
            builder: (context, hovered) => Card(
              color: AppColors.surfaceRaised,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: hoverBorder(hovered)),
              ),
              child: Padding(padding: const EdgeInsets.all(24), child: Row(children: [
                Container(width: 42, height: 42, decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.play_arrow_rounded, color: AppColors.accentInk)),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name?.isNotEmpty == true ? name! : '正在进行的训练', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), const SizedBox(height: 4), const Text('继续完成，或明确放弃本次训练', style: TextStyle(color: AppColors.muted))])),
                TextButton(onPressed: () => _abandon(workout), child: const Text('放弃')),
                const SizedBox(width: 8),
                PressScale(child: FilledButton(onPressed: () => _resume(workout), child: const Text('继续训练'))),
              ]))),
            ),
          ),
        );
      }),
```

`_StartCard.build`（当前约 64-65 行）整段替换。原文是：

```dart
  @override
  Widget build(BuildContext context) => Card(color: AppColors.surfaceRaised, child: Padding(padding: const EdgeInsets.all(24), child: Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.play_arrow_rounded, color: AppColors.accentInk)), const SizedBox(width: 16), const Expanded(child: Text('选择一份训练计划开始', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))), FilledButton(onPressed: onOpenPlans, child: const Text('训练计划'))])));
```

替换为：

```dart
  @override
  Widget build(BuildContext context) => HoverLift(
    builder: (context, hovered) => Card(
      color: AppColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: hoverBorder(hovered)),
      ),
      child: Padding(padding: const EdgeInsets.all(24), child: Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.play_arrow_rounded, color: AppColors.accentInk)), const SizedBox(width: 16), const Expanded(child: Text('选择一份训练计划开始', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))), PressScale(child: FilledButton(onPressed: onOpenPlans, child: const Text('训练计划')))]))),
    ),
  );
```

- [ ] **Step 2: 进度页训练卡片——AppearIn + HoverLift**

`progress_page.dart` import 区加：

```dart
import '../../../core/widgets/appear_in.dart';
import '../../../core/widgets/hover_lift.dart';
```

`_TrainingCard.build` 改为：

```dart
  @override
  Widget build(BuildContext context) {
    final name = (entry['plan_name'] as String?)?.trim();
    final date = _date(entry);
    return AppearIn(
      child: HoverLift(
        builder: (context, hovered) => Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: hoverBorder(hovered)),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                ...原 Icon/文字/箭头不变...
              ]),
            ),
          ),
        ),
      ),
    );
  }
```

- [ ] **Step 3: 验证与提交**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

Run: `cd apps/client_flutter && flutter test`
Expected: `All tests passed!`

```powershell
cd D:\self\training-book
git add apps/client_flutter/lib/features/today/presentation/today_page.dart apps/client_flutter/lib/features/progress/presentation/progress_page.dart
git commit -m "ui: today and progress pages get hover lift, entrance and press feedback"
```

---

### Task 7: 计划页与动作库页接入 + DESIGN.md 动效段

**Files:**
- Modify: `apps/client_flutter/lib/features/plans/presentation/plans_page.dart`
- Modify: `apps/client_flutter/lib/features/library/presentation/library_page.dart`
- Modify: `DESIGN.md`

- [ ] **Step 1: 计划页卡片**

`plans_page.dart` import 区加：

```dart
import '../../../core/widgets/appear_in.dart';
import '../../../core/widgets/hover_lift.dart';
```

`_PlanCard.build`（约 162 行，`return Card( ... child: InkWell(onTap: onOpen, ...))`）改为 HoverLift + 显式 shape（radius 16、hover 边框提亮），整卡外包 AppearIn：

```dart
  @override
  Widget build(BuildContext context) => AppearIn(
    child: HoverLift(
      builder: (context, hovered) => Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: hoverBorder(hovered)),
        ),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(16),
          child: ...原 Padding/内容不变...,
        ),
      ),
    ),
  );
```

页面其余 `Card(`（空状态卡等）保持全局主题样式不变。

- [ ] **Step 2: 动作库页卡片**

`library_page.dart` import 区加：

```dart
import '../../../core/widgets/appear_in.dart';
import '../../../core/widgets/hover_lift.dart';
```

`_ExerciseCard.build`（约 339 行 `return Card( ... child: InkWell(...))`）按 Step 1 同样模式改造：AppearIn + HoverLift + radius 16 显式 shape + hover 边框。

- [ ] **Step 3: DESIGN.md 追加动效段**

在 `DESIGN.md` 的 "## Components" 之前插入：

```markdown
## Motion

Interaction feedback only: 150-280ms, ease-out, no ambient looping animation.
Page changes fade with a subtle rise; desktop cards lift 2px with a tinted
border on hover; primary buttons scale to 0.97 while pressed; completion
checks pop in; progress bars roll smoothly; list entries fade in once.
```

- [ ] **Step 4: 验证与提交**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

Run: `cd apps/client_flutter && flutter test`
Expected: `All tests passed!`

```powershell
cd D:\self\training-book
git add apps/client_flutter/lib/features/plans/presentation/plans_page.dart apps/client_flutter/lib/features/library/presentation/library_page.dart DESIGN.md
git commit -m "ui: plans and library card hover + entrance, document motion language"
```

---

### Task 8: 全量验证与推送

- [ ] **Step 1: 最终验证**

Run: `cd apps/client_flutter && flutter --no-version-check analyze`
Expected: `No issues found!`

Run: `cd apps/client_flutter && flutter test`
Expected: `All tests passed!`

Run: `cd D:\self\training-book && git diff --cached --stat`（确认无意外文件）

- [ ] **Step 2: 推送**

```powershell
cd D:\self\training-book
git push origin main
```

Expected: 推送成功（SSH remote，无需登录）。

- [ ] **Step 3: 真机目测清单（用户执行）**

在 Windows 上运行 app 后确认：
1. 底色明显偏蓝、卡片层次清楚，不再灰闷；
2. 训练页大卡片圆角 20、按钮/输入框 12、chip 全圆；
3. 页面切换有轻微淡入上滑；完成一组对勾有弹入感；进度条平滑；
4. 桌面鼠标悬停卡片有上浮 + 青边；按主按钮有回弹；
5. 无闪烁、无卡顿、无布局错位。
