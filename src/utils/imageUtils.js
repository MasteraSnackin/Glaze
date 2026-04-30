export function fileToDataUrl(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(file);
    });
}

const MIME_MAP = {
    png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg',
    webp: 'image/webp', gif: 'image/gif', avif: 'image/avif',
    apng: 'image/apng', bmp: 'image/bmp', jfif: 'image/jpeg'
};

export function blobToDataUrl(blob, ext) {
    const mime = MIME_MAP[ext] || 'image/png';
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = reject;
        reader.readAsDataURL(new File([blob], 'asset', { type: mime }));
    });
}
