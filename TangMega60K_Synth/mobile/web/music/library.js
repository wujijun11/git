/* 手机曲库业务：原生HTTPS桥、本地文件、MIDI分析。此模块不发送演奏命令。 */
(function (root) {
    "use strict";
    let sequence = 0;
    const pending = new Map();
    root.nativeMusicResult = function (id, result) {
        const request = pending.get(id);
        if (!request) return;
        pending.delete(id);
        clearTimeout(request.timer);
        result.ok
            ? request.resolve(result)
            : request.reject(Error(result.error || "曲库请求失败"));
    };
    function nativeRequest(request) {
        if (!root.AndroidBle || !root.AndroidBle.musicRequest)
            return Promise.reject(
                Error("在线曲库请使用新版Android APK；浏览器仍可导入本地MIDI"),
            );
        return new Promise((resolve, reject) => {
            const id = ++sequence;
            const timer = setTimeout(() => {
                pending.delete(id);
                reject(Error("曲库请求超时，请稍后重试"));
            }, 45000);
            pending.set(id, { resolve, reject, timer });
            try {
                root.AndroidBle.musicRequest(JSON.stringify(request), id);
            } catch (error) {
                pending.delete(id);
                clearTimeout(timer);
                reject(error);
            }
        });
    }
    class MobileMusicLibrary {
        constructor() {
            this.files = new Map();
            this.serial = 0;
        }
        search(query, offset = 0) {
            return nativeRequest({ action: "search", query, offset });
        }
        recommend(batch = 0, refresh = false) {
            return nativeRequest({ action: "recommend", batch, refresh });
        }
        async fetch(item) {
            const result = await nativeRequest({ action: "fetch", item });
            return result.files.map((file) => {
                const data = Uint8Array.from(atob(file.base64), (c) =>
                    c.charCodeAt(0),
                );
                return this.add(data, file.name, file.attribution);
            });
        }
        async open(file) {
            if (!file || file.size > 4 * 1024 * 1024)
                throw Error("请选择4MiB以内的MID/MIDI文件");
            return [
                this.add(new Uint8Array(await file.arrayBuffer()), file.name, {
                    provider: "local",
                    title: file.name,
                    license: "用户自行确认授权",
                }),
            ];
        }
        add(bytes, name, attribution) {
            const info = root.MidiScore.parse(bytes),
                token = String(++this.serial);
            // 只保留最近32份解析数据，切换曲谱不累计占用手机内存。
            if (this.files.size >= 32)
                this.files.delete(this.files.keys().next().value);
            this.files.set(token, { info, name, attribution });
            return {
                token,
                name,
                tracks: info.tracks,
                durationMs: info.durationMs,
            };
        }
        prepare(token, options) {
            const file = this.files.get(token);
            if (!file) throw Error("文件已过期，请重新打开");
            return root.MidiScore.convert(
                file.info,
                file.name,
                options,
                file.attribution,
            );
        }
    }
    root.MobileMusicLibrary = MobileMusicLibrary;
})(typeof globalThis === "undefined" ? window : globalThis);
