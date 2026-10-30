"use strict";
const P = RemoteProtocol,
    $ = (id) => document.getElementById(id);
let session = null,
    device = null,
    writeCharacteristic = null,
    decoder = null,
    score = null,
    recorded = [],
    isMock = false,
    telemetryState = null;
let map = Array.from({ length: 25 }, (_, i) => 60 + i),
    held = new Map(),
    dataPackets = new Map(),
    waiters = new Map(),
    nativeWrite = null,
    testGeneration = 0,
    testActive = false;
let expressionControl = null,
    connectionGeneration = 0,
    webConnection = null,
    controlReady = false;
let scoreLoadGeneration = 0,
    scoreDownload = null,
    dataOperation = null;
let scoreCapacity = 1024,
    musicPanel = null;
let realtimePlayback = null;
let sustainState = { supported: false, enabled: false, deferredVoices: 0 };
let sustainSupport = false;
let boardMode = null,
    modeSupport = false;
function beginScoreLoad() {
    const id = ++scoreLoadGeneration;
    if (scoreDownload) scoreDownload.abort();
    scoreDownload = null;
    if (window.AndroidBle) AndroidBle.cancelScoreLoad();
    return id;
}
function dataIdle() {
    if (realtimePlayback?.busy) throw Error("请先停止蓝牙实时播放");
    if (dataOperation)
        throw new Error("正在" + dataOperation.name + "，请先完成或停止此操作");
    if (testActive) throw new Error("64声部测试正在运行，请先全部停止");
}
function beginDataOperation(name) {
    dataIdle();
    const op = { name, owner: session, cancelled: false };
    dataOperation = op;
    return op;
}
function checkDataOperation(op) {
    checkSession(op.owner);
    if (op.cancelled || op !== dataOperation)
        throw new Error(op.name + "已取消");
}
function endDataOperation(op) {
    if (dataOperation === op) dataOperation = null;
}
function cancelDataOperation() {
    if (dataOperation) dataOperation.cancelled = true;
}
function idleCommand(op, payload) {
    dataIdle();
    return command(op, payload);
}
function setControlReady(ready) {
    controlReady = ready;
    renderSustain();
    for (const id of [
        "timbre",
        "effect",
        "velocity",
        "gain",
        "bend",
        "vibrato",
        "mapKey",
        "mapNote",
        "mapApply",
    ])
        $(id).disabled = !ready;
    for (const key of $("keys").children) key.disabled = !ready;
}
function cancelExpression() {
    if (expressionControl) clearTimeout(expressionControl.timer);
    expressionControl = null;
}
function checkSession(owner) {
    if (!owner || owner !== session || owner.closed)
        throw new Error("连接已变化，请重新开始此操作");
}
function log(s) {
    $("log").textContent = (
        new Date().toLocaleTimeString() +
        " " +
        s +
        "\n" +
        $("log").textContent
    ).slice(0, 9000);
}
function status(s) {
    $("status").textContent = s;
    log(s);
}
function nextSeq() {
    try {
        return Number(localStorage.getItem("tang-next-seq") || 0) & 255;
    } catch (e) {
        return 0;
    }
}
function saveSeq(n) {
    try {
        localStorage.setItem("tang-next-seq", String(n));
    } catch (e) {}
}
function clearHeld() {
    for (const b of $("keys").children) b.classList.remove("pressed");
    held.clear();
}
function disposeWebConnection(c) {
    if (!c) return;
    if (c.notify && c.onNotify)
        c.notify.removeEventListener("characteristicvaluechanged", c.onNotify);
    c.device.removeEventListener("gattserverdisconnected", c.onDisconnect);
    if (
        c.device.gatt.connected &&
        (!webConnection || webConnection.device !== c.device)
    )
        c.device.gatt.disconnect();
}
function closeWebConnection() {
    const c = webConnection;
    webConnection = null;
    device = null;
    writeCharacteristic = null;
    disposeWebConnection(c);
}
function lost(s) {
    realtimePlayback?.stop();
    boardMode = null;
    modeSupport = false;
    sustainSupport = false;
    sustainState = { supported: false, enabled: false, deferredVoices: 0 };
    if ($("boardMode"))
        $("boardMode").textContent = "板上模式：未连接，无法确认当前状态";
    setControlReady(false);
    connectionGeneration++;
    closeWebConnection();
    testGeneration++;
    testActive = false;
    cancelExpression();
    cancelDataOperation();
    dataOperation = null;
    if (session) session.close(new Error(s));
    session = null;
    decoder = null;
    if (nativeWrite) {
        nativeWrite.reject(new Error(s));
        nativeWrite = null;
    }
    clearHeld();
    for (const w of waiters.values()) {
        clearTimeout(w.timer);
        w.reject(new Error(s));
    }
    waiters.clear();
    dataPackets.clear();
    status(s);
}
function receive(p) {
    if (p.op === P.OP.SUSTAIN_STATUS) {
        try { sustainState = P.sustainStatus(p.payload); renderSustain(); }
        catch (error) { lost(error.message); return; }
    }
    if (p.op === P.OP.MODE_STATUS) {
        try {
            boardMode = P.modeStatus(p.payload);
            renderBoardMode(boardMode);
        } catch (error) {
            lost(error.message);
            return;
        }
    }
    if (
        p.op === P.OP.TELEMETRY ||
        p.op === P.OP.EVENT ||
        p.op === P.OP.MODE_STATUS || p.op === P.OP.SCORE_CAPABILITIES || p.op === P.OP.SUSTAIN_STATUS
    ) {
        const key = p.seq + ":" + p.op;
        dataPackets.set(key, p);
        if (dataPackets.size > 64)
            dataPackets.delete(dataPackets.keys().next().value);
        const w = waiters.get(key);
        if (w) {
            clearTimeout(w.timer);
            waiters.delete(key);
            w.resolve(p);
        }
        if (p.op === P.OP.TELEMETRY) {
            telemetryState = P.telemetry(p.payload);
            $("telemetry").textContent = JSON.stringify(
                telemetryState,
                null,
                2,
            );
            if (telemetryState.overflow)
                log("FPGA 报告资源溢出；请检查状态并全部停止");
        }
    }
}
function createSession(write, mock = false) {
    if (session) lost("旧连接已关闭");
    setControlReady(false);
    cancelExpression();
    isMock = mock;
    dataPackets.clear();
    const owner = new P.Session(write, {
        startSeq: nextSeq(),
        onSequence: (n) => {
            saveSeq(n);
            const sent = (n - 1) & 255;
            dataPackets.delete(sent + ":129");
            dataPackets.delete(sent + ":130");
        },
        onPacket: receive,
        onFatal: (e) => {
            if (session !== owner) return;
            lost(e.message);
            if (window.AndroidBle) AndroidBle.disconnect();
        },
    });
    session = owner;
    decoder = new P.StreamDecoder((p) => session === owner && owner.receive(p));
    return owner;
}
function getData(seq, op) {
    const key = seq + ":" + op;
    if (dataPackets.has(key)) return Promise.resolve(dataPackets.get(key));
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            waiters.delete(key);
            reject(new Error("FPGA 数据响应超时"));
        }, 2000);
        waiters.set(key, { resolve, reject, timer });
    });
}
async function command(op, p = [], owner = session, setup = false) {
    if (!owner) throw new Error("请先连接或进入协议模拟");
    checkSession(owner);
    if (!setup && !controlReady) throw new Error("FPGA 握手尚未完成，请稍候");
    return owner.send(op, p);
}
async function readback(selector, index = 0, owner = session, setup = false) {
    const ack = await command(
        P.OP.READBACK,
        [selector, ...P.le16(index)],
        owner,
        setup,
    );
    checkSession(owner);
    return getData(
        ack.seq,
        selector === 0
            ? P.OP.TELEMETRY
            : selector === 2
              ? P.OP.MODE_STATUS
              : selector === 3
                ? P.OP.SCORE_CAPABILITIES
              : selector === 5 ? P.OP.SUSTAIN_STATUS : P.OP.EVENT,
    );
}
function renderSustain() {
    const box = $("sustainEnabled"), label = $("sustainStatus");
    if (!box || !label) return;
    box.disabled = !controlReady || !sustainSupport;
    box.checked = controlReady && sustainSupport && sustainState.enabled;
    label.textContent = !controlReady ? "连接配套延音测试版后可用" : !sustainSupport ?
        "板上版本尚不支持延音" : (sustainState.enabled ? "延音已开启" : "延音已关闭") +
        " · 保留 " + sustainState.deferredVoices + " / 64 声部";
}
async function setSustain(enabled) {
    const owner = session;
    if (!sustainSupport) throw Error("板上未提供延音功能，请使用配套延音测试版");
    await command(P.OP.CONFIG, [2, enabled ? 1 : 0], owner);
    await readback(5, 0, owner);
    checkSession(owner);
}
function renderBoardMode(state) {
    const node = $("boardMode");
    if (!node) return;
    if (!state) {
        node.textContent = "板上模式：旧程序未提供模式回传";
        return;
    }
    $("timbre").value = String(state.timbre);
    $("effect").value = String(state.effect);
    node.textContent =
        "板上模式：" +
        (state.mainMenu
            ? "总菜单"
            : ["音色", "音区", "录放", "曲谱 / 指引"][state.page]) +
        " · " +
        ["正弦", "风琴", "钢琴", "FM电钢琴"][state.timbre] +
        " · 音区 " +
        (state.transpose > 0 ? "+" : "") +
        state.transpose +
        " 半音 · " +
        (state.recording
            ? "录制中"
            : state.playing
              ? "播放中"
              : state.guide
                ? "指引中"
                : "待机") +
        (state.busy ? " · 切换中" : "");
}
async function handshake(owner = session) {
    // Read-only probe is safe if a new app happens to reuse the router's last seq.
    const generation = connectionGeneration;
    try {
        await readback(0, 0, owner, true);
    } catch (e) {
        if (!e.message.includes("NACK status=1")) throw e;
        await readback(0, 0, owner, true);
    }
    await command(P.OP.TRANSPORT, [5], owner, true);
    modeSupport = false;
    boardMode = null;
    try {
        await readback(2, 0, owner, true);
        modeSupport = true;
    } catch (error) {
        if (!/NACK status=[13]/.test(error.message)) throw error;
        renderBoardMode(null);
    }
    sustainSupport = false;
    if ($("sustainEnabled")) {
        try { await readback(5, 0, owner, true); sustainSupport = true; }
        catch (error) { if (!/NACK status=[13]/.test(error.message)) throw error; }
    }
    // Reapply the visible settings after FPGA reset or reconnect so physical
    // keys and the controller do not silently disagree about mapping/timbre.
    for (let i = 0; i < 25; i++)
        await command(P.OP.MAP, [i, map[i]], owner, true);
    if (!modeSupport) {
        await command(P.OP.CONFIG, [0, Number($("timbre").value)], owner, true);
        await command(P.OP.CONFIG, [1, Number($("effect").value)], owner, true);
    }
    await expression(owner, true);
    await readback(0, 0, owner, true);
    checkSession(owner);
    if (generation !== connectionGeneration) throw new Error("蓝牙连接已取消");
    setControlReady(true);
    status(
        isMock
            ? "协议模拟已连接（无 BLE / FPGA 硬件）"
            : "蓝牙已连接，FPGA 握手通过",
    );
}
async function connectWeb() {
    // Cancel pending device prompts/discovery as well as an established session.
    await disconnect();
    const generation = ++connectionGeneration;
    if (window.AndroidBle) {
        AndroidBle.connect();
        status("原生蓝牙正在扫描，等待选择设备");
        return;
    }
    if (!navigator.bluetooth)
        throw new Error("此浏览器不提供 Web Bluetooth，请使用 Android APK");
    if (!window.isSecureContext)
        throw new Error("Web Bluetooth 需要 HTTPS 或 localhost");
    let c = null;
    const current = () => generation === connectionGeneration;
    const check = () => {
        if (!current()) throw new Error("蓝牙连接已取消");
    };
    try {
        const selected = await navigator.bluetooth.requestDevice({
            filters: [{ services: [P.UUID.service] }],
        });
        check();
        c = { device: selected, notify: null, owner: null, decoder: null };
        webConnection = c;
        device = selected;
        c.onDisconnect = () => {
            if (webConnection === c) lost("蓝牙已断开；重连后将发送全部停止");
        };
        selected.addEventListener("gattserverdisconnected", c.onDisconnect);
        const server = await selected.gatt.connect();
        check();
        const service = await server.getPrimaryService(P.UUID.service);
        check();
        const characteristic = await service.getCharacteristic(P.UUID.rx);
        check();
        c.notify = await service.getCharacteristic(P.UUID.tx);
        check();
        c.onNotify = (e) => {
            if (webConnection !== c || session !== c.owner || !c.decoder)
                return;
            const v = e.target.value;
            c.decoder.push(
                new Uint8Array(v.buffer, v.byteOffset, v.byteLength),
            );
        };
        c.notify.addEventListener("characteristicvaluechanged", c.onNotify);
        await c.notify.startNotifications();
        check();
        writeCharacteristic = characteristic;
        c.owner = createSession((b) =>
            characteristic.writeValueWithResponse
                ? characteristic.writeValueWithResponse(b)
                : characteristic.writeValue(b),
        );
        c.decoder = decoder;
        await handshake(c.owner);
        check();
    } catch (e) {
        // A late result from a cancelled attempt cannot replace or close a newer one.
        if (!current()) {
            disposeWebConnection(c);
            return;
        }
        lost(e.message);
        throw e;
    }
}
window.nativeBleState = function (state, message) {
    if (state === "ready") {
        createSession(
            (b) =>
                new Promise((resolve, reject) => {
                    nativeWrite = { resolve, reject };
                    AndroidBle.writeHex(
                        Array.from(b, (x) =>
                            x.toString(16).padStart(2, "0"),
                        ).join(""),
                    );
                }),
        );
        const owner = session;
        handshake(owner).catch((e) => {
            if (session !== owner) return;
            lost(e.message);
            AndroidBle.disconnect();
        });
    } else if (state === "disconnected" || state === "error") lost(message);
    else status(message);
};
window.nativeBleWriteComplete = function (ok, message) {
    if (nativeWrite) {
        const n = nativeWrite;
        nativeWrite = null;
        ok ? n.resolve() : n.reject(new Error(message));
    }
};
window.nativeBleReceive = function (hex) {
    if (decoder)
        decoder.push(
            Uint8Array.from(hex.match(/../g) || [], (s) => parseInt(s, 16)),
        );
};
window.nativeScoreLoaded = function (json, error, id) {
    if (id !== scoreLoadGeneration) return;
    try {
        if (error) throw new Error(error);
        setScore(JSON.parse(json));
    } catch (e) {
        status(e.message);
    }
};
async function disconnect() {
    await realtimePlayback?.stop();
    setControlReady(false);
    connectionGeneration++;
    testGeneration++;
    testActive = false;
    cancelExpression();
    const owner = session;
    if (owner) {
        try {
            await command(P.OP.TRANSPORT, [5], owner, true);
        } catch (e) {
            log(e.message);
        }
        if (session !== owner) return;
    }
    lost("已断开");
    if (window.AndroidBle) AndroidBle.disconnect();
}
async function test64() {
    dataIdle();
    const generation = ++testGeneration,
        owner = session;
    testActive = true;
    clearHeld();
    try {
        await command(4, [5], owner);
        for (let i = 0; i < 64; i++) {
            if (generation !== testGeneration) return;
            await command(P.OP.NOTE, P.note(36 + i, 64, 0, 1), owner);
        }
        const response = await readback(0, 0, owner);
        if (generation !== testGeneration) return;
        const state = P.telemetry(response.payload);
        if (state.activeVoices !== 64)
            throw new Error("测试未达到64声部，请查看状态");
        status(
            isMock
                ? "协议模拟：已发送64个不同音高（未验证硬件）"
                : "64个不同音高已发送；请测量频谱与采样率，按全部停止结束",
        );
    } catch (e) {
        if (generation === testGeneration) {
            testActive = false;
            testGeneration++;
            if (owner && session === owner)
                await command(4, [5], owner).catch(log);
        }
        throw e;
    }
}
function setScore(doc) {
    dataIdle();
    score = doc.transport === "realtime" ? RealtimeScore.validate(doc, map) : P.validateScore(doc, scoreCapacity);
    $("scoreInfo").textContent =
        score.title + " · " + score.rows.length + (score.transport === "realtime" ? " 个事件，点击蓝牙实时播放" : " 个事件，尚未上传");
    log("曲谱格式校验通过");
}
async function upload() {
    if (!score) throw new Error("请先加载曲谱");
    if (score.transport === "realtime") throw Error("请点击蓝牙实时播放；上传需重新按板上容量分析");
    // 切到旧版容量后再次校验，必须在任何硬件写入之前拒绝越界。
    P.validateScore(score, scoreCapacity);
    const op = beginDataOperation("上传曲谱"),
        owner = op.owner,
        uploadScore = score,
        oldMapping = map.slice();
    let mappingChanged = false;
    try {
        if(uploadScore.playback==="direct"){
            let capability;
            try{capability=P.scoreCapabilities((await readback(3,0,owner)).payload);}
            catch(error){if(error.message?.includes("NACK"))throw Error("板上程序不支持直接播放，请先下载DirectScore新版");throw error;}
            checkDataOperation(op);
            if(uploadScore.rows.length>capability.capacity)throw Error("超过板上实际事件容量");
        }
        const state = P.telemetry((await readback(0, 0, owner)).payload);
        checkDataOperation(op);
        if (state.recording) throw new Error("请先停止录制，再上传曲谱");
        await command(P.OP.TRANSPORT, [5], owner);
        checkDataOperation(op);
        clearHeld();
        await command(P.OP.SCORE_COMMIT,[0,0,1],owner);
        checkDataOperation(op);
        if (uploadScore.mapping) {
            mappingChanged = true;
            for (let i = 0; i < 25; i++) {
                checkDataOperation(op);
                await command(P.OP.MAP, [i, uploadScore.mapping[i]], owner);
                checkDataOperation(op);
            }
            applyVisibleMapping(uploadScore.mapping);
        }
        for (let i = 0; i < uploadScore.rows.length; i++) {
            checkDataOperation(op);
            await command(
                P.OP.SCORE_WRITE,
                P.scoreRow(i, uploadScore.rows[i]),
                owner,
            );
            checkDataOperation(op);
            if (score === uploadScore)
                $("scoreInfo").textContent =
                    "上传 " + (i + 1) + " / " + uploadScore.rows.length;
        }
        await command(
            P.OP.SCORE_COMMIT,
            [...P.le16(uploadScore.rows.length), uploadScore.playback==="direct"?2:0],
            owner,
        );
        checkDataOperation(op);
        if (score === uploadScore)
            $("scoreInfo").textContent =
                uploadScore.title +
                " · 已提交 " +
                uploadScore.rows.length +
                " 个事件";
        else log(uploadScore.title + " 已上传；当前显示的新曲谱尚未上传");
    } catch (error) {
        // 恢复只针对同一仍有效会话，绝不向重连后的设备发送旧映射。
        if (mappingChanged && session === owner && !owner.closed) {
            try {
                for (let i = 0; i < 25; i++) {
                    checkSession(owner);
                    await command(P.OP.MAP, [i, oldMapping[i]], owner);
                }
                applyVisibleMapping(oldMapping);
            } catch (restore) {
                log("键位恢复未完成，请重新连接或设置映射：" + restore.message);
            }
        }
        throw error;
    } finally {
        endDataOperation(op);
    }
}
function applyVisibleMapping(values) {
    map = values.slice();
    for (let i = 0; i < 25; i++)
        $("keys").children[i].textContent = i + " · MIDI " + map[i];
    $("mapNote").value = map[Number($("mapKey").value) || 0];
}
async function readRecording() {
    const op = beginDataOperation("回传录音"),
        owner = op.owner;
    try {
        await command(P.OP.TRANSPORT, [3], owner);
        checkDataOperation(op);
        const p = await readback(0, 0, owner),
            t = P.telemetry(p.payload);
        checkDataOperation(op);
        if (t.recordCount > 1024) throw new Error("FPGA 录音数量越界");
        const rows = [];
        for (let i = 0; i < t.recordCount; i++) {
            const row = P.event((await readback(1, i, owner)).payload);
            checkDataOperation(op);
            if (row.index !== i) throw new Error("录音索引不匹配");
            rows.push(row);
            $("recordInfo").textContent =
                rows.length + " / " + t.recordCount + " 条已回传";
        }
        recorded = rows;
        log("录音事件回传完成；声音仍由 FPGA 合成");
    } finally {
        endDataOperation(op);
    }
}
function exportRecording() {
    dataIdle();
    const data = {
        version: 1,
        type: "tang-synth-event-recording",
        title: "FPGA 演奏录音",
        rows: recorded,
    };
    const json = JSON.stringify(data, null, 2);
    if (window.AndroidBle) {
        AndroidBle.exportJson(json);
        return;
    }
    const a = document.createElement("a"),
        url = URL.createObjectURL(
            new Blob([json], { type: "application/json" }),
        );
    a.href = url;
    a.download = "tang-recording.json";
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
}
async function clearRecording() {
    const op = beginDataOperation("清空录音");
    try {
        await command(4, [4], op.owner);
        checkDataOperation(op);
        recorded = [];
        $("recordInfo").textContent = "0 条已回传";
    } finally {
        endDataOperation(op);
    }
}
async function loadScoreUrl() {
    const id = beginScoreLoad();
    try {
        const url = new URL($("scoreUrl").value);
        if (url.protocol !== "https:") throw new Error("在线曲谱只允许 HTTPS");
        if (window.AndroidBle) {
            AndroidBle.loadScoreUrl(url.href, id);
            return;
        }
        const controller = new AbortController();
        scoreDownload = controller;
        const response = await fetch(url.href, {
            credentials: "omit",
            signal: controller.signal,
        });
        if (id !== scoreLoadGeneration) return;
        if (!response.ok) throw new Error("HTTP " + response.status);
        const text = await response.text();
        if (id !== scoreLoadGeneration) return;
        if (new TextEncoder().encode(text).length > 16777216)
            throw new Error("曲谱 JSON 超过 16MiB");
        setScore(JSON.parse(text));
    } catch (e) {
        if (id === scoreLoadGeneration) status(e.message);
    } finally {
        if (id === scoreLoadGeneration) scoreDownload = null;
    }
}
async function loadScoreFile() {
    const id = beginScoreLoad();
    try {
        const f = $("scoreFile").files[0];
        if (!f) return;
        if (f.size > 16777216) throw new Error("JSON 超过 16MiB");
        const text = await f.text();
        if (id !== scoreLoadGeneration) return;
        setScore(JSON.parse(text));
    } catch (e) {
        if (id === scoreLoadGeneration) status(e.message);
    }
}
function bind(id, fn) {
    $(id).onclick = () =>
        Promise.resolve()
            .then(fn)
            .catch((e) => status(e.message));
}
function expression(owner = session, setup = false) {
    return command(
        P.OP.EXPRESSION,
        P.expression(
            Number($("gain").value),
            Number($("bend").value),
            Number($("vibrato").value),
        ),
        owner,
        setup,
    );
}
// Keep one expression request in flight and only the latest unsent snapshot.
// At most 25 updates/s; slow ACKs cannot accumulate a slider command backlog.
function scheduleExpression(id) {
    if (!session || session.closed || !controlReady) return;
    if (!expressionControl || expressionControl.owner !== session)
        expressionControl = {
            owner: session,
            pending: null,
            sending: false,
            timer: null,
            lastSent: -Infinity,
        };
    const c = expressionControl,
        mask = { gain: 1, bend: 2, vibrato: 4 }[id];
    if (!mask) return;
    const pendingMask = mask | (c.pending ? c.pending[0] : 0);
    c.pending = P.expression(
        Number($("gain").value),
        Number($("bend").value),
        Number($("vibrato").value),
    );
    // A phone gain/vibrato drag must not reset an active physical slider bend.
    c.pending[0] = pendingMask;
    pumpExpression(c);
}
function pumpExpression(c) {
    if (
        c !== expressionControl ||
        c.owner !== session ||
        c.owner.closed ||
        c.sending ||
        !c.pending
    )
        return;
    clearTimeout(c.timer);
    const wait = 40 - (performance.now() - c.lastSent);
    if (wait > 0) {
        c.timer = setTimeout(() => pumpExpression(c), wait);
        return;
    }
    const payload = c.pending;
    c.pending = null;
    c.sending = true;
    c.lastSent = performance.now();
    command(P.OP.EXPRESSION, payload, c.owner)
        .catch((e) => {
            if (c === expressionControl) status(e.message);
        })
        .finally(() => {
            c.sending = false;
            pumpExpression(c);
        });
}
for (let i = 0; i < 25; i++) {
    const opt = document.createElement("option");
    opt.value = i;
    opt.textContent = "键 " + i;
    $("mapKey").append(opt);
    const b = document.createElement("button");
    b.textContent = i + " · MIDI " + map[i];
    b.onpointerdown = (e) => {
        e.preventDefault();
        if (realtimePlayback.busy) { status("实时播放期间请使用实体琴键；手机琴键暂不发送"); return; }
        if (held.has(i)) return;
        if (!controlReady) {
            status(
                session
                    ? "FPGA 握手尚未完成，请稍候"
                    : "请先连接或进入协议模拟",
            );
            return;
        }
        const owner = session,
            same = Array.from(held.values()).find(
                (n) => n.owner === owner && n.midi === map[i],
            );
        const n = {
            midi: map[i],
            timbre: same ? same.timbre : Number($("timbre").value),
            owner,
            pointerId: e.pointerId,
        };
        held.set(i, n);
        b.classList.add("pressed");
        if (b.setPointerCapture) b.setPointerCapture(e.pointerId);
        // All phone keys use source 63. A duplicate pitch must stay held until
        // its last physical pointer is released, instead of sending an early OFF.
        if (same) return;
        command(
            P.OP.NOTE,
            P.note(n.midi, Number($("velocity").value), n.timbre, 1),
            owner,
        ).catch((err) => {
            if (session !== owner) return;
            status(err.message);
            clearHeld();
            if (owner) command(P.OP.TRANSPORT, [5], owner).catch(log);
        });
    };
    const release = (e) => {
        e.preventDefault();
        const n = held.get(i);
        if (!n || n.pointerId !== e.pointerId) return;
        held.delete(i);
        b.classList.remove("pressed");
        if (
            Array.from(held.values()).some(
                (other) => other.owner === n.owner && other.midi === n.midi,
            )
        )
            return;
        command(P.OP.NOTE, P.note(n.midi, 0, n.timbre, 0), n.owner).catch(
            (err) => {
                if (session !== n.owner) return;
                status("释放失败：" + err.message);
                if (n.owner) command(P.OP.TRANSPORT, [5], n.owner).catch(log);
            },
        );
    };
    b.onpointerup = release;
    b.onpointercancel = release;
    b.onlostpointercapture = release;
    $("keys").append(b);
}
bind("connect", connectWeb);
bind("disconnect", disconnect);
bind("simulate", async () => {
    await disconnect();
    const mock = new Simulator(),
        owner = createSession((b) => mock.write(b), true),
        ownDecoder = decoder;
    mock.deliver = (b) => {
        if (session === owner) ownDecoder.push(b);
    };
    await handshake(owner);
});
bind("test64", test64);
bind("panic", async () => {
    await realtimePlayback.stop();
    const owner = session;
    testGeneration++;
    testActive = false;
    cancelDataOperation();
    await command(4, [5], owner);
    checkSession(owner);
    clearHeld();
});
$("timbre").onchange = () =>
    command(3, [0, Number($("timbre").value)]).catch((e) => status(e.message));
$("effect").onchange = () =>
    command(3, [1, Number($("effect").value)]).catch((e) => status(e.message));
for (const id of ["gain", "bend", "vibrato"]) {
    $(id).oninput = () => {
        $(id + "Value").textContent = $(id).value;
        scheduleExpression(id);
    };
    $(id).onchange = () => scheduleExpression(id);
}
$("mapKey").onchange = () =>
    ($("mapNote").value = map[Number($("mapKey").value)]);
bind("mapApply", async () => {
    const owner = session,
        i = Number($("mapKey").value),
        n = Number($("mapNote").value);
    if (!Number.isInteger(n) || n < 0 || n > 127)
        throw new Error("MIDI 必须为 0..127");
    await command(5, [i, n], owner);
    checkSession(owner);
    map[i] = n;
    $("keys").children[i].textContent = i + " · MIDI " + n;
});
bind("loadUrl", loadScoreUrl);
$("scoreFile").onchange = loadScoreFile;
bind("upload", upload);
bind("play", () => idleCommand(4, [1]));
bind("builtin", () => idleCommand(7, [0, 0, 1]));
bind("guideStart", () => idleCommand(4, [6]));
bind("guideStop", () => command(4, [7]));
bind("stop", async () => {
    await realtimePlayback.stop();
    cancelDataOperation();
    return command(4, [0]);
});
bind("recordStart", () => idleCommand(4, [2]));
bind("recordStop", () => command(4, [3]));
bind("recordRead", readRecording);
bind("recordExport", exportRecording);
bind("recordReplay", () => idleCommand(4, [8]));
bind("recordClear", clearRecording);
bind("readStatus", () => readback(0));
function releasePhoneNotes() {
    realtimePlayback?.stop();
    cancelExpression();
    if (held.size || testActive) {
        testGeneration++;
        testActive = false;
        clearHeld();
        if (session) command(4, [5]).catch((e) => log(e.message));
    }
}
document.addEventListener("visibilitychange", () => {
    if (document.hidden) releasePhoneNotes();
});
window.addEventListener("blur", releasePhoneNotes);
$("capability").textContent = window.AndroidBle
    ? "原生 Android BLE 通道可用"
    : navigator.bluetooth
      ? window.isSecureContext
          ? "Web Bluetooth 可用"
          : "请使用 HTTPS / localhost 启用蓝牙"
      : "此浏览器不支持 Web Bluetooth；请用 Android APK，或进入协议模拟";
setControlReady(false);
$("scoreCapacity").value = String(scoreCapacity);
$("scoreCapacity").onchange = () => {
    try {
        dataIdle();
        const value = Number($("scoreCapacity").value);
        if (![256, 1024].includes(value)) throw new Error("无效容量");
        scoreCapacity = value;
        if (musicPanel) musicPanel.invalidate();
    } catch (error) {
        status(error.message);
    } finally {
        $("scoreCapacity").value = String(scoreCapacity);
    }
};
if (window.MobileMusicPanel)
    musicPanel = new MobileMusicPanel({
        getMapping: () => map.slice(),
        getCapacity: () => scoreCapacity,
        accept: (doc) => {
            dataIdle();
            beginScoreLoad();
            setScore(doc);
        },
        message: status,
    });
realtimePlayback = new MobileRealtimePlayback({
    getSession: () => session, isReady: () => controlReady,
    getScore: () => score, getMapping: () => map,
    getTimbre: () => Number($("timbre").value), assertIdle: dataIdle,
    statusNode: $("realtimeStatus"), message: status,
    sendNote: (event, timbre, owner) => command(P.OP.NOTE,
        P.note(event.midi, event.velocity, timbre, event.on), owner),
    prepare: async (owner, check) => {
        if (held.size) throw Error("请先松开手机琴键再播放");
        const state = P.telemetry((await readback(0, 0, owner)).payload);
        check();
        if (state.recording) throw Error("请先停止录制再实时播放");
        await command(P.OP.TRANSPORT, [0], owner);
        check();
        if (modeSupport) await readback(2, 0, owner);
        check();
    },
});
bind("realtimePlay", () => realtimePlayback.start());
bind("realtimeStop", () => realtimePlayback.stop());
if ($("sustainEnabled")) $("sustainEnabled").onchange = async () => {
    const desired = $("sustainEnabled").checked;
    $("sustainEnabled").disabled = true;
    try { await setSustain(desired); }
    catch (error) { status(error.message); }
    finally { renderSustain(); }
};
let heartbeatPending = false;
setInterval(() => {
    if (
        !session ||
        !controlReady ||
        heartbeatPending ||
        document.hidden ||
        session.pending ||
        session.queue.length
    )
        return;
    heartbeatPending = true;
    readback(0)
        .then(() => {
            if (modeSupport && !held.size && !dataOperation && !testActive && !realtimePlayback.busy)
                return readback(2);
        })
        .then(() => {
            if (sustainSupport && !held.size && !dataOperation && !testActive && !realtimePlayback.busy)
                return readback(5);
        })
        .catch((e) => log(e.message))
        .finally(() => (heartbeatPending = false));
}, 1000);
// Explicit software protocol simulator. It never claims a hardware connection.
class Simulator {
    constructor() {
        this.rows = [];
        this.events = [];
        this.recording = false;
        this.playing = false;
        this.guide = false;
        this.notes = new Set();
        this.sustain = false;
        this.last = null;
        this.lastTime = performance.now();
    }
    async write(bytes) {
        const q = P.decode(bytes);
        if (this.last && this.last.seq === q.seq) {
            if (JSON.stringify(this.last.q) === JSON.stringify(q)) {
                for (const b of this.last.responses)
                    setTimeout(() => this.deliver(b), 10);
                return;
            }
            this.deliver(P.encode(q.seq, 128, [q.op, 1]));
            return;
        }
        const p = q.payload;
        let status = 0,
            data = null;
        if (q.op === 1) {
            p[4] && p[2] !== 0 ? this.notes.add(p[1]) : this.notes.delete(p[1]);
            if (this.recording) {
                const now = performance.now();
                this.events.push({
                    deltaMs: Math.round(now - this.lastTime),
                    source: 63,
                    midi: p[1],
                    velocity: p[2],
                    timbre: p[3],
                    on: p[4],
                });
                this.lastTime = now;
            }
        } else if (q.op === 4) {
            if (p[0] === 0) this.playing = false;
            if (p[0] === 1) this.playing = true;
            if (p[0] === 2) {
                this.events = [];
                this.recording = true;
                this.lastTime = performance.now();
            }
            if (p[0] === 3) this.recording = false;
            if (p[0] === 4) this.events = [];
            if (p[0] === 5) {
                this.sustain = false;
                this.notes.clear();
                this.playing = false;
                this.guide = false;
                this.recording = false;
            }
            if (p[0] === 6) this.guide = true;
            if (p[0] === 7) this.guide = false;
            if (p[0] === 8) {
                if (
                    !this.events.length ||
                    this.events.some((r) => r.source < 25 || r.source > 49)
                )
                    status = 1;
                else this.playing = true;
            }
        } else if (q.op === 3 && p[0] === 2) {
            if (p[1] > 1 || p.slice(2).some(Boolean)) status = 1;
            else this.sustain = !!p[1];
        } else if (q.op === 6) this.rows[P.u16(p, 0)] = p.slice();
        else if (q.op === 8) {
            if (p[0] === 5) data = P.encode(q.seq, P.OP.SUSTAIN_STATUS, [1, this.sustain ? 1 : 0, 0, 64]);
            else if (p[0] === 2) status = 1;
            else if(p[0]===3)data=P.encode(q.seq,P.OP.SCORE_CAPABILITIES,[1,1,...P.le16(1024),127,64,62]);
            else if (p[0] === 0)
                data = P.encode(q.seq, 129, [
                    this.notes.size,
                    (this.playing ? 1 : 0) |
                        (this.recording ? 2 : 0) |
                        (this.guide ? 4 : 0),
                    ...P.le16(this.events.length),
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                ]);
            else {
                const i = P.u16(p, 1),
                    r = this.events[i];
                if (!r) status = 1;
                else
                    data = P.encode(q.seq, 130, [
                        ...P.le16(i),
                        ...P.le32(r.deltaMs),
                        r.source,
                        r.midi,
                        r.velocity,
                        r.on | (r.timbre << 1),
                    ]);
            }
        }
        const responses = [P.encode(q.seq, 128, [q.op, status])];
        if (data) responses.push(data);
        this.last = { seq: q.seq, q, responses };
        responses.forEach((b, i) =>
            setTimeout(() => this.deliver(b), 10 + i * 10),
        );
    }
}
