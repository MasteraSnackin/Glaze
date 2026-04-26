/**
 * Utilities for generating image thumbnails.
 */

/**
 * Generates a base64 thumbnail from an image source.
 * @param {string} imageSrc - The source of the image (base64 or URL).
 * @param {number} maxSize - Maximum width or height of the generated thumbnail.
 * @returns {Promise<string|null>} Base64 JPEG string of the thumbnail, or null on failure.
 */
export async function generateThumbnail(imageSrc, maxSize = 600) {
    if (!imageSrc) return null;
    return new Promise((resolve, reject) => {
        const img = new Image();
        img.onload = () => {
            let width = img.width;
            let height = img.height;
            if (width > height) {
                if (width > maxSize) {
                    height *= maxSize / width;
                    width = maxSize;
                }
            } else {
                if (height > maxSize) {
                    width *= maxSize / height;
                    height = maxSize;
                }
            }
            const canvas = document.createElement('canvas');
            canvas.width = width;
            canvas.height = height;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, width, height);
            resolve(canvas.toDataURL('image/jpeg', 0.8));
        };
        img.onerror = () => {
            console.warn('Could not load image for thumbnail generation', imageSrc.substring(0, 50));
            reject(new Error('Failed to load image'));
        };

        // Handle CORS if it's an external URL
        if (imageSrc.startsWith('http')) {
            img.crossOrigin = 'Anonymous';
        }

        img.src = imageSrc;
    });
}

/**
 * Generates both a standard thumbnail (600px) and a mini thumbnail (150px) from an image source.
 * @param {string} imageSrc - The source of the image (base64 or URL).
 * @returns {Promise<{ thumbnail: string|null, mini_thumbnail: string|null }>}
 */
export async function generateAllThumbnails(imageSrc) {
    if (!imageSrc) return { thumbnail: null, mini_thumbnail: null };
    const [thumbnail, mini_thumbnail] = await Promise.all([
        generateThumbnail(imageSrc, 600).catch(() => null),
        generateThumbnail(imageSrc, 150).catch(() => null),
    ]);
    return { thumbnail, mini_thumbnail };
}
