// 生成自签证书(TLS一层加密)。首次运行自动生成, 指纹打印给前端TOFU确认。
const selfsigned = require('selfsigned');
const fs = require('fs'); const path = require('path');
const dir = path.join(__dirname, '..', 'data');
fs.mkdirSync(dir, { recursive: true });
const attrs = [{ name: 'commonName', value: 'ThirdHub' }];
selfsigned.generate(attrs, {
  algorithm: 'sha256', days: 3650, keySize: 2048,
  extensions: [{ name: 'subjectAltName', altNames: [{ type: 2, value: 'localhost' }] }]
}, (err, pems) => {
  if (err) throw err;
  fs.writeFileSync(path.join(dir, 'key.pem'), pems.private);
  fs.writeFileSync(path.join(dir, 'cert.pem'), pems.cert);
  const crypto = require('crypto');
  const fp = crypto.createHash('sha256').update(pems.cert).digest('hex').match(/.{4}/g).join(':');
  console.log('证书已生成 data/cert.pem');
  console.log('SHA256 指纹(前端首次连接需确认):');
  console.log(fp);
});
