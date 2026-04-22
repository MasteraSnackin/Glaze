export function normalizeImgGenHtmlForEditing(text, iigMap) {
    if (!text) return text;

    const makeTag = (instruction) => `<img data-iig-instruction='${instruction}' src="[IMG:GEN]">`;

    const extractInstruction = (chunk) => {
        if (!chunk) return null;
        const m1 = chunk.match(/\bdata-iig-instruction='([^']*)'/i);
        if (m1?.[1] != null) return m1[1];
        const m2 = chunk.match(/\bdata-iig-instruction="([^"]*)"/i);
        if (m2?.[1] != null) return m2[1];
        return null;
    };

    text = text.replace(
        /<span\b[^>]*\bclass="[^"]*\bimggen-result-wrapper\b[^"]*"[^>]*>[\s\S]*?<\/span>/gi,
        (wrapperHtml) => {
            const instruction = extractInstruction(wrapperHtml);
            if (!instruction) return wrapperHtml;

            if (iigMap) {
                const mSrc = wrapperHtml.match(/src="([^"]+)"/i);
                const mId = wrapperHtml.match(/data-iig-id="([^"]+)"/i);
                if (mSrc && mSrc[1]) {
                    iigMap[instruction] = { dataUrl: mSrc[1], id: mId ? mId[1] : `iig_${Date.now()}` };
                }
            }
            return makeTag(instruction);
        }
    );

    text = text.replace(
        /<img\b[^>]*\bclass="[^"]*\bimggen-result\b[^"]*"[^>]*>/gi,
        (imgHtml) => {
            const instruction = extractInstruction(imgHtml);
            if (!instruction) return imgHtml;

            if (iigMap) {
                const mSrc = imgHtml.match(/src="([^"]+)"/i);
                const mId = imgHtml.match(/data-iig-id="([^"]+)"/i);
                if (mSrc && mSrc[1]) {
                    iigMap[instruction] = { dataUrl: mSrc[1], id: mId ? mId[1] : `iig_${Date.now()}` };
                }
            }
            return makeTag(instruction);
        }
    );

    text = text.replace(
        /<span\b[^>]*\bclass="[^"]*\bimggen-loading\b[^"]*"[^>]*>[\s\S]*?<\/span>/gi,
        (spanHtml) => {
            const instruction = extractInstruction(spanHtml);
            if (!instruction) return spanHtml;
            return makeTag(instruction);
        }
    );
    text = text.replace(
        /<span\b[^>]*\bclass="[^"]*\bimggen-error\b[^"]*"[^>]*>[\s\S]*?<\/span>/gi,
        (spanHtml) => {
            const instruction = extractInstruction(spanHtml);
            if (!instruction) return spanHtml;
            return makeTag(instruction);
        }
    );

    return text;
}

export function prepareEditText(text, iigMap) {
    text = normalizeImgGenHtmlForEditing(text, iigMap);

    const map = {};
    let idx = 0;
    const cleaned = text.replace(
        /(<img\b[^>]*\bdata-iig-instruction=[^>]*\bsrc=")([^"]{256,})("[^>]*>)/gi,
        (match, before, src, after) => {
            const key = `[IMG:SRC:${idx}]`;
            map[key] = src;
            idx++;
            return before + key + after;
        }
    );
    return { text: cleaned, map };
}

export function restoreEditText(text, map) {
    if (!map) return text;
    for (const [key, src] of Object.entries(map)) {
        text = text.replace(key, src);
    }
    return text;
}
