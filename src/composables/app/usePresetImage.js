export function usePresetImage({ currentPreset }) {
    function triggerImageUpload() {
        document.getElementById('preset-image-input').click();
    }

    async function compressImage(base64Str, maxWidth = 1200, maxHeight = 800, quality = 0.7) {
        return new Promise((resolve) => {
            const img = new Image();
            img.src = base64Str;
            img.onload = () => {
                const canvas = document.createElement('canvas');
                let width = img.width;
                let height = img.height;
                if (width > height) {
                    if (width > maxWidth) { height *= maxWidth / width; width = maxWidth; }
                } else {
                    if (height > maxHeight) { width *= maxHeight / height; height = maxHeight; }
                }
                canvas.width = width;
                canvas.height = height;
                const ctx = canvas.getContext('2d');
                ctx.drawImage(img, 0, 0, width, height);
                resolve(canvas.toDataURL('image/jpeg', quality));
            };
        });
    }

    function onImageSelected(event) {
        const file = event.target.files[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = async (e) => {
            const compressed = await compressImage(e.target.result);
            currentPreset.value.image = compressed;
        };
        reader.readAsDataURL(file);
    }

    return { triggerImageUpload, compressImage, onImageSelected };
}
