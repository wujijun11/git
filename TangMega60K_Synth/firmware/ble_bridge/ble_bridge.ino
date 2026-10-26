// ESP32-C3, Espressif Arduino core 3.3.5. No audio, no event generation,
// no command deduplication: one 16-byte write => unchanged UART packet.
#include <Arduino.h>
#include <atomic>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#if defined(CONFIG_NIMBLE_ENABLED)
#include <nimble/nimble_port.h>
#endif
#include "bridge_uart_io.h"
#include "bridge_notify_policy.h"
#include "bridge_link_policy.h"

#if !defined(CONFIG_IDF_TARGET_ESP32C3)
#error "Build this bridge for the ESP32-C3, not another ESP32 variant."
#endif
#if !ARDUINO_USB_CDC_ON_BOOT
#error "Enable USB CDC On Boot for the native USB on the Waveshare ESP32-C3-Zero."
#endif
#ifndef FPGA_RX_GPIO
#define FPGA_RX_GPIO 6
#endif
#ifndef FPGA_TX_GPIO
#define FPGA_TX_GPIO 7
#endif
#ifndef BRIDGE_RGB_GPIO
#define BRIDGE_RGB_GPIO 10
#endif
// Reserved on the selected board: straps 2/8/9, onboard RGB 10,
// stacked flash 12..17 and native USB 18/19. UART1 uses the GPIO matrix;
// board silk RX/TX names UART0 (20/21), not this bridge's GPIO6/7.
constexpr bool usableBridgePin(int pin) {
    return pin >= 0 && pin <= 21 && pin != 2 && pin != 8 && pin != 9 &&
        pin != BRIDGE_RGB_GPIO && !(pin >= 11 && pin <= 19);
}
static_assert(usableBridgePin(FPGA_RX_GPIO) && usableBridgePin(FPGA_TX_GPIO),
    "Bridge UART must use free exposed GPIOs; preserve USB, flash, BOOT and RGB.");
static_assert(FPGA_RX_GPIO != FPGA_TX_GPIO, "Bridge RX and TX require separate GPIOs.");
#define SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define RX_UUID "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define TX_UUID "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
#define DIAG_UUID "6e400004-b5a3-f393-e0a9-e50e24dcca9e"
// The session tag is internal only; UART and BLE still transfer 16 bytes.
struct Packet { uint8_t bytes[16]; uint32_t session; };
// FPGA responses use CRC-8/ATM (poly 0x07, init 0) over bytes 2..14.
// This only identifies intact UART frame boundaries; it does not interpret
// opcodes/versions, modify bytes, generate commands, or deduplicate retries.
bool uartFrameCrcValid(const uint8_t *bytes){
    uint8_t crc=0;
    for(unsigned i=2;i<15;i++){
        crc^=bytes[i];
        for(unsigned bit=0;bit<8;bit++)crc=(crc&0x80)?(crc<<1)^0x07:crc<<1;
    }
    return crc==bytes[15];
}
QueueHandle_t toUart, toBle;
BLEServer *server;
BLECharacteristic *txChar, *diagChar;
// BLE callbacks and the UART event task run outside loop(). Volatile alone
// does not synchronize these reads/writes or protect read-modify-write counters.
// Keep the generation and its live/failed flags in one atomic word. A delayed
// old-session error may only poison that exact session, never its replacement.
constexpr uint32_t SESSION_CONNECTED=1,SESSION_FAILED=2,SESSION_FLAGS=3;
std::atomic<uint32_t> sessionState{0};
uint32_t sessionGeneration(){return sessionState.load()>>2;}
bool healthySession(uint32_t session){return sessionState.load()==((session<<2)|SESSION_CONNECTED);}
void failSession(uint32_t session){
    uint32_t expected=(session<<2)|SESSION_CONNECTED;
    sessionState.compare_exchange_strong(expected,expected|SESSION_FAILED);
}
#if defined(CONFIG_NIMBLE_ENABLED)
// Connection callbacks and this event run on the NimBLE host task. Checking
// the generation here keeps a delayed close from selecting a new connection,
// including when the controller reuses the old connection handle. No bridge
// lock is held across the host call; loop() only posts a persistent event.
struct ble_npl_event closeSessionEvent;
std::atomic<uint32_t> requestedCloseState{0};
void handleSessionClose(struct ble_npl_event *){
    const uint32_t requested=requestedCloseState.load();
    if((requested&SESSION_FLAGS)==(SESSION_CONNECTED|SESSION_FAILED) &&
        sessionState.load()==requested)
        server->disconnect(server->getConnId());
}
#endif
void requestSessionClose(uint32_t failedState){
#if defined(CONFIG_NIMBLE_ENABLED)
    requestedCloseState=failedState;
    ble_npl_eventq_put(nimble_port_get_dflt_eventq(),&closeSessionEvent);
#else
    // The selected ESP32-C3 build uses NimBLE. Preserve the other backend's
    // existing close behavior without introducing NimBLE-only APIs there.
    server->disconnect(server->getConnId());
#endif
}
std::atomic<uint32_t> bleWriteErrors{0}, uartErrors{0}, notifyErrors{0}, resyncCount{0};
// Observations only: no counter below controls forwarding or session state.
std::atomic<uint32_t> bleReceivedFrames{0}, uartSentFrames{0}, uartReceivedBytes{0},
    uartValidFrames{0}, notifyAcceptedFrames{0};
// Kept separate from the compatible 40-byte diagnostic value: these bytes
// reached the UART while no live session was allowed to consume a response.
std::atomic<uint32_t> uartDiscardedBytes{0};
bool bridgeUartReady=false;
BridgeUartResult bridgeUartInitialization{
    BridgeUartStatus::NotInstalled,ESP_ERR_INVALID_STATE,0,"not-started"};
void discardUartInput(){
    while(Serial1.available()){
        if(Serial1.read()<0)break;
        uartDiscardedBytes++;
    }
}
// Keep the original four little-endian error counters at bytes 0..15.
// Extension: "TB", version 1, UART-init flags, then five uint32 LE counters.
// A notify acceptance counts host acceptance, not confirmed client delivery.
void updateDiagnostics(BLECharacteristic *c){
    const uint32_t counters[9]={bleWriteErrors,uartErrors,notifyErrors,resyncCount,
        bleReceivedFrames,uartSentFrames,uartReceivedBytes,uartValidFrames,notifyAcceptedFrames};
    uint8_t bytes[40];
    for(unsigned i=0;i<9;i++)for(unsigned b=0;b<4;b++)
        bytes[(i<4?i*4:20+(i-4)*4)+b]=counters[i]>>(8*b);
    bytes[16]='T';bytes[17]='B';bytes[18]=1;bytes[19]=bridgeUartReady?1:0;
    c->setValue(bytes,sizeof(bytes));
}
std::atomic<int> notifyResult{0}; // 0=pending, 1=host accepted, -1=failed
std::atomic<TaskHandle_t> notifyOwnerTask{nullptr};
bool notifying=false;
unsigned notifyAttempts=0;
uint32_t notifyTime=0;

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer *) override {
        sessionState=((sessionState.load()+4)&~SESSION_FLAGS)|SESSION_CONNECTED;
    }
    void onDisconnect(BLEServer *) override {
        sessionState=(sessionState.load()+4)&~SESSION_FLAGS;
    }
#if defined(CONFIG_NIMBLE_ENABLED)
    void onConnect(BLEServer *owner, ble_gap_conn_desc *desc) override {
        // 使用当前回调提供的连接句柄，不从其他任务猜测或重用旧句柄。
        owner->updateConnParams(desc->conn_handle, BRIDGE_INTERVAL_MIN,
            BRIDGE_INTERVAL_MAX, BRIDGE_SLAVE_LATENCY, BRIDGE_SUPERVISION_TIMEOUT);
    }
#endif
};
class ReceiveCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *c) override {
        String value=c->getValue();
        const uint32_t session=sessionGeneration();
        if(!healthySession(session) || value.length()!=16) { bleWriteErrors++;failSession(session);return; }
        bleReceivedFrames++;
        if(!bridgeUartReady){uartErrors++;failSession(session);return;}
        Packet p;memcpy(p.bytes,value.c_str(),16);p.session=session;
        if(xQueueSend(toUart,&p,0)!=pdTRUE){bleWriteErrors++;failSession(session);}
    }
};
class NotifyCallbacks : public BLECharacteristicCallbacks {
    void onStatus(BLECharacteristic *,Status s,uint32_t) override {
        if(s!=SUCCESS_NOTIFY)notifyErrors++;
        // Core 3.3.5 calls onStatus both synchronously from notify() and later
        // from the BLE host task. That late callback has no attempt identifier;
        // it must not dequeue a newer response or overwrite its failed send.
        // Only notify()'s loop-task result acknowledges host acceptance. The
        // phone/FPGA ACK retry covers errors after that acceptance.
        if(xTaskGetCurrentTaskHandle()==notifyOwnerTask.load())
            notifyResult=(s==SUCCESS_NOTIFY)?1:-1;
    }
};
class DiagnosticCallbacks : public BLECharacteristicCallbacks {
    void onRead(BLECharacteristic *c) override {
        updateDiagnostics(c);
    }
};
void setup(){
    notifyOwnerTask=xTaskGetCurrentTaskHandle();
    Serial.begin(115200);
    // Logging must not delay the transport when no USB monitor is attached.
    Serial.setTxTimeoutMs(1);
    rgbLedWrite(BRIDGE_RGB_GPIO,0,0,8);
    toUart=xQueueCreate(8,sizeof(Packet));toBle=xQueueCreate(32,sizeof(Packet));
    if(!toUart || !toBle){rgbLedWrite(BRIDGE_RGB_GPIO,8,0,0);if(Serial)Serial.println("FATAL: bridge queue allocation");while(true)delay(1000);}
    const size_t rxCapacity=Serial1.setRxBufferSize(1024);
    const size_t txCapacity=Serial1.setTxBufferSize(256);
    Serial1.begin(115200,SERIAL_8N1,FPGA_RX_GPIO,FPGA_TX_GPIO);
    bridgeUartInitialization=bridgeUartPrepare();
    if(rxCapacity!=1024 || txCapacity!=256)
        bridgeUartInitialization={BridgeUartStatus::ConfigMismatch,
            ESP_ERR_INVALID_SIZE,0,"buffer-size"};
    bridgeUartReady=static_cast<bool>(Serial1) && bridgeUartInitialization.ok();
    Serial1.onReceiveError([](hardwareSerial_error_t){uartErrors++;failSession(sessionGeneration());});
    BLEDevice::init("Tang-Synth-C3");server=BLEDevice::createServer();
#if defined(CONFIG_NIMBLE_ENABLED)
    ble_npl_event_init(&closeSessionEvent,handleSessionClose,nullptr);
#endif
    server->setCallbacks(new ServerCallbacks());
    BLEService *service=server->createService(SERVICE_UUID);
    txChar=service->createCharacteristic(TX_UUID,BLECharacteristic::PROPERTY_NOTIFY);
#if defined(CONFIG_BLUEDROID_ENABLED)
    txChar->addDescriptor(new BLE2902());
#endif
    txChar->setCallbacks(new NotifyCallbacks());
    BLECharacteristic *rxChar=service->createCharacteristic(RX_UUID,BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    rxChar->setCallbacks(new ReceiveCallbacks());
    diagChar=service->createCharacteristic(DIAG_UUID,BLECharacteristic::PROPERTY_READ);
    diagChar->setCallbacks(new DiagnosticCallbacks());
    // The core's NimBLE read guard can skip onRead; publish before advertising.
    updateDiagnostics(diagChar);
    service->start();BLEAdvertising *advertising=server->getAdvertising();
    advertising->addServiceUUID(SERVICE_UUID);advertising->setScanResponse(true);advertising->start();
    if(Serial)Serial.printf("Tang-Synth-C3 Zero bridge: UART 115200 8N1 RX%d / TX%d; no audio\n",FPGA_RX_GPIO,FPGA_TX_GPIO);
}
void loop(){
    static uint32_t activeSession=0;
    static bool wasConnected=false;
    static bool closeRequested=false;
    static int previousLedState=-1;
    static uint32_t errorUntil=0;
    static Packet assembling;
    static unsigned used=0;
    static uint32_t lastByte=0,lastStats=0,reAdvertiseAt=0;
    static uint32_t lastDiagnostics=0;
    static bool uartInitReported=false;
    const uint32_t now=millis();
    // Publish even while disconnected or failed, without relying on onRead.
    if(now-lastDiagnostics>=100){lastDiagnostics=now;updateDiagnostics(diagChar);}
    if(!uartInitReported && Serial && Serial.availableForWrite()>=100){
        Serial.printf("bridge UART init=%s RX%d TX%d baud115200 FIFO16 timeout2 status=%s op=%s sdk=%ld\n",
            bridgeUartReady?"OK":"FAILED",FPGA_RX_GPIO,FPGA_TX_GPIO,
            bridgeUartStatusName(bridgeUartInitialization.status),
            bridgeUartInitialization.operation,(long)bridgeUartInitialization.sdkError);
        uartInitReported=true;
    }
    // Report even when disconnected: otherwise discarded UART traffic could
    // be mistaken for a completely silent physical receive path.
    if(now-lastStats>=5000){
        lastStats=now;
        if(Serial && Serial.availableForWrite()>=240)
            Serial.printf("bridge counters BLEwrite=%lu UART=%lu notify=%lu resync=%lu BLErx=%lu UARTtx=%lu UARTbytes=%lu validRx=%lu notifyOK=%lu UARTdiscard=%lu\n",
                (unsigned long)bleWriteErrors,(unsigned long)uartErrors,(unsigned long)notifyErrors,(unsigned long)resyncCount,
                (unsigned long)bleReceivedFrames,(unsigned long)uartSentFrames,(unsigned long)uartReceivedBytes,
                (unsigned long)uartValidFrames,(unsigned long)notifyAcceptedFrames,(unsigned long)uartDiscardedBytes);
    }
    const uint32_t state=sessionState;
    const uint32_t session=state>>2;
    const bool isConnected=(state&SESSION_CONNECTED)!=0;
    const bool failed=(state&SESSION_FAILED)!=0;
    if(session!=activeSession || isConnected!=wasConnected){
        // Queue consumers are owned by loop(). Never reset them from a BLE
        // callback or here: a new client's first write may already be queued.
        used=0;notifying=false;notifyResult=0;notifyAttempts=0;closeRequested=false;
        discardUartInput();
        if(!isConnected)reAdvertiseAt=now+500;
        else {reAdvertiseAt=0;if(!failed)errorUntil=0;}
        activeSession=session;wasConnected=isConnected;
    }
    if(failed && isConnected && !closeRequested){
        closeRequested=true;errorUntil=now+2000;
        requestSessionClose(state);
        if(Serial && Serial.availableForWrite()>=100)Serial.println("Bridge error: closing; FPGA source63 watchdog must release held notes");
    }
    const int ledState=(errorUntil && (int32_t)(errorUntil-now)>0)?2:(isConnected?1:0);
    if(ledState!=previousLedState){
        rgbLedWrite(BRIDGE_RGB_GPIO,ledState==2?8:0,ledState==1?8:0,ledState==0?8:0);
        previousLedState=ledState;
    }
    // A connect/disconnect during this iteration invalidates its local state.
    if(sessionGeneration()!=activeSession){delay(1);return;}
    Packet p;
    // Tagged stale frames can be discarded without clearing a newer session's
    // first command. Only loop() removes queue entries; callbacks only append.
    while(xQueuePeek(toUart,&p,0)==pdTRUE && p.session!=activeSession){
        if(sessionGeneration()!=activeSession){delay(1);return;}
        xQueueReceive(toUart,&p,0);
    }
    while(xQueuePeek(toBle,&p,0)==pdTRUE && p.session!=activeSession){
        xQueueReceive(toBle,&p,0);
    }
    if(!isConnected){discardUartInput();if(reAdvertiseAt&&(int32_t)(now-reAdvertiseAt)>=0){server->startAdvertising();reAdvertiseAt=0;}delay(1);return;}
    // disconnect() only requests asynchronous close. Keep this generation
    // poisoned until a connect/disconnect transition; no later loop or write
    // callback may resume its queued traffic while the close is still pending.
    if(!healthySession(activeSession)){delay(1);return;}
    if(Serial1.availableForWrite()>=16 && xQueuePeek(toUart,&p,0)==pdTRUE && p.session==activeSession && healthySession(activeSession)){
        xQueueReceive(toUart,&p,0);
        if(healthySession(activeSession)){
            const BridgeUartResult sent=bridgeUartTransmit(p.bytes,16);
            if(!sent.ok()){
                uartErrors++;failSession(activeSession);
                if(Serial && Serial.availableForWrite()>=150)
                    Serial.printf("bridge UART send failed status=%s op=%s sdk=%ld accepted=%d\n",
                        bridgeUartStatusName(sent.status),sent.operation,
                        (long)sent.sdkError,sent.acceptedBytes);
                delay(1);return;
            }
            uartSentFrames++;
        }
    }
    // TX completion can yield to the UART/BLE tasks. Use the time after that
    // wait, rather than the loop's earlier snapshot, for receive framing.
    const uint32_t receiveNow=millis();
    // A response tail may already have reached the ring while TX completion
    // yielded. Drain it before treating a partial frame as an idle timeout.
    if(used&&receiveNow-lastByte>20&&!Serial1.available()){used=0;resyncCount++;}
    while(healthySession(activeSession) && Serial1.available()){
        const int received=Serial1.read();if(received<0)break;
        const uint8_t b=static_cast<uint8_t>(received);uartReceivedBytes++;lastByte=receiveNow;
        if(used==0){if(b==0xa5){assembling.bytes[used++]=b;assembling.session=activeSession;}else resyncCount++;}
        else if(used==1){if(b==0x5a)assembling.bytes[used++]=b;else if(b!=0xa5){used=0;resyncCount+=2;}else resyncCount++;}
        else {
            assembling.bytes[used++]=b;
            if(used==16){
                if(uartFrameCrcValid(assembling.bytes)){
                    uartValidFrames++;
                    used=0;
                    if(xQueueSend(toBle,&assembling,0)!=pdTRUE){uartErrors++;failSession(activeSession);}
                }else{
                    // A dropped/inserted byte can leave a real next header
                    // inside this rejected window. Keep its suffix (or a final
                    // A5), rather than blindly consuming 16 bytes forever at a
                    // false header embedded in repeated response payloads.
                    unsigned discard=1;
                    while(discard+1<16 && !(assembling.bytes[discard]==0xa5 && assembling.bytes[discard+1]==0x5a))discard++;
                    if(discard==15 && assembling.bytes[15]!=0xa5)discard=16;
                    used=16-discard;
                    memmove(assembling.bytes,assembling.bytes+discard,used);
                    resyncCount+=discard;
                }
            }
        }
    }
    if(!healthySession(activeSession)){delay(1);return;}
    // Keep the queued response until the BLE host accepts notify; application
    // ACK retry still covers losses after the host accepts a notification.
    if(notifying && notifyResult==1){xQueueReceive(toBle,&p,0);notifyAcceptedFrames++;notifying=false;notifyAttempts=0;notifyResult=0;}
    if(notifying && (notifyResult==-1 || now-notifyTime>500)){
        notifying=false;notifyResult=0;if(++notifyAttempts>=3){notifyErrors++;failSession(activeSession);delay(1);return;}
    }
    if(!notifying&&bridgeNotifyDue(now,notifyTime,notifyAttempts)&&xQueuePeek(toBle,&p,0)==pdTRUE){notifying=true;notifyResult=0;notifyTime=now;txChar->setValue(p.bytes,16);txChar->notify();}
    delay(1);
}
