import { sanitizeCssText, sanitizeStyleDeclaration } from './css_sanitizer.js';

const BLOCKED_ELEMENTS = new Set([
  'script', 'iframe', 'object', 'embed', 'form', 'math', 'meta',
  'link', 'base',
  // Preserve formatter-generated static <svg><path> icons, but reject SVG
  // features that can load resources, embed HTML, or trigger animation.
  'foreignobject', 'animate', 'animatemotion', 'animatetransform', 'set',
  'use', 'image', 'feimage',
]);

const URL_ATTRIBUTES = new Set([
  'href', 'src', 'xlink:href', 'action', 'formaction', 'poster',
]);

const SAFE_IMAGE_DATA_URL = /^data:image\/(?:png|jpe?g|webp|gif|avif);base64,/i;

// ExtBlock HTML is inserted into the light DOM, so its `<style>` rules are
// pinned to the block body instead of leaking into the app chrome. Message
// HTML needs no prefix — it is written into a per-message shadow root.
const EXT_BLOCK_CSS_SCOPE = '.ext-block-content';

function isSafeDataUrl(element, attributeName, value) {
  if (!SAFE_IMAGE_DATA_URL.test(value)) return false;
  const localName = element.localName.toLowerCase();
  return attributeName === 'src' &&
    (localName === 'img' || localName === 'source');
}

// Message and ExtBlock CSS keeps working while message scripts are disabled;
// the declaration-level policy lives in css_sanitizer.js.
function sanitizeStyleAttribute(element) {
  sanitizeStyleDeclaration(element.style);
  if (!element.getAttribute('style')) element.removeAttribute('style');
}

function sanitizeStyleElement(element, cssScope) {
  const safe = sanitizeCssText(element.textContent, cssScope);
  if (!safe) {
    element.remove();
    return;
  }
  // media/type/nonce/blocking attributes carry no styling the block needs.
  for (const attribute of Array.from(element.attributes)) {
    element.removeAttribute(attribute.name);
  }
  element.textContent = safe;
}

function sanitizeHtml(html, cssScope) {
  const template = document.createElement('template');
  template.innerHTML = String(html == null ? '' : html);

  for (const element of Array.from(template.content.querySelectorAll('*'))) {
    const localName = element.localName.toLowerCase();
    if (BLOCKED_ELEMENTS.has(localName)) {
      element.remove();
      continue;
    }
    if (localName === 'style') {
      sanitizeStyleElement(element, cssScope);
      continue;
    }
    for (const attribute of Array.from(element.attributes)) {
      const name = attribute.name.toLowerCase();
      if (name.startsWith('on') || name === 'srcdoc') {
        element.removeAttribute(attribute.name);
        continue;
      }
      if (name === 'style') {
        sanitizeStyleAttribute(element);
        continue;
      }
      if (!URL_ATTRIBUTES.has(name)) continue;
      const value = attribute.value.trim();
      const compact = value.replace(/[\u0000-\u0020]+/g, '').toLowerCase();
      if (compact.startsWith('javascript:') || compact.startsWith('vbscript:') ||
          (compact.startsWith('data:') &&
            !isSafeDataUrl(element, name, value))) {
        element.removeAttribute(attribute.name);
      }
    }
    if (element.hasAttribute('srcset')) {
      const candidates = element.getAttribute('srcset').split(',');
      const unsafe = candidates.some(candidate => {
        const value = candidate.trim().split(/\s+/)[0] || '';
        const compact = value.replace(/[\u0000-\u0020]+/g, '').toLowerCase();
        return compact.startsWith('javascript:') ||
          compact.startsWith('vbscript:') ||
          (compact.startsWith('data:') && !SAFE_IMAGE_DATA_URL.test(value));
      });
      if (unsafe) element.removeAttribute('srcset');
    }
  }

  return template.innerHTML;
}

export function sanitizeMessageHtml(html) {
  return sanitizeHtml(html, '');
}

export function sanitizeExtBlockHtml(html) {
  return sanitizeHtml(html, EXT_BLOCK_CSS_SCOPE);
}
