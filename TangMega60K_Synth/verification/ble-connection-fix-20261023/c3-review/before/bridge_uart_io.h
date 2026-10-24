#pragma once

#include <stddef.h>
#include <stdint.h>
#include <driver/uart.h>
#include <freertos/FreeRTOS.h>

// Serial1 owns installation, pin routing and its receive ring buffer. These
// helpers never install/delete a driver or move the selected GPIO6/7 pins.
enum class BridgeUartStatus : uint8_t {
    Ok,
    NotInstalled,
    QueryFailed,
    ConfigMismatch,
    RxSetupFailed,
    InvalidArgument,
    WriteFailed,
    ShortWrite,
    TxTimeout,
    TxWaitFailed
};

struct BridgeUartResult {
    BridgeUartStatus status;
    esp_err_t sdkError;
    int acceptedBytes;
    const char *operation;
    bool ok() const { return status == BridgeUartStatus::Ok; }
};

inline const char *bridgeUartStatusName(BridgeUartStatus status) {
    switch (status) {
        case BridgeUartStatus::Ok: return "ok";
        case BridgeUartStatus::NotInstalled: return "not-installed";
        case BridgeUartStatus::QueryFailed: return "query-failed";
        case BridgeUartStatus::ConfigMismatch: return "config-mismatch";
        case BridgeUartStatus::RxSetupFailed: return "rx-setup-failed";
        case BridgeUartStatus::InvalidArgument: return "invalid-argument";
        case BridgeUartStatus::WriteFailed: return "write-failed";
        case BridgeUartStatus::ShortWrite: return "short-write";
        case BridgeUartStatus::TxTimeout: return "tx-timeout";
        case BridgeUartStatus::TxWaitFailed: return "tx-wait-failed";
    }
    return "unknown";
}

inline BridgeUartResult bridgeUartCheck() {
    constexpr uart_port_t port = UART_NUM_1;
    if (!uart_is_driver_installed(port))
        return {BridgeUartStatus::NotInstalled, ESP_ERR_INVALID_STATE, 0, "driver"};

    uint32_t baud = 0;
    uart_word_length_t bits = UART_DATA_5_BITS;
    uart_parity_t parity = UART_PARITY_DISABLE;
    uart_stop_bits_t stop = UART_STOP_BITS_1;
    uart_hw_flowcontrol_t flow = UART_HW_FLOWCTRL_DISABLE;
    esp_err_t err = uart_get_baudrate(port, &baud);
    if (err != ESP_OK)
        return {BridgeUartStatus::QueryFailed, err, 0, "get-baud"};
    // Divider quantization means the returned hardware baud need not be 115200
    // exactly. Reject an unexpected rate while allowing a one-percent error.
    if (baud < 114048 || baud > 116352)
        return {BridgeUartStatus::ConfigMismatch, ESP_ERR_INVALID_STATE, 0, "baud"};
    err = uart_get_word_length(port, &bits);
    if (err != ESP_OK)
        return {BridgeUartStatus::QueryFailed, err, 0, "get-bits"};
    if (bits != UART_DATA_8_BITS)
        return {BridgeUartStatus::ConfigMismatch, ESP_ERR_INVALID_STATE, 0, "bits"};
    err = uart_get_parity(port, &parity);
    if (err != ESP_OK)
        return {BridgeUartStatus::QueryFailed, err, 0, "get-parity"};
    if (parity != UART_PARITY_DISABLE)
        return {BridgeUartStatus::ConfigMismatch, ESP_ERR_INVALID_STATE, 0, "parity"};
    err = uart_get_stop_bits(port, &stop);
    if (err != ESP_OK)
        return {BridgeUartStatus::QueryFailed, err, 0, "get-stop"};
    if (stop != UART_STOP_BITS_1)
        return {BridgeUartStatus::ConfigMismatch, ESP_ERR_INVALID_STATE, 0, "stop"};
    err = uart_get_hw_flow_ctrl(port, &flow);
    if (err != ESP_OK)
        return {BridgeUartStatus::QueryFailed, err, 0, "get-flow"};
    if (flow != UART_HW_FLOWCTRL_DISABLE)
        return {BridgeUartStatus::ConfigMismatch, ESP_ERR_INVALID_STATE, 0, "flow"};
    return {BridgeUartStatus::Ok, ESP_OK, 0, "check"};
}

inline BridgeUartResult bridgeUartPrepare() {
    BridgeUartResult result = bridgeUartCheck();
    if (!result.ok()) return result;
    // A 16-byte response should reach the existing 1024-byte receive ring
    // immediately; a final partial burst is released after two symbol timeout.
    // No flush/read is performed here, so back-to-back ACK + telemetry survives.
    esp_err_t err = uart_set_rx_timeout(UART_NUM_1, 2);
    if (err != ESP_OK)
        return {BridgeUartStatus::RxSetupFailed, err, 0, "rx-timeout"};
    err = uart_set_rx_full_threshold(UART_NUM_1, 16);
    if (err != ESP_OK)
        return {BridgeUartStatus::RxSetupFailed, err, 0, "rx-threshold"};
    return {BridgeUartStatus::Ok, ESP_OK, 0, "prepare"};
}

inline BridgeUartResult bridgeUartTransmit(const uint8_t *bytes, size_t length) {
    // This bridge transfers exactly one unchanged 16-byte packet per write.
    if (bytes == nullptr || length != 16)
        return {BridgeUartStatus::InvalidArgument, ESP_ERR_INVALID_ARG, 0, "packet"};
    BridgeUartResult result = bridgeUartCheck();
    if (!result.ok()) return result;
    // HardwareSerial::write() in Arduino-ESP32 3.3.5 always returns the requested
    // length. Call its underlying IDF driver so a failed/short write is visible.
    // loop() is the only sender; the driver supplies its own TX mutex.
    const int accepted = uart_write_bytes(UART_NUM_1, bytes, length);
    if (accepted < 0)
        return {BridgeUartStatus::WriteFailed, ESP_FAIL, accepted, "write"};
    if (accepted != static_cast<int>(length))
        return {BridgeUartStatus::ShortWrite, ESP_FAIL, accepted, "write"};

    constexpr TickType_t waitTicks = pdMS_TO_TICKS(20) > 0 ? pdMS_TO_TICKS(20) : 1;
    const esp_err_t err = uart_wait_tx_done(UART_NUM_1, waitTicks);
    if (err == ESP_ERR_TIMEOUT)
        return {BridgeUartStatus::TxTimeout, err, accepted, "wait-tx"};
    if (err != ESP_OK)
        return {BridgeUartStatus::TxWaitFailed, err, accepted, "wait-tx"};
    // This proves driver acceptance and UART completion, not delivery across
    // the external wire. Only the FPGA's valid protocol response proves that.
    return {BridgeUartStatus::Ok, ESP_OK, accepted, "tx-done"};
}
