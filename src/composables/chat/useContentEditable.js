import { nextTick } from 'vue';
import { formatInputPreview } from '@/utils/textFormatter.js';

export function getCaretIndex(element) {
    let position = 0;
    try {
        const selection = window.getSelection?.();
        if (!selection || selection.rangeCount === 0) return position;
        const range = selection.getRangeAt(0);
        if (!range) return position;
        const preCaretRange = range.cloneRange();
        preCaretRange.selectNodeContents(element);
        preCaretRange.setEnd(range.endContainer, range.endOffset);
        const tempDiv = document.createElement('div');
        tempDiv.appendChild(preCaretRange.cloneContents());
        const visualBrs = tempDiv.querySelectorAll('.visual-br');
        visualBrs.forEach(br => br.remove());
        const brs = tempDiv.querySelectorAll('br');
        brs.forEach(br => {
            const textNode = document.createTextNode('\n');
            br.parentNode.replaceChild(textNode, br);
        });
        let text = tempDiv.textContent || '';
        text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
        position = text.length;
    } catch (_e) {
        // Selection API can throw on iOS/WKWebView during keyboard transitions
    }
    return position;
}

export function setCaretPosition(element, pos) {
    try {
        const sel = window.getSelection?.();
        if (!sel) return;
        const range = document.createRange();
        let currentPos = 0;
        function traverse(node) {
            if (node.nodeType === 3) {
                const len = node.nodeValue.length;
                if (currentPos + len >= pos) {
                    range.setStart(node, pos - currentPos);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    return true;
                }
                currentPos += len;
            } else if (node.nodeName === 'BR') {
                if (node.classList.contains('visual-br')) return false;
                if (currentPos === pos) {
                    const index = Array.from(node.parentNode.childNodes).indexOf(node);
                    range.setStart(node.parentNode, index);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    return true;
                }
                currentPos += 1;
                if (currentPos === pos) {
                    const index = Array.from(node.parentNode.childNodes).indexOf(node);
                    range.setStart(node.parentNode, index + 1);
                    range.collapse(true);
                    sel.removeAllRanges();
                    sel.addRange(range);
                    return true;
                }
            } else {
                for (let i = 0; i < node.childNodes.length; i++) {
                    if (traverse(node.childNodes[i])) return true;
                }
            }
            return false;
        }
        if (!traverse(element)) {
            range.selectNodeContents(element);
            range.collapse(false);
            sel.removeAllRanges();
            sel.addRange(range);
        }
    } catch (_e) {
        // Selection API can throw on iOS/WKWebView during keyboard transitions
    }
}

export function getTextFromContentEditable(el) {
    const clone = el.cloneNode(true);
    const hasVisualBr = !!clone.querySelector('.visual-br');
    const visualBrs = clone.querySelectorAll('.visual-br');
    visualBrs.forEach(br => br.remove());
    
    const originalText = clone.textContent || '';
    const brs = clone.querySelectorAll('br');
    brs.forEach(br => {
        const textNode = document.createTextNode('\n');
        br.parentNode.replaceChild(textNode, br);
    });
    
    let text = clone.textContent || '';
    text = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    
    if (originalText === '' && text === '\n' && !hasVisualBr) {
        return '';
    }
    return text;
}

export function updateInputPreview(chatInputRef, modelValue, isComposing, forcedCaretPos = null) {
    if (!chatInputRef || isComposing) return;
    const el = chatInputRef;
    if (!el.isConnected) return;
    const isActive = document.activeElement === el;
    const currentCaret = (isActive || forcedCaretPos !== null) ? (forcedCaretPos !== null ? forcedCaretPos : getCaretIndex(el)) : 0;
    
    let formatted = modelValue ? formatInputPreview(modelValue) : '';
    if (modelValue && modelValue.endsWith('\n')) {
        formatted += '<br class="visual-br">';
    }
    
    if (el.innerHTML !== formatted) {
        el.innerHTML = formatted;
        if (isActive || forcedCaretPos !== null) {
            nextTick(() => { if (el.isConnected && document.activeElement === el) setCaretPosition(el, currentCaret); });
        }
    } else if (forcedCaretPos !== null && isActive) {
        nextTick(() => { if (el.isConnected && document.activeElement === el) setCaretPosition(el, currentCaret); });
    }
}
