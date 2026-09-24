# Skill: interaction-design · ThirdHub 高级交互动效设计

> 收编日期：2026-09-24 · 来源：Advanced Interaction Design 模式库
> 接入方式：AI系统内置技能（技能注入体系第9个），用户输入 `@交互设计` 或描述界面交互需求时自动启用
> 维护规则：新增模式只追加进模式库清单，不改已有模式定义

---

## 作用

当用户描述一个APP/网页/小程序的界面交互时，先判断这个需求真正适合哪一种交互模式，再把需求整理成可以直接交给AI的实现指令（英文提示词）。

这不是一个视频制作Skill，也不是让AI随便给界面加动画。重点是判断：

- 变化从哪里发生；
- 用户的操作最后落在哪里；
- 哪些元素需要跟着变化；
- 周围内容是否需要主动让位；
- 动画结束后，用户应该看到什么结果。

## 使用规则

1. 先理解用户要完成的任务，再选择交互类型，不要看到"动画"两个字就直接添加通用淡入淡出。
2. 默认选择一个最匹配的主交互。如果一个需求确实包含多个交互，拆成主交互和辅助交互，并说明两者的关系。
3. 保留用户已有的视觉风格、组件结构和技术栈，不要改写无关页面。
4. 描述交互时必须写清楚触发方式、开始状态、变化过程、结束状态和失败或取消状态。
5. 需要实现代码时，再根据用户指定的技术栈输出代码；用户只要提示词时，不要擅自输出完整项目代码。
6. 所有 Copyable prompt 必须使用英文，方便用户直接复制给其他 AI。不要在英文提示词中混入中文。
7. 不要把"更高级""更有质感""更顺滑"当作完整需求，必须翻译成具体的状态变化、位置变化、尺寸变化或反馈方式。
8. 如果关键信息缺失但仍能合理判断，先做一个明确假设并继续，不要连续追问。

## 判断方法

先用下面四个问题定位需求：

| 判断问题 | 重点关注的交互 |
|----------|----------------|
| 变化应该从哪里开始？ | Radial Theme Transition、Drag-to-Reorder、Fan Menu Expansion（扇形菜单展开） |
| 操作最后应该停在哪里？ | Staggered Bulk Selection、Velocity-Based Slider Snap |
| 这次变化需要谁跟着回应？ | Spring Stepper Progress、Ripple Feedback for Related Switches |
| 周围内容要不要一起让位？ | Curved Card Deletion、Stacked Card Scroll、Expanding Tag Selection、Cross-Module Drag（跨模块拖拽） |

如果是内容本身从隐藏变为显示，优先检查 Animated Text Disclosure。

---

## 模式库（13种）

### 1. Radial Theme Transition | 圆形主题切换

**适用场景**：用户点击主题切换按钮，需要从浅色模式切换到深色模式，或在两套完整页面之间切换。

**必须保留**：以真实点击或触摸位置为圆心；圆的半径覆盖到最远的屏幕角落；两套页面保持相同尺寸和位置；只裁切上层页面，不缩放页面内容。

```
Implement a radial theme transition for an app interface. When the user presses the theme toggle, reveal the new theme from the exact pointer or touch position as the center of an expanding circle. Calculate the circle radius based on the distance from the touch point to the farthest viewport corner. Keep both theme layers at the same scale and position, and clip only the top layer with a circular mask instead of scaling the page. Support mouse and touch input, respect prefers-reduced-motion, and use a simple fallback transition when needed.
```

### 2. Drag-to-Reorder | 拖拽排序

**适用场景**：用户拖动列表、卡片或任务项，重新决定它们的顺序。

**必须保留**：拖动项暂时脱离普通列表流；每一帧重新计算落点索引；其他项目形成明确的空槽；每一项独立追赶新位置；用户中途停下时，布局也停在当前状态。

```
Create a draggable sortable list. When the user holds and drags one row, temporarily remove it from the normal list flow and calculate the insertion index continuously from the pointer position. The other rows should create a visible empty slot and move out of the way. Animate each row independently with a spring motion so the layout feels soft and staggered. Keep the dragged item attached to the pointer, prevent layout jumps, and support both touch and keyboard interactions.
```

### 3. Staggered Bulk Selection | 批量勾选

**适用场景**：用户点击全选或批量操作，需要让多条内容依次进入选中状态。

**必须保留**：状态可以立即更新，但视觉反馈从第一项开始错峰执行；每个勾选出现时有轻微弹性放大；不能让动画阻塞用户继续操作。

```
Implement a select-all interaction for a list of four items. When the user activates select all, update the selection state immediately but animate the checkmarks one by one with a short staggered delay from the first item to the last. Add a subtle elastic scale effect when each checkmark appears, then return each item to its normal size. Make the sequence feel deliberate without slowing down the actual state update, and support keyboard and screen-reader accessibility.
```

### 4. Velocity-Based Slider Snap | 滑杆惯性吸附

**适用场景**：用户拖动带有刻度的滑杆选择数值、档位或目标值。

**必须保留**：记录释放速度；松手后允许滑块短距离过冲；再通过弹簧回到最近的有效刻度；最终值必须被限制在合法范围内。

```
Create a stepped slider for selecting a target value. Track the pointer velocity while the user drags. When the user releases the slider, let the thumb continue slightly past the release point based on the release velocity, then use a spring animation to pull it back to the nearest valid tick. Clamp the final value to the available range, make the overshoot subtle, and support mouse, touch, keyboard control, and reduced-motion preferences.
```

### 5. Animated Text Disclosure | 文本展开

**适用场景**：一段说明文字、详情内容或帮助信息需要在折叠和展开之间切换。

**必须保留**：根据真实内容高度调整容器；从当前高度连续过渡到目标高度；箭头或图标旋转180度；不能让文字突然出现或造成布局跳动。

```
Create an animated text disclosure component for a collapsible description. When the user opens it, measure the real content height and animate the container from its current height to the measured height instead of suddenly revealing the text. When it closes, animate back to the collapsed height. Rotate the trailing chevron by 180 degrees to represent the two states, keep the content accessible to screen readers, and avoid layout jumps.
```

### 6. Spring Stepper Progress | 步骤条回弹

**适用场景**：用户完成表单、购买或设置流程中的一个步骤，需要推进到下一步。

**必须保留**：进度段先略微超过目标位置，再回弹到准确位置；完成、当前和未完成状态要清晰区分；动画不能改变真实步骤状态。

```
Create a multi-step progress indicator. When the user completes a step, animate the next progress segment so it slightly overshoots its target and then settles back with a soft spring motion. Update the completed, current, and upcoming states clearly, keep the progress value accurate throughout the animation, and make the transition feel responsive without delaying navigation. Support keyboard accessibility and prefers-reduced-motion.
```

### 7. Ripple Feedback for Related Switches | 开关联动反馈

**适用场景**：一组相互关联的设置中，用户切换其中一个开关，需要提醒用户它属于同一组设置。

**必须保留**：当前开关正常改变状态；邻近开关只产生轻微震动或涟漪反馈；邻近开关的真实开关状态不能被改变。

```
Create a settings group with multiple toggle switches. When the user changes one switch, trigger a subtle ripple-like feedback effect that spreads to the neighboring switches. The neighboring switches may slightly shake or translate, but their actual on and off states must not change. The source switch should update normally, while the ripple remains purely visual feedback. Keep the effect contained within the group, support touch and keyboard input, and disable the motion for reduced-motion users.
```

### 8. Curved Card Deletion | 卡片曲线删除

**适用场景**：用户滑动删除卡片、消息或任务，希望让删除动作有明确的去向。

**必须保留**：卡片沿曲线路径移动到删除图标或回收区域；移动过程中逐渐缩小、旋转和变淡；未达到删除阈值时可以取消并回到原位；动画结束后再从数据源移除。

```
Create a swipe-to-delete card interaction. When the user swipes a card past the delete threshold, animate the card along a curved path toward the delete icon or trash area. While moving, gradually reduce its scale, rotate it slightly, and fade its opacity. Remove the card from the data source after the exit animation completes. If the user releases before the threshold, smoothly return the card to its original position. Support touch, mouse, keyboard deletion, and reduced-motion preferences.
```

### 9. Stacked Card Scroll | 卡片堆叠滚动

**适用场景**：用户滚动一组有顺序的卡片、记录或历史内容，需要保留已经看过内容的空间线索。

**必须保留**：顶部卡片到达边界后暂时固定；后续卡片向上移动并把前面的卡片压成一摞；压缩程度、缩放和层级根据后方卡片数量变化；内容不能突然消失。

```
Create a vertically scrollable card stack. When the top card reaches the top boundary, keep it pinned temporarily while the cards behind it move upward and compress into a visible stack. Calculate each card's vertical offset, scale, and depth based on how many cards are behind it. The more cards that move forward, the deeper and smaller the previous cards should become. Preserve the user's scroll context, avoid abrupt disappearance, and support touch, mouse wheel, and keyboard scrolling.
```

### 10. Expanding Tag Selection | 标签挤开

**适用场景**：用户从一行标签、筛选项或分类项中选择一个选项，需要突出当前选择。

**必须保留**：当前标签稍微放大；邻近标签平滑向两侧让位；元素不能互相重叠或突然跳动；小屏幕下要正确处理换行。

```
Create a selectable tag list with animated layout reflow. When the user selects a tag, slightly enlarge the active tag and make the neighboring tags move aside to create enough space. The surrounding tags should smoothly translate rather than overlap or jump. Clearly show the selected state, preserve the original order of the tags, handle wrapping on smaller screens, and support mouse, touch, keyboard navigation, and reduced-motion preferences.
```

### 11. Fan Menu Expansion | 悬浮球扇形展开（ThirdHub专属）

**适用场景**：用户点击右下角悬浮球，需要展开模块菜单（扇形/圆形排列），再次点击或点遮罩收起。

**必须保留**：菜单项从球心沿弧线弹出（错峰、带弹簧回弹）；当前所在模块图标高亮；背景加半透明遮罩，点击遮罩收起；长按球可拖动换位、松手吸附边缘；键盘弹出时球自动上移；动画结束后焦点的第一项可被键盘/手柄选中。

```
Implement a floating action ball in the bottom corner of a mobile app. When the user taps it, expand a fan-shaped radial menu from the ball center with staggered item pop-in and spring overshoot. Highlight the icon of the currently active module. Add a semi-transparent backdrop; tapping the backdrop collapses the menu. Long-pressing the ball allows drag repositioning, snapping to screen edges on release. When the keyboard opens, move the ball upward to avoid occlusion. After the menu animation completes, make the first item focusable for keyboard or remote control navigation. Respect prefers-reduced-motion with an instant fallback.
```

### 12. Reader Page Curl | 阅读器仿真翻页（ThirdHub专属）

**适用场景**：小说阅读器中用户点击/滑动翻页，需要纸张卷曲仿真动画（覆盖模式）。

**必须保留**：以触摸点为折痕锚点；翻起页背面显示浅色背面+轻微阴影；角度跟随手指连续变化；松手后根据位置决定完成翻页或回弹；平移模式下降级为滑动+阴影过渡；动画不得改变真实章节位置，翻页完成才更新阅读进度。

```
Implement a realistic page-curl page turn for a novel reader in overlay mode. Use the touch point as the fold anchor and render the lifted page with a light-colored back face, soft shadows, and a continuous angle following the finger. On release, complete the turn or spring back based on pointer position. In scroll mode, degrade to a slide transition with shadow. The animation must never change the real chapter position; only update reading progress after the turn completes. Support tap zones, horizontal swipe, and prefers-reduced-motion.
```

### 13. Cross-Module Drag | 卡片跨模块拖拽（ThirdHub专属）

**适用场景**：用户把书籍/音乐卡片从书架拖到分类文件夹、或拖入下载队列（跨模块移动）。

**必须保留**：拖动全程卡片悬浮跟随手指（缩放1.05+阴影）；经过可接收目标时目标高亮并轻微扩大；松手后卡片沿短曲线路径飞入目标容器；源列表和目标列表同步更新（先动画后数据）；不可接收的目标不响应；取消时弹簧回原位。

```
Implement a cross-module drag interaction. While dragging a card (book, song, or comic), keep it floating under the pointer with a slight scale-up and elevated shadow. Highlight and gently enlarge any valid drop target as the card passes over it; invalid targets give no response. On release, animate the card along a short curved path into the target container, then update both the source and target lists after the animation completes. If the user cancels, spring the card back to its origin. Support touch, mouse, keyboard move operations, and prefers-reduced-motion.
```

---

## 输出格式

当用户描述一个具体界面需求时，按下面格式回答：

### Selected interaction
写出最合适的英文名称和中文名称。

### Why it fits
用简短中文说明它解决的是"从哪里发生""落在哪里""谁跟着变化"还是"周围是否让位"。

### Interaction behavior
用中文说明触发方式、开始状态、变化过程、最终状态、取消或失败状态，以及移动端需要注意的触控区域。

### Copyable prompt
只输出一段英文提示词。提示词必须包含：
- 具体组件或界面对象；
- 触发方式；
- 开始状态和结束状态；
- 位移、尺寸、透明度、裁切、弹簧或过冲等具体变化；
- 数据状态和视觉状态之间的关系；
- 响应式、键盘、触控和reduced-motion要求；
- 不要改写无关组件。

```
Use the selected interaction pattern in my existing interface. Preserve the current visual style, layout language, and component structure. Do not rewrite unrelated components. Implement the trigger, state changes, start and end states, motion behavior, responsive behavior, keyboard accessibility, touch support, and reduced-motion fallback described below:

[Insert the selected English interaction prompt here]
```

## 不要这样回答

- 不要只说"加一个高级动画"。
- 不要把13种模式全部混在一起输出。
- 不要把视觉反馈误写成真实功能变化，例如让邻近开关跟着改变状态。
- 不要用固定时长掩盖没有定义开始状态和结束状态的问题。
- 不要输出视频剪辑、配音、字幕或视频制作流程。
- 不要生成中英文双栏提示词图；需要图片时，只提供适合做信息浓缩图的结构和文案。
