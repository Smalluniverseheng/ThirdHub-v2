'use strict';
// EPUB 3 生成器（纯 Node，无依赖）。
//
// 为什么是 EPUB 而不是 TXT/PDF：
//   · EPUB 在手机上能直接被系统阅读器、各家阅读 App 打开，**不需要本 App 在场**；
//   · 它是标准格式 —— 这正是「桌面端出成品、移动端只负责读」的关键一环：
//     手机端拿到的是一份合规的本地文件，不是一条需要实时连服务器才能看的链接。
//
// 结构（EPUB 3.3 最小合规集）：
//   mimetype                （必须是第一个条目且不压缩）
//   META-INF/container.xml  （指向 OPF）
//   OEBPS/content.opf       （package：metadata + manifest + spine）
//   OEBPS/nav.xhtml         （EPUB3 导航文档，属性 toc）
//   OEBPS/toc.ncx           （EPUB2 兼容目录，老阅读器认这个）
//   OEBPS/text/chap-N.xhtml （正文）
//   OEBPS/images/...        （插图，可选）

const { ZipWriter } = require('./zip');

const XML_ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' };
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => XML_ESC[c]);
}

/** 纯文本 → 段落 HTML。空行分段，单换行变 <br/>。 */
function textToHtml(text) {
  const blocks = String(text || '')
    .replace(/\r\n?/g, '\n')
    .split(/\n{2,}/)
    .map((b) => b.trim())
    .filter(Boolean);
  if (!blocks.length) return '<p></p>';
  return blocks
    .map((b) => '<p>' + esc(b).replace(/\n/g, '<br/>') + '</p>')
    .join('\n');
}

/** 判断传入内容像不像 HTML（避免把已有 HTML 再转义一遍）。 */
function looksHtml(s) {
  return /<\/?(p|div|br|h[1-6]|img|span|em|strong)\b/i.test(String(s || ''));
}

function chapterBody(content) {
  return looksHtml(content) ? String(content) : textToHtml(content);
}

/**
 * @param {object} book
 * @param {string} book.title
 * @param {string} [book.author]
 * @param {string} [book.language] 默认 zh-CN
 * @param {string} [book.identifier] 默认由 title+时间生成
 * @param {Array<{title:string, content:string}>} book.chapters
 * @param {{name:string, data:Buffer, mediaType:string}} [book.cover]
 * @returns {Buffer}
 */
function buildEpub(book) {
  const title = book.title || '未命名';
  const author = book.author || '';
  const lang = book.language || 'zh-CN';
  const chapters = (book.chapters || []).filter((c) => c && (c.content || c.title));
  if (!chapters.length) throw new Error('EPUB 至少需要一章');

  const uid = book.identifier || 'th-' + Buffer.from(title + Date.now()).toString('hex').slice(0, 24);
  const modified = new Date().toISOString().replace(/\.\d+Z$/, 'Z');

  const z = new ZipWriter();
  // ① mimetype 必须第一个、且不压缩 —— 阅读器靠这一点做魔数识别
  z.add('mimetype', 'application/epub+zip', { store: true });

  z.add('META-INF/container.xml', `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`);

  // ② 正文
  const manifestItems = [];
  const spineItems = [];
  chapters.forEach((c, i) => {
    const id = 'chap' + (i + 1);
    const href = `text/${id}.xhtml`;
    z.add('OEBPS/' + href, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="${esc(lang)}" lang="${esc(lang)}">
<head><meta charset="utf-8"/><title>${esc(c.title || '第 ' + (i + 1) + ' 章')}</title>
<link rel="stylesheet" type="text/css" href="../style.css"/></head>
<body><h1>${esc(c.title || '第 ' + (i + 1) + ' 章')}</h1>
${chapterBody(c.content)}
</body></html>`);
    manifestItems.push(`    <item id="${id}" href="${href}" media-type="application/xhtml+xml"/>`);
    spineItems.push(`    <itemref idref="${id}"/>`);
  });

  // ③ 样式（出版社不用管，能读就行）
  z.add('OEBPS/style.css', `body{font-family:serif;line-height:1.75;margin:1em;}
h1{font-size:1.25em;margin:1.2em 0 .8em;line-height:1.4;}
p{margin:0 0 .9em;text-indent:2em;}
img{max-width:100%;height:auto;}`);

  // ④ 封面（可选）
  let coverMeta = '';
  let coverManifest = '';
  if (book.cover && book.cover.data) {
    const ext = (book.cover.name || 'cover.jpg').split('.').pop().toLowerCase();
    const mt = book.cover.mediaType || (ext === 'png' ? 'image/png' : 'image/jpeg');
    z.add('OEBPS/images/cover.' + ext, book.cover.data);
    coverManifest =
      `    <item id="cover-img" href="images/cover.${ext}" media-type="${mt}" properties="cover-image"/>\n`;
    coverMeta = '    <meta name="cover" content="cover-img"/>\n';
  }

  // ⑤ 导航（EPUB3）
  const navLis = chapters
    .map((c, i) => `      <li><a href="text/chap${i + 1}.xhtml">${esc(c.title || '第 ' + (i + 1) + ' 章')}</a></li>`)
    .join('\n');
  z.add('OEBPS/nav.xhtml', `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="${esc(lang)}">
<head><meta charset="utf-8"/><title>目录</title></head>
<body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>
${navLis}
</ol></nav></body></html>`);
  manifestItems.push('    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>');

  // ⑥ 老阅读器兼容目录
  const navPoints = chapters
    .map((c, i) => `    <navPoint id="np${i + 1}" playOrder="${i + 1}">
      <navLabel><text>${esc(c.title || '第 ' + (i + 1) + ' 章')}</text></navLabel>
      <content src="text/chap${i + 1}.xhtml"/>
    </navPoint>`)
    .join('\n');
  z.add('OEBPS/toc.ncx', `<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="${esc(uid)}"/></head>
  <docTitle><text>${esc(title)}</text></docTitle>
  <navMap>
${navPoints}
  </navMap>
</ncx>`);
  manifestItems.push('    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');

  // ⑦ 打包描述
  z.add('OEBPS/content.opf', `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="${esc(lang)}">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">${esc(uid)}</dc:identifier>
    <dc:title>${esc(title)}</dc:title>
    <dc:language>${esc(lang)}</dc:language>
${author ? '    <dc:creator>' + esc(author) + '</dc:creator>\n' : ''}    <dc:publisher>ThirdHub 桌面引擎</dc:publisher>
    <meta property="dcterms:modified">${modified}</meta>
${coverMeta}  </metadata>
  <manifest>
    <item id="css" href="style.css" media-type="text/css"/>
${coverManifest}${manifestItems.join('\n')}
  </manifest>
  <spine toc="ncx">
${spineItems.join('\n')}
  </spine>
</package>`);

  return z.build();
}

module.exports = { buildEpub, textToHtml, looksHtml };
