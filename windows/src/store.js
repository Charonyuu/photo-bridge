// 備份資料夾裡的索引：只有「收到的位元組 SHA-256 跟手機算的一致」才會寫進來。
// 格式：<備份資料夾>/.photobridge/index.jsonl，一行一筆，後面的覆蓋前面的。
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const crypto = require('crypto');

const META = '.photobridge';

class Store {
  constructor(root) {
    this.root = root;
    this.metaDir = path.join(root, META);
    this.tmpDir = path.join(this.metaDir, 'tmp');
    this.indexPath = path.join(this.metaDir, 'index.jsonl');
    this.entries = new Map(); // key -> record
    this.reservedPaths = new Set(); // 上傳中已佔用的目的檔名（小寫）
    this.writeChain = Promise.resolve();
  }

  async open() {
    await fsp.mkdir(this.tmpDir, { recursive: true });
    // 上次中斷留下的 .part 全部清掉（斷點續傳以「檔案」為單位）
    for (const f of await fsp.readdir(this.tmpDir)) {
      await fsp.rm(path.join(this.tmpDir, f), { force: true });
    }
    if (fs.existsSync(this.indexPath)) {
      const text = await fsp.readFile(this.indexPath, 'utf8');
      for (const line of text.split('\n')) {
        if (!line.trim()) continue;
        let rec;
        try { rec = JSON.parse(line); } catch { continue; } // 最後一行寫到一半就略過
        if (rec.removed) this.entries.delete(rec.key);
        else this.entries.set(rec.key, rec);
      }
    }
    return this;
  }

  get count() { return this.entries.size; }

  get totalBytes() {
    let n = 0;
    for (const r of this.entries.values()) n += r.size;
    return n;
  }

  has(key) { return this.entries.has(key); }
  get(key) { return this.entries.get(key); }

  append(rec) {
    // 串起來寫，避免並行上傳時兩行交錯
    this.writeChain = this.writeChain.then(async () => {
      const fh = await fsp.open(this.indexPath, 'a');
      try {
        await fh.write(JSON.stringify(rec) + '\n');
        await fh.sync();
      } finally {
        await fh.close();
      }
    });
    return this.writeChain;
  }

  async add(rec) {
    await this.append(rec);
    this.entries.set(rec.key, rec);
  }

  async remove(key, reason) {
    await this.append({ key, removed: true, reason, at: new Date().toISOString() });
    this.entries.delete(key);
  }

  // 依拍攝日期放：2024/2024-05/IMG_0001.HEIC，撞名就加 (2)
  async reserveDest(filename, created, sha256) {
    const d = created ? new Date(created) : null;
    const valid = d && !isNaN(d);
    const y = valid ? String(d.getFullYear()) : '未知日期';
    const ym = valid ? `${y}-${String(d.getMonth() + 1).padStart(2, '0')}` : '未知日期';
    const dir = path.join(this.root, y, ym);
    await fsp.mkdir(dir, { recursive: true });
    const safe = sanitize(filename);
    const ext = path.extname(safe);
    const base = safe.slice(0, safe.length - ext.length);
    for (let i = 1; i < 100000; i++) {
      const name = i === 1 ? safe : `${base} (${i})${ext}`;
      const full = path.join(dir, name);
      const lower = full.toLowerCase(); // Windows 檔名不分大小寫
      if (this.reservedPaths.has(lower)) continue;
      if (fs.existsSync(full)) {
        // 同名同內容（例如索引遺失後重傳）就直接沿用
        if (sha256 && (await hashFile(full)) === sha256) {
          this.reservedPaths.add(lower);
          return { full, existing: true };
        }
        continue;
      }
      this.reservedPaths.add(lower);
      return { full, existing: false };
    }
    throw new Error('找不到可用檔名');
  }

  release(full) { this.reservedPaths.delete(full.toLowerCase()); }

  rel(full) { return path.relative(this.root, full).split(path.sep).join('/'); }
  abs(rel) { return path.join(this.root, ...rel.split('/')); }
}

function sanitize(name) {
  let s = String(name || 'unnamed').replace(/[<>:"/\\|?*\x00-\x1f]/g, '_').trim();
  s = s.replace(/[. ]+$/, '');
  if (!s) s = 'unnamed';
  if (/^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$/i.test(s)) s = '_' + s;
  return s.slice(0, 180);
}

function hashFile(file) {
  return new Promise((resolve, reject) => {
    const h = crypto.createHash('sha256');
    fs.createReadStream(file)
      .on('data', (c) => h.update(c))
      .on('error', reject)
      .on('end', () => resolve(h.digest('hex')));
  });
}

module.exports = { Store, hashFile, sanitize, META };
