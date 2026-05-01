if (typeof localStorage === 'undefined') {
    globalThis.localStorage = {
        _data: {},
        getItem(key) { return Object.prototype.hasOwnProperty.call(this._data, key) ? this._data[key] : null; },
        setItem(key, value) { this._data[key] = String(value); },
        removeItem(key) { delete this._data[key]; },
        clear() { this._data = {}; }
    };
}
