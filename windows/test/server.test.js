// 模擬 iPhone 端行為的端對端測試
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { App } = require('../src/server');

const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
let tmpRoot, app, base, token;

async function start() {
  app = new App({ configDir: path.join(tmpRoot, 'cfg'), port: 0 });
  app.quiet = true;
  await app.init();
  await app.listen();
  base = `http://127.0.0.1:${app.port}`;
  token = app.cfg.token;
}
async function stop() { await new Promise((r) => app.server.close(r)); if (app.store) await app.store.close(); }

async function api(p, opts = {}) {
  const r = await fetch(base + p, { ...opts, headers: { 'x-token': token, 'content-type': 'application/json', ...(opts.headers || {}) } });
  return { status: r.status, body: await r.json() };
}
function upload(buf, meta, override = {}) {
  return api('/api/upload', {
    method: 'PUT', body: buf,
    headers: {
      'content-type': 'application/octet-stream',
      'x-key': encodeURIComponent(meta.key), 'x-filename': encodeURIComponent(meta.filename),
      'x-sha256': override.sha ?? sha(buf), 'x-size': String(override.size ?? buf.length),
      'x-created': meta.created || '2024-05-03T10:00:00Z', 'x-res-type': 'photo',
    },
  });
}

test.before(async () => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'pb-test-'));
  await start();
});
test.after(async () => { await stop(); fs.rmSync(tmpRoot, { recursive: true, force: true }); });

test('沒有 token 被拒絕', async () => {
  const r = await fetch(base + '/api/hello');
  assert.strictEqual(r.status, 401);
});

test('沒選資料夾時不能上傳', async () => {
  const h = await api('/api/hello');
  assert.strictEqual(h.body.ready, false);
  const r = await upload(Buffer.from('x'), { key: 'k0', filename: 'a.jpg' });
  assert.strictEqual(r.status, 409);
});

test('選資料夾後上傳、驗證、去重', async () => {
  const dir = path.join(tmpRoot, 'backup');
  const r0 = await fetch(base + '/ui/set-folder', { method: 'POST', body: JSON.stringify({ path: dir }) });
  assert.strictEqual(r0.status, 200);

  const img = crypto.randomBytes(300 * 1024);
  const r1 = await upload(img, { key: 'A1|photo|IMG_0001.HEIC', filename: 'IMG_0001.HEIC' });
  assert.strictEqual(r1.status, 200);
  assert.strictEqual(r1.body.status, 'saved');
  assert.strictEqual(r1.body.path, '2024/2024-05/IMG_0001.HEIC');
  const saved = fs.readFileSync(path.join(dir, '2024', '2024-05', 'IMG_0001.HEIC'));
  assert.ok(saved.equals(img), '內容要一模一樣');
  // 修改時間設成拍攝時間
  assert.strictEqual(fs.statSync(path.join(dir, '2024', '2024-05', 'IMG_0001.HEIC')).mtime.toISOString(), '2024-05-03T10:00:00.000Z');

  const r2 = await upload(img, { key: 'A1|photo|IMG_0001.HEIC', filename: 'IMG_0001.HEIC' });
  assert.strictEqual(r2.body.status, 'exists');

  const c = await api('/api/check', { method: 'POST', body: JSON.stringify({ keys: ['A1|photo|IMG_0001.HEIC', 'nope'] }) });
  assert.deepStrictEqual(c.body.have, ['A1|photo|IMG_0001.HEIC']);
});

test('SHA-256 不符或大小不符就不存、不記錄', async () => {
  const buf = crypto.randomBytes(1000);
  const bad = await upload(buf, { key: 'B1|photo|IMG_0002.JPG', filename: 'IMG_0002.JPG' }, { sha: sha(Buffer.from('other')) });
  assert.strictEqual(bad.status, 422);
  const short = await upload(buf, { key: 'B1|photo|IMG_0002.JPG', filename: 'IMG_0002.JPG' }, { size: 2000 });
  assert.strictEqual(short.status, 422);
  assert.strictEqual(app.store.has('B1|photo|IMG_0002.JPG'), false);
  assert.strictEqual(fs.existsSync(path.join(app.store.root, '2024', '2024-05', 'IMG_0002.JPG')), false);
  assert.deepStrictEqual(fs.readdirSync(app.store.tmpDir), []);
});

test('傳到一半斷線：不記錄，之後可重傳', async () => {
  const buf = crypto.randomBytes(2 * 1024 * 1024);
  const url = new URL(base + '/api/upload');
  await new Promise((resolve) => {
    const req = http.request({
      host: url.hostname, port: url.port, path: url.pathname, method: 'PUT',
      headers: { 'x-token': token, 'x-key': 'C1|video|IMG_0003.MOV', 'x-filename': 'IMG_0003.MOV', 'x-sha256': sha(buf), 'x-size': String(buf.length) },
    });
    req.on('error', () => {});
    req.write(buf.subarray(0, 500 * 1024));
    setTimeout(() => { req.destroy(); setTimeout(resolve, 300); }, 100);
  });
  assert.strictEqual(app.store.has('C1|video|IMG_0003.MOV'), false);
  assert.deepStrictEqual(fs.readdirSync(app.store.tmpDir), []);
  const ok = await upload(buf, { key: 'C1|video|IMG_0003.MOV', filename: 'IMG_0003.MOV' });
  assert.strictEqual(ok.body.status, 'saved');
});

test('同名不同內容：加 (2)；Live Photo 兩個檔都收', async () => {
  const a = crypto.randomBytes(500), b = crypto.randomBytes(600);
  const [r1, r2] = await Promise.all([
    upload(a, { key: 'D1|photo|IMG_0100.HEIC', filename: 'IMG_0100.HEIC' }),
    upload(b, { key: 'D2|photo|IMG_0100.HEIC', filename: 'IMG_0100.HEIC' }),
  ]);
  const paths = [r1.body.path, r2.body.path].sort();
  assert.deepStrictEqual(paths, ['2024/2024-05/IMG_0100 (2).HEIC', '2024/2024-05/IMG_0100.HEIC']);
  const mov = crypto.randomBytes(800);
  const r3 = await upload(mov, { key: 'D1|pairedVideo|IMG_0100.MOV', filename: 'IMG_0100.MOV' });
  assert.strictEqual(r3.body.path, '2024/2024-05/IMG_0100.MOV');
});

test('危險檔名會被清理', async () => {
  const r = await upload(Buffer.from('z'), { key: 'E1|photo|x', filename: '..\\..\\evil:name?.jpg' });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.path.split('/').length, 3, '不能跳出日期資料夾');
  assert.ok(r.body.path.startsWith('2024/2024-05/'));
});

test('重開程式後索引還在（斷點續傳）', async () => {
  const before = app.store.count;
  await stop();
  await start();
  assert.strictEqual(app.store.count, before);
  const c = await api('/api/check', { method: 'POST', body: JSON.stringify({ keys: ['A1|photo|IMG_0001.HEIC', 'C1|video|IMG_0003.MOV'] }) });
  assert.strictEqual(c.body.have.length, 2);
});

test('驗證硬碟：刪掉或改壞的檔案會從索引移除', async () => {
  fs.rmSync(path.join(app.store.root, '2024', '2024-05', 'IMG_0001.HEIC'));
  fs.appendFileSync(path.join(app.store.root, '2024', '2024-05', 'IMG_0003.MOV'), 'x');
  const job = await app.verifyDisk();
  assert.strictEqual(job.missing, 1);
  assert.strictEqual(job.corrupt, 1);
  assert.strictEqual(app.store.has('A1|photo|IMG_0001.HEIC'), false);
  await stop(); await start();
  assert.strictEqual(app.store.has('C1|video|IMG_0003.MOV'), false, '移除紀錄重開後也要生效');
});

test('手機最終回報會寫出未完成清單 CSV', async () => {
  const r = await api('/api/report', {
    method: 'POST',
    body: JSON.stringify({ final: true, summary: { total: 3, files: 4, done: 1, failed: 1, icloud: 1, pending: 0 },
      problems: [{ status: 'icloud', filename: 'IMG_9.HEIC', created: '2020-01-01T00:00:00Z', reason: '原始檔只在 iCloud' }, { status: 'failed', filename: 'a,b.MOV', reason: '讀取失敗' }] }),
  });
  assert.strictEqual(r.status, 200);
  const csv = fs.readFileSync(path.join(app.store.root, '未完成備份清單.csv'), 'utf8');
  assert.match(csv, /只在 iCloud,IMG_9.HEIC/);
  assert.match(csv, /"a,b.MOV"/);
  const st = await (await fetch(base + '/ui/state')).json();
  assert.strictEqual(st.phone.summary.icloud, 1);
  assert.strictEqual(st.problems.length, 2);
});

test('QR Code 內容帶 token 與區網位址', async () => {
  const j = await (await fetch(base + '/ui/pair-url')).json();
  const u = new URL(j.url);
  assert.strictEqual(u.protocol, 'photobridge:');
  assert.strictEqual(u.searchParams.get('token'), token);
  const svg = await (await fetch(base + '/ui/qr')).text();
  assert.match(svg, /^<svg/);
});
