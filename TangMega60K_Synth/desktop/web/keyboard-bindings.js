/* 电脑快捷键的数据模型：与MIDI音高映射、BLE协议和界面分别管理。 */
(function (root) {
    "use strict";
    const defaults = [
        "KeyZ",
        "KeyS",
        "KeyX",
        "KeyD",
        "KeyC",
        "KeyV",
        "KeyG",
        "KeyB",
        "KeyH",
        "KeyN",
        "KeyJ",
        "KeyM",
        "KeyQ",
        "Digit2",
        "KeyW",
        "Digit3",
        "KeyE",
        "KeyR",
        "Digit5",
        "KeyT",
        "Digit6",
        "KeyY",
        "Digit7",
        "KeyU",
        "KeyI",
    ];
    const symbols = {
        Comma: ",",
        Period: ".",
        Slash: "/",
        Semicolon: ";",
        Quote: "'",
        BracketLeft: "[",
        BracketRight: "]",
        Backslash: "\\",
        Minus: "-",
        Equal: "=",
        Backquote: "`",
        NumpadAdd: "Num +",
        NumpadSubtract: "Num -",
        NumpadMultiply: "Num *",
        NumpadDivide: "Num /",
        NumpadDecimal: "Num .",
    };
    function supported(code) {
        return (
            typeof code === "string" &&
            (/^Key[A-Z]$/.test(code) ||
                /^Digit[0-9]$/.test(code) ||
                /^Numpad[0-9]$/.test(code) ||
                Object.hasOwn(symbols, code))
        );
    }
    function validate(codes) {
        if (!Array.isArray(codes) || codes.length !== 25)
            throw Error("快捷键必须对应25个琴键");
        const seen = new Set();
        return Array.from(codes, (code, index) => {
            if (code === null) return null;
            if (!supported(code))
                throw Error(
                    `第${index + 1}键不支持该按键；请选择字母、数字或常用标点，Esc保留为全部停止`,
                );
            if (seen.has(code))
                throw Error(`${label(code)}重复分配，请先清除原绑定`);
            seen.add(code);
            return code;
        });
    }
    function label(code) {
        if (code === null) return "未绑定";
        return (
            symbols[code] ||
            code.replace(/^Key|^Digit/, "").replace(/^Numpad/, "Num ")
        );
    }
    function assign(codes, index, code) {
        if (!Number.isInteger(index) || index < 0 || index >= 25)
            throw Error("琴键编号应为1–25");
        const next = codes.slice();
        const owner = code === null ? -1 : next.indexOf(code);
        if (owner !== -1 && owner !== index)
            throw Error(
                `${label(code)}已分配给第${owner + 1}键，请先清除该绑定`,
            );
        next[index] = code;
        return validate(next);
    }
    class KeyboardBindings {
        constructor(codes = defaults) {
            this.codes = validate(codes);
        }
        snapshot() {
            return this.codes.slice();
        }
        apply(codes) {
            this.codes = validate(codes);
        }
        index(code) {
            return code ? this.codes.indexOf(code) : -1;
        }
        isDefault() {
            return this.codes.every((code, i) => code === defaults[i]);
        }
    }
    const api = {
        defaults: Object.freeze(defaults),
        supported,
        validate,
        label,
        assign,
        KeyboardBindings,
    };
    if (typeof module !== "undefined") module.exports = api;
    root.ShortcutBindings = api;
})(typeof globalThis === "undefined" ? window : globalThis);
