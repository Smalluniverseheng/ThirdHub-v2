# 声明式内容源规范（FreeSourceSpec v1）

> 一句话：**一个源 = 一份 JSON**。里面只有「向哪个地址发请求」和「从响应里怎么取字段」，
> 没有脚本、没有代码执行。这份文档就是写源的全部依据。

---

## 1. 为什么是「声明式」而不是脚本

开放式内容源通常有两类做法：

| 做法 | 表达力 | 风险 |
|---|---|---|
| JS 脚本源（如 legado 书源） | 极强，可写任意逻辑 | 源作者拿到执行权，等于 App 变成代码执行器 |
| **声明式 JSON（本规范）** | 够用：请求 + 取字段 | 最坏结果是「这个源自己取不到数据」 |

本应用选了后者，理由很直接：**手机上的 App 不该因为导入了一份别人的文件，
就获得执行任意代码的能力**。抓取和转换这些重活儿交给桌面容器去做，
端上只负责「把已经结构化的数据取回来」。

代价是表达力有边界，写在最后一节。

---

## 2. 安全边界（这一节是硬约束）

源包是纯数据。执行引擎（`lib/core/free/free_spec.dart`）额外做了这些限制：

- **只允许 `http` / `https`**，`file:` `javascript:` `data:` 一律拒绝；
- **请求头不许指定 `Host`**，不许含 CRLF（防请求走私）；
- **单次响应最多 8 MB**，单页最多 200 条（防内存打爆）；
- **一个动作 = 一次请求**，不跟随源作者写的跳转链，不递归爬站；
- **最多两个动作**（`search` + `detail`），不做三层下钻；
- 取值只能**读**，不能写文件、不能访问本地路径。

---

## 3. 最小可用示例

```json
{
  "schema": 1,
  "name": "我的第一个源",
  "sources": [
    {
      "id": "demo",
      "name": "示例",
      "note": "一句话说明它是什么、内容从哪来",
      "kind": "music",
      "license": "officialApi",
      "base": "https://api.example.com",
      "ping": "/health",
      "search": {
        "path": "/search",
        "query": { "q": "{q}", "limit": "20" },
        "list": "data.items",
        "map": {
          "id": "id",
          "title": "name",
          "subtitle": "artist",
          "playUrl": "audio_url"
        }
      }
    }
  ]
}
```

> 单个源也可以直接当包导入：把 `sources` 那层去掉，顶层直接写源对象。

---

## 4. 源（source）字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 2~32 位小写字母/数字/下划线，全局唯一。**重复 id 后导入的覆盖先导入的** |
| `name` | 是 | 显示名 |
| `note` | | 一句话说明：是什么、内容哪来、有什么限制 |
| `kind` | 是 | `music` / `podcast` / `radio` / `video` / `comic` / `book` / `poem` |
| `license` | 是 | 见 §8。**不写按最严处理**（等价于 `thirdPartyRule`） |
| `attribution` | | 权利人署名 / 内容出处。上架审核会看这一项，也是给用户的交代 |
| `termsUrl` | | 该源的使用条款或授权说明地址 |
| `base` | | 站点根地址。相对路径与 `abs` 补全都以它为基准 |
| `ping` | | 探活地址（相对 `base` 或完整 URL）。留空则不探测，总是尝试 |
| `search` | 是 | 搜索动作，见 §5 |
| `detail` | | 下钻动作（漫画章节 / 播客单集）。没有就不可下钻 |

---

## 5. 动作（action）字段

```json
{
  "method": "GET",
  "path": "/search?q={q}&page={page}",
  "query": { "extra": "1" },
  "headers": { "Referer": "https://site.com" },
  "body": "{\"kw\":\"{q}\"}",
  "fetch": "json",
  "list": "data.items",
  "limit": 40,
  "drill": false,
  "map": { "...": "见 §6" }
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `method` | `GET` | `GET` / `POST` |
| `path` | — | 必填。相对 `base` 或完整 URL。支持占位符（见 §7） |
| `query` | `{}` | 追加查询参数，值同样支持占位符 |
| `headers` | `{}` | 附加请求头。**不接受 `Host`** |
| `body` | | POST 请求体。缺省 `Content-Type` 为 `application/json` |
| `fetch` | `json` | `json` / `rss` / `html`，决定 `map` 与 `list` 的取值语法 |
| `list` | | 结果数组的位置（见 §6） |
| `limit` | `60` | 单页最多取几条，上限 200 |
| `drill` | `false` | 结果是否可点进去看子列表 |

---

## 6. 取值语法

### 6.1 `fetch: "json"`

`list` 是结果数组的路径，`map` 的每个值是该字段的路径：

| 写法 | 含义 |
|---|---|
| `a.b.c` | 逐层取 |
| `a.b[0]` 或 `a.b.0` | 取数组第 0 项 |
| `artists[].name` | 遍历数组，把每项的 `name` 用 `、` 连起来 |
| `$` | 整个响应体 |

取不到时返回空串，不会报错，也不会让整条结果消失（除非 `title` 为空，
那条会被丢弃，用来过滤广告位）。

### 6.2 `fetch: "rss"`

`map` 的值是标签名：

| 写法 | 含义 |
|---|---|
| `title` | 取 `<title>` 的文本（CDATA 会自动剥掉） |
| `enclosure@url` | 取 `<enclosure url="...">` 的属性值 |
| `itunes:image@href` | 带命名空间的标签同样按字面匹配 |

RSS 模式忽略 `list`，一条 `<item>` 就是一条结果。

### 6.3 `fetch: "html"`

`list` 是 CSS 选择器，`map` 的每个值也是选择器：

| 写法 | 含义 |
|---|---|
| `div.book` | 取该元素的文本 |
| `a.title@href` | 取属性 |
| `div.desc@html` | 取内层 HTML（常配 `"strip": true`） |

### 6.4 候选路径链 `||`（三种 fetch 通用）

一条字段可以写**多条候选路径**，用 `||` 分隔，按顺序取第一个非空值：

```json
"cover": {
  "path": "relationships.0.attributes.fileName||relationships.1.attributes.fileName||relationships.2.attributes.fileName"
}
```

这不是语法糖，是真实接口逼出来的。两个实例：

**MangaDex 的封面**在 `relationships` 数组里，但 `cover_art` 的索引会变 ——
有 author + artist 时是第 3 个，没有 author 时是第 2 个。固定下标必然漏掉一部分，
用候选链就能自动跳过「有索引但没有 fileName」的 author / artist 项。

**PeerTube 的播放地址**在两种位置：老视频在顶层 `files`，新视频在
`streamingPlaylists[0].files`。同一套 API 两种形态，不做候选链就得把一份源拆成两个入口。

> ⚠️ 候选链的判断依据是**「空不空」，不是「能不能访问」**。
> 如果一个地址取到了值但其实已经 404，候选链不会往下退。
> 所以顺序要按「哪种形态更少失效」来排 —— 实测 PeerTube 是 HLS 更持久，
> 所以 `streamingPlaylists` 写在前面、`files` 兜底，4 条样本全部可播；
> 反过来排会有 1 条落在死链上。

---

## 7. 字段映射（map）

`map` 的 key 是**固定的一组**，值有三种写法：

```json
"map": {
  "title": "name",
  "cover": { "path": "img", "abs": true },
  "desc":  { "path": "intro", "strip": true },
  "playUrl": { "tpl": "https://site.com/play/{id}.mp3" }
}
```

| key | 用途 |
|---|---|
| `id` | 源内唯一 id。下钻时用它拼 `{id}` |
| `title` | **必填**。为空则该条被丢弃 |
| `subtitle` | 副标题（作者 / 艺人 / 时间） |
| `cover` | 封面图 URL |
| `desc` | 简介 |
| `playUrl` | 可播放地址。有它 = 点了直接播 |
| `drill` | 存在即表示「可下钻」，值本身不参与判断 |

值的修饰符：

| 修饰符 | 说明 |
|---|---|
| `abs: true` | 取到的是相对地址，用 `base` 补全 |
| `strip: true` | 剥掉 HTML 标签 |
| `fallback` | 取不到时的兜底值 |
| `tpl` | **模板模式**：用 `{字段名}` 拼字符串，而不是从响应取值 |

### 模板模式（重要）

大量源的播放地址不是响应里的某个字段，而是拿 id 拼出来的：

```json
"playUrl": { "tpl": "https://music.163.com/song/media/outer/url?id={id}.mp3" }
```

规则：
- `{x}` 取自**同一条结果已解析出的字段**（`id` / `title` / `cover` …）；
- 解析顺序是「先跑完所有路径字段，再跑模板字段」，所以模板可以安全引用 `id`；
- 引用了不存在的字段会替换成**空串**，不报错。

### 占位符（用在 path / query / body）

| 占位符 | 内容 |
|---|---|
| `{q}` | 搜索关键词（会被 URL 编码） |
| `{page}` | 页码，从 1 开始 |
| `{id}` | 下钻时的条目 id |

---

## 8. 授权性质（license）与它决定的事

| 值 | 含义 | 移动端可用 |
|---|---|---|
| `publicDomain` | 公有领域 | ✅ 直接可用 |
| `creativeCommons` | CC / ODbL 等开放许可 | ✅ 直接可用 |
| `officialApi` | 平台官方公开 API，条款允许第三方读取 | ✅ 直接可用 |
| `userOwned` | 你自己购买/录制/部署的内容 | ✅ 直接可用 |
| `thirdPartyRule` | 授权不明，或可能违反目标站点条款 | ⚠️ 需手动开启「自担责任」 |
| `scraped` | 主动爬取网页 | ⚠️ 需手动开启「自担责任」 |

判据只有一条，写在 `FreePolicy` 里：**要上架的二进制里不能有后两类源**。
导入的源存的是「你的配置」，不是应用分发的内容 —— 但开关必须由你自己点。

---

## 9. 完整示例

### 9.1 JSON 接口 + 模板拼播放地址（网易云）

```json
{
  "id": "netease_music",
  "name": "网易云音乐",
  "kind": "music",
  "license": "thirdPartyRule",
  "base": "https://music.163.com",
  "ping": "/api/search/get?s=test&type=1&limit=1",
  "search": {
    "path": "/api/search/get",
    "query": { "s": "{q}", "type": "1", "limit": "30" },
    "headers": { "Referer": "https://music.163.com" },
    "list": "result.songs",
    "map": {
      "id": "id",
      "title": "name",
      "subtitle": { "path": "artists[].name" },
      "desc": "album.name",
      "playUrl": { "tpl": "https://music.163.com/song/media/outer/url?id={id}.mp3" }
    }
  }
}
```

### 9.2 播客 RSS（最省事的一类）

```json
{
  "id": "storyfm",
  "name": "故事 FM",
  "kind": "podcast",
  "license": "officialApi",
  "ping": "https://feeds.storyfm.cn/storyfm.xml",
  "search": {
    "path": "https://feeds.storyfm.cn/storyfm.xml",
    "fetch": "rss",
    "limit": 50,
    "map": {
      "id": "guid",
      "title": "title",
      "subtitle": "pubDate",
      "desc": { "path": "description", "strip": true },
      "playUrl": "enclosure@url",
      "cover": "itunes:image@href"
    }
  }
}
```

> **加一个新播客 = 换一个 `path`**。这是性价比最高的扩源方式。

### 9.3 网页选择器（HTML）

```json
{
  "id": "demo_html",
  "name": "网页示例",
  "kind": "book",
  "license": "scraped",
  "base": "https://example.com",
  "search": {
    "path": "/search?q={q}",
    "fetch": "html",
    "list": "div.result-item",
    "map": {
      "id": "a.title@href",
      "title": "a.title",
      "desc": { "path": "p.intro", "strip": true },
      "cover": { "path": "img@src", "abs": true }
    }
  }
}
```

---

## 10. 怎么验证你写的源

不用装到手机上猜。仓库里有探测器：

```bash
cd flutter_app
dart run tool/free_spec_probe.dart ../docs/free-sources/starter.json 关键词
```

输出会逐源告诉你：请求耗时、取到几条、前三条长什么样、
以及**第一条播放地址到底是不是媒体流**（会真读 8KB 判断 Content-Type）。

判定口径：

| 输出 | 含义 |
|---|---|
| `[OK]` | 取到条目 |
| `[EMPTY]` | 请求成功但没取到条目 → 多半是 `list` 或字段路径写错 |
| `[FAIL]` | 请求本身失败 → 地址、请求头、或站点拒绝 |
| `播放地址：不可播（返回网页…）` | 地址拿到了但不是媒体流 |

---

## 11. 已知边界（做不到的事）

写在最前面，免得写源的人反复试：

1. **不能取正文**。`detail` 只能返回「子列表」（章节/单集），不能把一篇文章的正文抓回来读。
   需要读正文的场景，目前只有内置的维基文库 / 古登堡实现了（走各自的专用解析）。
2. **不能做算术**。`page=3` 想换成 `offset=60` 做不到 —— 只能直接当页码传。
3. **不能多步登录**。要 Cookie / token 的站，只能把固定值写进 `headers`（会过期）。
4. **不做 GBK 解码**。响应必须是 UTF-8；老 GBK 站点会显示乱码。
5. **最多两层**。搜索 → 子列表，不能再往下点。
6. **必须是 JSON / RSS / 标准 HTML**，纯 JS 渲染的站（SPA）抓到的是空壳。

第 6 条是中文站点最常撞上的：大量站点搜索页是前端渲染的，
HTML 里根本没有条目。判断方法很简单 —— 用 `curl` 拿到的 HTML 里搜不到你要的词，
那这个站就没法用声明式源接。

---

## 12. 分发

- 源包放在家庭后端的 `data/free-sources.json`，管理员账号登录后 App 自动同步；
- 也可以导出成文件互相分享（「我的源 → 导出」把包复制到粘贴板）；
- **源包不进安装包**。安装包里只有随版本发布的合规源，可静态审计。
