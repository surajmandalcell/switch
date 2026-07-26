import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createDefaultConfig, normalizeConfig } from '../domain/config.js';

export class ConfigStore {
  constructor(filePath) {
    this.filePath = filePath;
    this.config = null;
    this.writeChain = Promise.resolve();
  }

  async load() {
    try {
      this.config = normalizeConfig(JSON.parse(await readFile(this.filePath, 'utf8')));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      this.config = createDefaultConfig();
      await this.save(this.config);
    }
    return this.config;
  }

  get() {
    return this.config ?? createDefaultConfig();
  }

  async update(mutator) {
    const operation = async () => {
      const next = normalizeConfig(await mutator(structuredClone(this.get())));
      next.revision = this.get().revision + 1;
      await this.persist(next);
      this.config = next;
      return next;
    };
    this.writeChain = this.writeChain.then(operation, operation);
    return this.writeChain;
  }

  async save(config) {
    const next = normalizeConfig(config);
    await this.persist(next);
    this.config = next;
    return next;
  }

  async persist(config) {
    await mkdir(path.dirname(this.filePath), { recursive: true });
    const temporary = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    await writeFile(temporary, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, this.filePath);
  }
}
