const appExtensionInstallers = [];

export function registerAppExtensionInstaller(installer) {
    if (typeof installer !== 'function') {
        throw new Error('[appExtensions] Installer must be a function');
    }

    appExtensionInstallers.push(installer);

    return () => {
        const index = appExtensionInstallers.indexOf(installer);
        if (index !== -1) {
            appExtensionInstallers.splice(index, 1);
        }
    };
}

export function listAppExtensionInstallers() {
    return [...appExtensionInstallers];
}

export function initAppExtensions() {
    const disposers = [];

    for (const installer of appExtensionInstallers) {
        try {
            const dispose = installer();
            if (typeof dispose === 'function') {
                disposers.push(dispose);
            }
        } catch (error) {
            console.error('[appExtensions] Failed to install extension', error);
        }
    }

    return () => {
        for (const dispose of disposers) {
            try {
                dispose();
            } catch (error) {
                console.error('[appExtensions] Failed to dispose extension', error);
            }
        }
    };
}
