// PhotoBridge 接收端：iPhone 在同一個 Wi-Fi 直接把原始檔傳過來。
// /api/*  給手機用，要帶配對 token。
// /ui/*   給本機瀏覽器操作介面用，只接受 127.0.0.1。
const http = require('http');
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execFile } = require('child_process');
const QRCode = require('qrcode');
const { Store, hashFile } = require('./store');

const VERSION = '0.1.0';

function configDir() {
  if (process.env.PHOTOBRIDGE_CONFIG_DIR) return process.env.PHOTOBRIDGE_CONFIG_DIR;
  if (process.platform === 'win32') return path.join(process.env.APPDATA || os.homedir(), 'PhotoBridge');
  return path.join(os.homedir(), '.photobridge');
}

function lanAddresses() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (a.address.startsWith('169.254.')) continue;
      // 虛擬網卡（VPN、WSL、VirtualBox）排後面
      const virtual = /vEthernet|VirtualBox|VMware|WSL|Hyper-V|tailscale|utun|docker|bridge/i.test(name)
        || a.address.startsWith('100.');
      const priv = /^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a.address);
      out.push({ address: a.address, score: (priv ? 0 : 2) + (virtual ? 4 : 0) });
    }
  }
  return out.sort((a, b) => a.score - b.score).map((a) => a.address);
}

class App {
  constructor(opts = {}) {
    this.cfgDir = opts.configDir || configDir();
    this.cfgPath = path.join(this.cfgDir, 'config.json');
    this.port = opts.port ?? (Number(process.env.PHOTOBRIDGE_PORT) || 52765);
    this.cfg = {};
    this.store = null;
    this.uploadsInFlight = new Map(); // key -> filename
    this.session = this.newSession();
    this.phoneReport = null; // 手機最後回報的總覽
    this.verifyJob = null;
    this.events = []; // 最近事件，給介面顯示
  }

  newSession() {
    return { startedAt: null, lastSeen: null, device: null, received: 0, skipped: 0, failed: 0, bytes: 0 };
  }

  async init() {
    await fsp.mkdir(this.cfgDir, { recursive: true });
    if (fs.existsSync(this.cfgPath)) {
      try { this.cfg = JSON.parse(await fsp.readFile(this.cfgPath, 'utf8')); } catch { this.cfg = {}; }
    }
    if (!this.cfg.token) this.cfg.token = crypto.randomBytes(18).toString('base64url');
    if (!this.cfg.name) this.cfg.name = os.hostname().replace(/\.local$/i, '');
    await this.saveCfg();
    if (this.cfg.backupDir) {
      try { await this.setBackupDir(this.cfg.backupDir); } catch (e) { this.log('error', `備份資料夾無法使用：${e.message}`); }
    }
  }

  async saveCfg() {
    await fsp.writeFile(this.cfgPath, JSON.stringify(this.cfg, null, 2));
  }

  async setBackupDir(dir) {
    const abs = path.resolve(dir);
    await fsp.mkdir(abs, { recursive: true });
    const probe = path.join(abs, `.pb-write-test-${process.pid}`);
    await fsp.writeFile(probe, 'ok');
    await fsp.rm(probe);
    if (this.uploadsInFlight.size) throw new Error('傳輸中不能換資料夾');
    this.store = await new Store(abs).open();
    this.cfg.backupDir = abs;
    await this.saveCfg();
    const report = path.join(this.store.metaDir, 'last-report.json');
    this.phoneReport = fs.existsSync(report) ? JSON.parse(await fsp.readFile(report, 'utf8')) : null;
    this.log('info', `備份資料夾：${abs}（已有 ${this.store.count} 個檔案）`);
  }

  log(level, msg) {
    this.events.unshift({ at: new Date().toISOString(), level, msg });
    this.events.length = Math.min(this.events.length, 200);
    if (!this.quiet) console.log(`[${level}] ${msg}`);
  }

  pairUrl() {
    const q = new URLSearchParams({
      v: '1',
      hosts: lanAddresses().slice(0, 3).join(','),
      port: String(this.port),
      token: this.cfg.token,
      name: this.cfg.name,
    });
    return `photobridge://pair?${q}`;
  }

  // ---------------- HTTP ----------------
  handler() {
    return async (req, res) => {
      try {
        const url = new URL(req.url, 'http://x');
        if (url.pathname.startsWith('/api/')) return await this.api(req, res, url);
        if (!isLocal(req)) return send(res, 403, { error: '介面只能在這台電腦上開' });
        if (url.pathname.startsWith('/ui/')) return await this.ui(req, res, url);
        return await this.staticFile(res, url.pathname);
      } catch (e) {
        this.log('error', e.stack || String(e));
        if (!res.headersSent) send(res, 500, { error: e.message });
        else res.destroy();
      }
    };
  }

  async api(req, res, url) {
    const token = req.headers['x-token'];
    if (!token || !safeEqual(token, this.cfg.token)) return send(res, 401, { error: '配對碼不對，請重新掃描 QR Code' });
    const p = url.pathname;
    const device = req.headers['x-device'] ? decodeURIComponent(req.headers['x-device']) : null;
    this.session.lastSeen = new Date().toISOString();
    if (device) this.session.device = device;

    if (p === '/api/hello' && req.method === 'GET') {
      return send(res, 200, {
        name: this.cfg.name, version: VERSION, ready: !!this.store,
        backupDir: this.store ? this.store.root : null, count: this.store ? this.store.count : 0,
      });
    }
    if (!this.store) return send(res, 409, { error: '電腦端還沒選備份資料夾' });

    if (p === '/api/check' && req.method === 'POST') {
      // 手機送一批 key，回傳哪些已經驗證過、不用再傳
      const body = await readJson(req, 20 * 1024 * 1024);
      const have = [];
      for (const k of body.keys || []) if (this.store.has(k)) have.push(k);
      return send(res, 200, { have });
    }
    if (p === '/api/upload' && req.method === 'PUT') return this.upload(req, res);
    if (p === '/api/report' && req.method === 'POST') {
      const body = await readJson(req, 50 * 1024 * 1024);
      body.receivedAt = new Date().toISOString();
      this.phoneReport = body;
      if (body.final) {
        await fsp.writeFile(path.join(this.store.metaDir, 'last-report.json'), JSON.stringify(body));
        await this.writeProblemCsv(body);
        const s = body.summary || {};
        this.log('info', `手機回報：已備份 ${s.done ?? '?'}、失敗 ${s.failed ?? '?'}、只在 iCloud ${s.icloud ?? '?'}、尚未備份 ${s.pending ?? '?'}`);
      }
      return send(res, 200, { ok: true });
    }
    return send(res, 404, { error: 'not found' });
  }

  async upload(req, res) {
    const h = req.headers;
    const key = h['x-key'] && decodeURIComponent(h['x-key']);
    const filename = h['x-filename'] && decodeURIComponent(h['x-filename']);
    const sha = String(h['x-sha256'] || '').toLowerCase();
    const size = Number(h['x-size']);
    const created = h['x-created'] || null;
    if (!key || !filename || !/^[0-9a-f]{64}$/.test(sha) || !Number.isFinite(size) || size < 0) {
      req.resume();
      return send(res, 400, { error: '缺少 key / filename / sha256 / size' });
    }
    const known = this.store.get(key);
    if (known && known.sha256 === sha && known.size === size) {
      req.resume();
      this.session.skipped++;
      return send(res, 200, { status: 'exists', path: known.rel });
    }
    if (this.uploadsInFlight.has(key)) {
      req.resume();
      return send(res, 409, { error: '同一個檔案正在傳' });
    }
    if (await lowDisk(this.store.root, size)) {
      req.resume();
      this.log('error', `磁碟空間不足，無法接收 ${filename}`);
      return send(res, 507, { error: '電腦的備份磁碟空間不足' });
    }

    if (!this.session.startedAt) this.session.startedAt = new Date().toISOString();
    this.uploadsInFlight.set(key, filename);
    const tmp = path.join(this.store.tmpDir, crypto.randomBytes(8).toString('hex') + '.part');
    let dest = null;
    try {
      const { bytes, digest } = await receive(req, tmp);
      if (bytes !== size || digest !== sha) {
        await fsp.rm(tmp, { force: true });
        this.session.failed++;
        this.log('error', `${filename} 驗證失敗（大小 ${bytes}/${size}${digest !== sha ? '，SHA-256 不符' : ''}）`);
        return send(res, 422, { error: '檔案不完整或內容不符，請重傳', receivedBytes: bytes });
      }
      dest = await this.store.reserveDest(filename, created, sha);
      if (dest.existing) await fsp.rm(tmp, { force: true });
      else await fsp.rename(tmp, dest.full);
      if (created) {
        const t = new Date(created);
        if (!isNaN(t)) await fsp.utimes(dest.full, t, t).catch(() => {});
      }
      const rec = {
        key, rel: this.store.rel(dest.full), filename, size, sha256: sha, created,
        assetId: h['x-asset-id'] ? decodeURIComponent(h['x-asset-id']) : null,
        resType: h['x-res-type'] || null, at: new Date().toISOString(),
      };
      await this.store.add(rec);
      this.session.received++;
      this.session.bytes += size;
      return send(res, 200, { status: 'saved', path: rec.rel });
    } catch (e) {
      await fsp.rm(tmp, { force: true }).catch(() => {});
      this.session.failed++;
      this.log('error', `${filename} 接收中斷：${e.message}`);
      if (!res.headersSent && !req.destroyed) send(res, 500, { error: e.message });
    } finally {
      if (dest) this.store.release(dest.full);
      this.uploadsInFlight.delete(key);
    }
  }

  async writeProblemCsv(report) {
    const file = path.join(this.store.root, '未完成備份清單.csv');
    if (!(report.problems || []).length) return fsp.rm(file, { force: true });
    const rows = [['狀態', '檔名', '拍攝時間', '原因']];
    for (const it of report.problems || []) rows.push([labelOf(it.status), it.filename, it.created || '', it.reason || '']);
    const csv = '﻿' + rows.map((r) => r.map(csvCell).join(',')).join('\r\n');
    await fsp.writeFile(file, csv);
  }

  async ui(req, res, url) {
    const p = url.pathname;
    if (p === '/ui/state') {
      return send(res, 200, {
        version: VERSION, name: this.cfg.name, port: this.port, hosts: lanAddresses(),
        backupDir: this.store ? this.store.root : null,
        stored: this.store ? { count: this.store.count, bytes: this.store.totalBytes } : null,
        inFlight: [...this.uploadsInFlight.values()],
        session: this.session, phone: this.phoneReport ? stripProblems(this.phoneReport) : null,
        problems: this.phoneReport ? (this.phoneReport.problems || []).slice(0, 500) : [],
        verify: this.verifyJob, events: this.events.slice(0, 30),
      });
    }
    if (p === '/ui/qr') {
      const svg = await QRCode.toString(this.pairUrl(), { type: 'svg', margin: 1, errorCorrectionLevel: 'M' });
      res.writeHead(200, { 'content-type': 'image/svg+xml', 'cache-control': 'no-store' });
      return res.end(svg);
    }
    if (p === '/ui/pair-url') return send(res, 200, { url: this.pairUrl() });
    if (req.method !== 'POST') return send(res, 405, { error: 'POST only' });
    if (p === '/ui/pick-folder') {
      const dir = await pickFolder();
      if (!dir) return send(res, 200, { cancelled: true });
      await this.setBackupDir(dir);
      return send(res, 200, { backupDir: this.store.root });
    }
    if (p === '/ui/set-folder') {
      const body = await readJson(req, 64 * 1024);
      await this.setBackupDir(String(body.path || ''));
      return send(res, 200, { backupDir: this.store.root });
    }
    if (p === '/ui/reset-token') {
      this.cfg.token = crypto.randomBytes(18).toString('base64url');
      await this.saveCfg();
      this.log('info', '已重設配對碼，手機需要重新掃描');
      return send(res, 200, { ok: true });
    }
    if (p === '/ui/verify') {
      if (!this.store) return send(res, 409, { error: '先選備份資料夾' });
      if (this.verifyJob && this.verifyJob.running) return send(res, 409, { error: '驗證進行中' });
      this.verifyDisk();
      return send(res, 200, { ok: true });
    }
    if (p === '/ui/open-folder') {
      if (this.store) openPath(this.store.root);
      return send(res, 200, { ok: true });
    }
    return send(res, 404, { error: 'not found' });
  }

  // 重新讀一次硬碟上每個檔案算 SHA-256，壞掉或不見的從索引移除，手機下次會補傳
  async verifyDisk() {
    const job = this.verifyJob = { running: true, total: this.store.count, checked: 0, ok: 0, missing: 0, corrupt: 0, startedAt: new Date().toISOString() };
    const entries = [...this.store.entries.values()];
    for (const rec of entries) {
      const full = this.store.abs(rec.rel);
      try {
        const st = await fsp.stat(full);
        if (st.size !== rec.size || (await hashFile(full)) !== rec.sha256) {
          job.corrupt++;
          await this.store.remove(rec.key, 'corrupt');
          this.log('error', `檔案內容已變動，下次會重傳：${rec.rel}`);
        } else job.ok++;
      } catch {
        job.missing++;
        await this.store.remove(rec.key, 'missing');
        this.log('error', `檔案不見了，下次會重傳：${rec.rel}`);
      }
      job.checked++;
    }
    job.running = false;
    job.finishedAt = new Date().toISOString();
    this.log('info', `驗證完成：正常 ${job.ok}、不見 ${job.missing}、損毀 ${job.corrupt}`);
    return job;
  }

  async staticFile(res, p) {
    if (p !== '/' && p !== '/index.html') return send(res, 404, { error: 'not found' });
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end(indexHtml());
  }

  listen() {
    return new Promise((resolve, reject) => {
      const server = http.createServer(this.handler());
      server.requestTimeout = 0; // 大影片可能傳很久
      server.headersTimeout = 60000;
      server.keepAliveTimeout = 30000;
      server.once('error', reject);
      server.listen(this.port, '0.0.0.0', () => {
        this.port = server.address().port;
        this.server = server;
        resolve(server);
      });
    });
  }
}

// ---------------- helpers ----------------
// 打包成 exe 時介面內嵌在執行檔裡（node:sea asset），開發時讀 public/index.html
let cachedHtml = null;
function indexHtml() {
  if (cachedHtml) return cachedHtml;
  try {
    const sea = require('node:sea');
    if (sea.isSea()) return (cachedHtml = sea.getAsset('index.html', 'utf8'));
  } catch {}
  return fs.readFileSync(path.join(__dirname, '..', 'public', 'index.html'), 'utf8');
}

function receive(req, tmp) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    let bytes = 0;
    const out = fs.createWriteStream(tmp);
    req.on('data', (c) => { h.update(c); bytes += c.length; });
    req.on('close', () => {
      if (!req.complete) { out.destroy(); reject(new Error('連線中斷')); }
    });
    req.on('error', (e) => { out.destroy(); reject(e); });
    out.on('error', reject);
    out.on('finish', () => {
      // 確實寫到磁碟再回報成功
      fs.open(tmp, 'r+', (err, fd) => {
        if (err) return reject(err);
        fs.fsync(fd, () => fs.close(fd, () => resolve({ bytes, digest: h.digest('hex') })));
      });
    });
    req.pipe(out);
  });
}

async function lowDisk(dir, need) {
  try {
    const s = await fsp.statfs(dir);
    return s.bavail * s.bsize < need + 512 * 1024 * 1024;
  } catch { return false; }
}

function readJson(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

function isLocal(req) {
  const a = req.socket.remoteAddress || '';
  return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1';
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a)); const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function labelOf(s) { return { icloud: '只在 iCloud', failed: '失敗', pending: '尚未備份' }[s] || s; }
function csvCell(v) { const s = String(v ?? ''); return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; }
function stripProblems(r) { const { problems, ...rest } = r; return { ...rest, problemCount: (problems || []).length }; }

function pickFolder() {
  return new Promise((resolve) => {
    if (process.platform === 'win32') {
      const ps = [
        'Add-Type -AssemblyName System.Windows.Forms;',
        '$f = New-Object System.Windows.Forms.Form; $f.TopMost = $true;',
        '$d = New-Object System.Windows.Forms.FolderBrowserDialog;',
        '$d.Description = "選擇照片備份要放的資料夾"; $d.ShowNewFolderButton = $true;',
        'if ($d.ShowDialog($f) -eq "OK") { [Console]::OutputEncoding = [Text.Encoding]::UTF8; Write-Output $d.SelectedPath }',
      ].join(' ');
      execFile('powershell.exe', ['-NoProfile', '-STA', '-Command', ps], { windowsHide: true }, (err, out) => resolve(err ? null : out.trim() || null));
    } else if (process.platform === 'darwin') {
      execFile('osascript', ['-e', 'POSIX path of (choose folder with prompt "選擇照片備份要放的資料夾")'], (err, out) => resolve(err ? null : out.trim() || null));
    } else resolve(null);
  });
}

function openPath(p) {
  const cmd = process.platform === 'win32' ? 'explorer.exe' : process.platform === 'darwin' ? 'open' : 'xdg-open';
  execFile(cmd, [p], () => {});
}

module.exports = { App, lanAddresses };

async function main() {
  const app = new App();
  await app.init();
  try {
    await app.listen();
  } catch (e) {
    if (e.code === 'EADDRINUSE') {
      console.log(`連接埠 ${app.port} 已被佔用，可能已經開著一個接收程式了。直接打開 http://localhost:${app.port}`);
      openPath(`http://localhost:${app.port}`);
      return;
    }
    throw e;
  }
  const url = `http://localhost:${app.port}`;
  console.log(`PhotoBridge 接收程式已啟動：${url}`);
  console.log(`區網位址：${lanAddresses().join(', ') || '(找不到，請確認有連上 Wi-Fi)'}`);
  console.log('這個視窗關掉就會停止接收。');
  if (!process.env.PHOTOBRIDGE_NO_OPEN) openPath(url);
}

module.exports.main = main;
if (require.main === module) main();
