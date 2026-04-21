export function consumeSseDataLines(buffer = '', chunk = '') {
    const pending = `${buffer}${chunk}`;
    const lines = pending.split('\n');
    const remaining = lines.pop() || '';
    const dataLines = [];

    for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || !trimmed.startsWith('data: ')) continue;

        const dataStr = trimmed.substring(6);
        if (dataStr === '[DONE]') continue;
        dataLines.push(dataStr);
    }

    return { dataLines, remaining };
}

export function getTrailingSseDataLine(buffer = '') {
    const trimmed = buffer.trim();
    if (!trimmed.startsWith('data: ')) return null;

    const dataStr = trimmed.substring(6);
    return dataStr && dataStr !== '[DONE]' ? dataStr : null;
}
