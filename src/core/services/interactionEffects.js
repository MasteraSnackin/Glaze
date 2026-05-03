export function attachRipple(el) {
    if (el.dataset.rippleInit) return;
    el.dataset.rippleInit = 'true';

    if (window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
        attachHoverGlow(el);
        return;
    }

    const style = window.getComputedStyle(el);
    if (style.position === 'static') {
        el.style.position = 'relative';
    }

    el.style.overflow = 'hidden';

    el.addEventListener('pointerdown', function (e) {
        const circle = document.createElement('span');
        const diameter = Math.max(this.clientWidth, this.clientHeight);
        const radius = diameter / 2;

        const rect = this.getBoundingClientRect();

        circle.style.width = circle.style.height = `${diameter}px`;
        circle.style.left = `${e.clientX - rect.left - radius}px`;
        circle.style.top = `${e.clientY - rect.top - radius}px`;
        circle.classList.add('ripple');

        circle.style.background = `radial-gradient(circle, rgba(var(--vk-blue-rgb), 0.15) 0%, transparent 70%)`;

        circle.addEventListener('animationend', () => {
            circle.remove();
        });

        this.appendChild(circle);
    });
}

export function attachHoverGlow(el) {
    if (el.dataset.glowInit) return;
    el.dataset.glowInit = 'true';
    el.classList.add('has-hover-glow');

    const style = window.getComputedStyle(el);
    if (style.position === 'static') {
        el.style.position = 'relative';
    }

    el.style.overflow = 'hidden';

    const onMove = (e) => {
        const rect = el.getBoundingClientRect();
        const x = e.clientX - rect.left;
        const y = e.clientY - rect.top;
        el.style.setProperty('--glow-x', `${x}px`);
        el.style.setProperty('--glow-y', `${y}px`);
    };

    el.addEventListener('mousemove', onMove);
    el.addEventListener('mouseenter', () => el.classList.add('hover-glow-active'));
    el.addEventListener('mouseleave', () => el.classList.remove('hover-glow-active'));
}

let _rippleDelegationAdded = false;

export function initRipple() {
    if (!document.getElementById('ripple-effect-styles')) {
        const style = document.createElement('style');
        style.id = 'ripple-effect-styles';
        style.textContent = `
            @keyframes ripple-glow {
                0% { transform: scale(0.2); opacity: 1; }
                100% { transform: scale(2.5); opacity: 0; }
            }
            .ripple {
                position: absolute;
                border-radius: 50%;
                pointer-events: none;
                filter: blur(10px);
                animation: ripple-glow 0.8s ease-out forwards;
                z-index: -1;
            }
            .hover-glow-active {
                position: relative;
                overflow: hidden;
            }
            .has-hover-glow::before {
                content: "";
                position: absolute;
                top: 0; left: 0; right: 0; bottom: 0;
                background: radial-gradient(circle 200px at var(--glow-x) var(--glow-y), rgba(var(--vk-blue-rgb), 0.07) 0%, rgba(var(--vk-blue-rgb), 0.04) 38%, rgba(var(--vk-blue-rgb), 0.015) 68%, transparent 100%);
                pointer-events: none;
                z-index: -1;
                opacity: 0;
                transition: opacity 0.4s ease;
            }
            .hover-glow-active::before {
                opacity: 1;
            }
        `;
        document.head.appendChild(style);
    }

    const elements = document.querySelectorAll('.bottom-nav, .app-header:not(.window-app-header), .menu-group, .preset-selector, .conn-badge, .glass-panel, .segmented-control, .bottom-sheet-content');
    elements.forEach(attachRipple);

    if (!_rippleDelegationAdded) {
        _rippleDelegationAdded = true;
        document.addEventListener('pointerdown', function (e) {
            if (window.matchMedia('(hover: hover) and (pointer: fine)').matches) return;

            const trigger = e.target.closest('.list-item, .triggered-item-card, .list-container');
            if (!trigger || trigger.dataset.rippleInit) return;

            const bgContainer = trigger.closest('.view-content-wrapper') || document.body;

            const circle = document.createElement('span');
            const diameter = Math.max(window.innerWidth, window.innerHeight) * 2;
            const radius = diameter / 2;

            circle.style.width = circle.style.height = `${diameter}px`;
            circle.style.left = `${e.clientX - radius}px`;
            circle.style.top = `${e.clientY - radius}px`;
            circle.style.position = 'fixed';
            circle.style.zIndex = '0';
            circle.style.pointerEvents = 'none';
            circle.classList.add('ripple');

            circle.style.background = `radial-gradient(circle, rgba(var(--vk-blue-rgb), 0.1) 0%, transparent 70%)`;

            circle.addEventListener('animationend', () => {
                circle.remove();
            });

            bgContainer.appendChild(circle);
        });
    }
}
