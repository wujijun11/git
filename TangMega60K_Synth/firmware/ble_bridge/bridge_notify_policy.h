#pragma once
#include <stdint.h>

// 成功通知后不再强制等15ms；交给BLE主机调度，循环自身仍有1ms让步。
// 失败重试保留15ms间隔，不能因追求速度而连续冲击拥塞队列。
inline bool bridgeNotifyDue(uint32_t now, uint32_t previous, unsigned failures) {
    const uint32_t intervalMs = failures ? 15U : 1U;
    return static_cast<uint32_t>(now - previous) >= intervalMs;
}
