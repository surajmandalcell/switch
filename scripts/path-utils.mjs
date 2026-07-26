export function normalizeRepositoryPath(value) {
  return String(value).replaceAll('\\', '/');
}
