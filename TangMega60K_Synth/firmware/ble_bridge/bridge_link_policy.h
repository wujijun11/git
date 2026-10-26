#pragma once
#include <stdint.h>

// BLE连接间隔单位1.25ms；请求7.5..15ms、从机延迟0、监督超时4s。
// 这是协商请求，Windows/手机可调整或拒绝，不能把请求值当实际测量值。
constexpr uint16_t BRIDGE_INTERVAL_MIN = 6;
constexpr uint16_t BRIDGE_INTERVAL_MAX = 12;
constexpr uint16_t BRIDGE_SLAVE_LATENCY = 0;
constexpr uint16_t BRIDGE_SUPERVISION_TIMEOUT = 400;
static_assert(BRIDGE_INTERVAL_MIN >= 6 && BRIDGE_INTERVAL_MAX >= BRIDGE_INTERVAL_MIN,
              "BLE interval outside specification");
