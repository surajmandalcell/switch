import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile, chmod } from 'node:fs/promises';
import path from 'node:path';

export class SecretStore {
  constructor({ vaultPath, keyPath, safeStorage = null }) {
    this.vaultPath = vaultPath;
    this.keyPath = keyPath;
    this.safeStorage = safeStorage;
    this.vault = { version: 1, secrets: {} };
    this.key = null;
  }

  async load() {
    try { this.vault = JSON.parse(await readFile(this.vaultPath, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; await this.persist(); }
    if (!this.canUseSafeStorage()) this.key = await this.loadOrCreateKey();
    return this;
  }

  canUseSafeStorage() {
    return Boolean(this.safeStorage?.isEncryptionAvailable?.());
  }

  async set(value, ref = `secret_${randomUUID()}`) {
    const text = String(value);
    if (this.canUseSafeStorage()) {
      const encrypted = this.safeStorage.encryptString(text);
      this.vault.secrets[ref] = { mode: 'safe-storage', data: Buffer.from(encrypted).toString('base64') };
    } else {
      if (!this.key) this.key = await this.loadOrCreateKey();
      const iv = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', this.key, iv);
      const encrypted = Buffer.concat([cipher.update(text, 'utf8'), cipher.final()]);
      this.vault.secrets[ref] = { mode: 'aes-256-gcm', iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: encrypted.toString('base64') };
    }
    await this.persist();
    return ref;
  }

  get(ref) {
    if (!ref) return null;
    const record = this.vault.secrets[ref];
    if (!record) return null;
    if (record.mode === 'safe-storage') return this.safeStorage.decryptString(Buffer.from(record.data, 'base64'));
    if (record.mode === 'aes-256-gcm') {
      if (!this.key) throw new Error('Secret store key is not loaded.');
      const decipher = createDecipheriv('aes-256-gcm', this.key, Buffer.from(record.iv, 'base64'));
      decipher.setAuthTag(Buffer.from(record.tag, 'base64'));
      return Buffer.concat([decipher.update(Buffer.from(record.data, 'base64')), decipher.final()]).toString('utf8');
    }
    throw new Error(`Unsupported secret mode: ${record.mode}`);
  }

  async delete(ref) {
    const existed = Boolean(this.vault.secrets[ref]);
    delete this.vault.secrets[ref];
    if (existed) await this.persist();
    return existed;
  }

  listRefs() {
    return Object.keys(this.vault.secrets).sort();
  }

  async loadOrCreateKey() {
    await mkdir(path.dirname(this.keyPath), { recursive: true });
    try {
      const key = Buffer.from(await readFile(this.keyPath, 'utf8'), 'base64');
      if (key.length !== 32) throw new Error('Invalid secret-store key length.');
      return key;
    } catch (error) {
      if (error.code && error.code !== 'ENOENT') throw error;
      const key = randomBytes(32);
      await writeFile(this.keyPath, key.toString('base64'), { mode: 0o600 });
      await chmod(this.keyPath, 0o600).catch(() => {});
      return key;
    }
  }

  async persist() {
    await mkdir(path.dirname(this.vaultPath), { recursive: true });
    const temporary = `${this.vaultPath}.${process.pid}.${Date.now()}.tmp`;
    await writeFile(temporary, `${JSON.stringify(this.vault, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, this.vaultPath);
  }
}
