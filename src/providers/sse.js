export async function* parseSse(body, signal) {
  if (!body) return;
  const decoder = new TextDecoder();
  let buffer = '';
  for await (const chunk of body) {
    if (signal?.aborted) throw Object.assign(new DOMException('Aborted', 'AbortError'), { code: 'CLIENT_ABORTED' });
    buffer += (typeof chunk === 'string' ? chunk : decoder.decode(chunk, { stream: true })).replace(/\r\n/g, '\n');
    let boundary;
    while ((boundary = buffer.indexOf('\n\n')) >= 0) {
      const raw = buffer.slice(0, boundary);
      buffer = buffer.slice(boundary + 2);
      const event = { event: 'message', data: '' };
      for (const line of raw.split('\n')) {
        if (line.startsWith('event:')) event.event = line.slice(6).trim();
        if (line.startsWith('data:')) event.data += `${event.data ? '\n' : ''}${line.slice(5).trimStart()}`;
      }
      if (event.data) yield event;
    }
  }
  if (buffer.trim()) yield { event: 'message', data: buffer.trim().replace(/^data:\s?/, '') };
}

export function encodeSse({ event, data, comment }) {
  if (comment) return `: ${String(comment).replaceAll('\n', ' ')}\n\n`;
  const payload = typeof data === 'string' ? data : JSON.stringify(data);
  return `${event ? `event: ${event}\n` : ''}${payload.split('\n').map((line) => `data: ${line}`).join('\n')}\n\n`;
}
