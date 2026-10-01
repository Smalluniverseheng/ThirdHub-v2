# 开源 TTS 引擎接入协议（TTS/1）

> 面向"**你自己跑一个开源语音合成服务，ThirdHub 直接连它**"这一条路。
> 与既有的三条听书通道**并存不替代**：
> `system`（系统 TTS）／`online:<provider>`（OpenAI 兼容厂商）／`backend`（家庭后端 `/v1/tts`）。
> 本协议描述的是第 4 条：`opensource`。
>
> 相关实现：`flutter_app/lib/core/tts_direct.dart`（客户端）、
> `flutter_app/lib/core/tts_engines_logic.dart`（契约解析，零 Flutter 依赖）、
> `flutter_app/lib/core/tts_engines_page.dart`（引导页）。
> 自检：`flutter_app/tool/tts_engines_selfcheck.dart`

---

## 1. 三条底线

1. **不内置、不分发任何模型与音频**。本协议只定义"怎么连"，引擎与音色由用户自行获取。
   仓内**没有任何**语音模型的下载地址被硬编码进安装包（只有项目主页 URL，供用户自己去下载）。
2. **流量只到用户自己指定的主机**。不经过本项目、不经过家庭后端（走 `opensource` 渠道时）。
3. **认不出就是认不出**。服务端返回的东西不符合本协议时，客户端必须报出**具体哪一项**不符，
   不许"看起来像就成了"。历史上"能连上但其实连错了东西"是本项目反复踩的坑
   （引擎 `:1234` 与资源库 `:9527` 被混为一谈）。

---

## 2. 端点

服务端只需实现两个端点。**均为 HTTP**（局域网明文；要上公网请自行套 TLS 反代）。

### 2.1 `GET /health` — 能力声明

成功响应 `200` + JSON：

```json
{
  "ok": true,
  "name": "Piper 本地服务",
  "engine": "piper",
  "protocol": "tts/1",
  "sample_rate": 22050,
  "voices": ["zh_CN-huayan-medium", "en_US-amy-low"],
  "default_voice": "zh_CN-huayan-medium",
  "formats": ["wav", "mp3"]
}
```

必填与语义：

| 字段 | 必填 | 语义 | 不合格的后果 |
|---|---|---|---|
| `ok` | ✅ | 必须为 `true` | 视为不兼容 |
| `protocol` | ✅ | 必须为 `"tts/1"` | 视为不兼容（**这是唯一不会误判的那一项**） |
| `engine` | ✅ | 引擎标识，小写 ASCII | 只用于显示 |
| `name` | 可选 | 展示名 | 缺省用 `engine` |
| `sample_rate` | 可选 | 采样率，Hz | 仅用于显示 |
| `voices` | 可选 | 可用音色 id 列表 | 缺省表示"由服务端自行决定" |
| `default_voice` | 可选 | 默认音色 | 缺省取 `voices[0]` |
| `formats` | 可选 | 支持输出格式，按优先级 | 缺省 `["wav"]` |

**为什么把 `protocol` 设为必填**：只看 `ok: true` 会误判 —— 任何 REST 服务都可能返回
`{"ok":true}`。`tts/1` 这个字面量是唯一能不歧义地确认"对面是 TTS/1 引擎"的凭据。

不合格时要报出**是哪一项不合格**，例如：
`缺少 protocol 字段（拿到了 name/engine，说明对面是个服务但不是 TTS/1）`。

### 2.2 `POST /synthesize` — 合成

请求 `Content-Type: application/json`：

```json
{ "text": "要合成的文本", "voice": "zh_CN-huayan-medium", "format": "wav" }
```

- `text` **必填**，非空。建议服务端同时设上限（如 5000 字），超限返回 `413`。
- `voice` 可选；缺省用服务端的 `default_voice`。
- `format` 可选；缺省用 `formats[0]`。

成功响应 `200`，**响应体就是音频字节**，`Content-Type` 必须如实标注
（`audio/wav` / `audio/mpeg` / `audio/ogg`…）。
客户端**按 `Content-Type` 决定落盘扩展名**，不猜。

失败响应：非 `200` 状态码 + JSON：

```json
{ "ok": false, "error": { "code": "voice_not_found", "message": "音色 xx 不存在" } }
```

客户端在失败时会把 `error.message` 直接显示给用户（不是显示 `HTTP 500`）。

---

## 3. 客户端判定顺序（`tts_engines_logic.dart` 逐字实现）

```
1. 地址能解析成 http(s) URL，且能连上（3 秒超时）
2. GET /health 返回 200 且是 JSON 对象
3. ok == true          —— 否则判 "服务在但不健康"
4. protocol == "tts/1" —— 否则判 "不是 TTS/1 引擎"（这一步最容易被跳过）
5. 记下 voices / default_voice / formats / sample_rate，落盘
6. 才算"已连接"
```

★ 第 3 步与第 4 步必须**分开报**：
   - `ok` 不为真 → 对面是自己声明"不健康"，通常是模型没加载完；
   - `ok` 为真但 `protocol` 不对 → 对面是**另一个**服务（很可能你把 1234 端口
     上的阅读引擎、或 9527 上的资源库地址填进来了）。
   两种情况用户要做的事完全不同，合并成一句"连接失败"就等于没说。

---

## 4. 参考实现（三行 shim）

本协议刻意做成"什么引擎都能套"，因为真实情况是各引擎的启动方式差别很大：

- **Piper**（离线、体积小、中文可用）
  官方发布页提供各语言的 `.onnx` 音色文件；跑起来后套一个 30 行的
  FastAPI/Flask 暴露上面两个端点即可。
- **sherpa-onnx**（离线、多语言、含中文）
  官方提供预编译二进制与模型包；同样套一层薄 HTTP。
- **GPT-SoVITS / ChatTTS / CosyVoice**（音色克隆/高质量，吃显卡）
  这些自带 WebUI，**不要**去爬 WebUI 的私有接口（会随版本变）；照本协议写一层薄封装。
- **edge-tts**（在线、免费、无需模型）
  属于"在线"性质，本协议不管它的内部实现；同样只需包一层。

**为什么不做"一键安装"**：这些引擎的依赖（CUDA / Python 版本 / 模型体积）差异太大，
"一键"在真机上几乎必然失败，然后用户会以为是 App 坏了。
所以引导页做的是：**列出项目主页 + 附启动命令 + 填入地址 + 一键连接自检** ——
下载与安装交给用户，连接这一段由 App 保证可用、可诊断。

---

## 5. 已知边界

- **只支持 HTTP 明文与标准 TLS**；自签证书需要用户在系统层信任（客户端不做跳过校验）。
- **不做音色试听预处理**：`voices` 列表直接展示，试听靠"合成一句短句并播放"。
- **不做流式**：本协议是"整段返回文件"。边合成边播需要 chunked 传输，留待 TTS/2。
- **不做文本切分**：切分由客户端做（`tts.dart` 已有的分段逻辑），
  所以服务端收到的每段都在合理长度内。
- **不做鉴权**：局域网内自用。要暴露到公网请在反代上加 Basic/Token，
  并在 URL 里带上（客户端的地址栏接受完整 URL）。
