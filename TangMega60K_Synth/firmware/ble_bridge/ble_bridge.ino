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
QueueHandle_t toUart, toBle;
BLEServer *server;
BLECharacteristic *txChar, *diagChar;
// BLE callbacks and the UART event task run outside loop(). Volatile alone
// does not synchronize these reads/writes or protect read-modify-write counters.
std::atomic<bool> connected{false};
std::atomic<uint32_t> sessionGeneration{0}, failedSession{0};
std::atomic<uint32_t> bleWriteErrors{0}, uartErrors{0}, notifyErrors{0}, resyncCount{0};
std::atomic<int> notifyResult{0}; // 0=pending, 1=host accepted, -1=failed
std::atomic<TaskHandle_t> notifyOwnerTask{nullptr};
bool notifying=false;
unsigned notifyAttempts=0;
uint32_t notifyTime=0;

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer *) override {
        connected=false;sessionGeneration++;connected=true;
    }
    void onDisconnect(BLEServer *) override {
        connected=false;sessionGeneration++;
    }
};
class ReceiveCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *c) override {
        String value=c->getValue();
        const uint32_t session=sessionGeneration;
        if(!connected || value.length()!=16) { bleWriteErrors++;failedSession=session;return; }
        Packet p;memcpy(p.bytes,value.c_str(),16);p.session=session;
        if(xQueueSend(toUart,&p,0)!=pdTRUE){bleWriteErrors++;failedSession=session;}
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
        // Four uint32 LE counters, visible after reconnect as well.
        const uint32_t counters[4]={bleWriteErrors,uartErrors,notifyErrors,resyncCount};
        uint8_t bytes[16];for(unsigned i=0;i<4;i++)for(unsigned b=0;b<4;b++)bytes[i*4+b]=counters[i]>>(8*b);
        c->setValue(bytes,16);
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
    Serial1.setRxBufferSize(1024);Serial1.setTxBufferSize(256);
    Serial1.begin(115200,SERIAL_8N1,FPGA_RX_GPIO,FPGA_TX_GPIO);
    Serial1.onReceiveError([](hardwareSerial_error_t){uartErrors++;failedSession=sessionGeneration.load();});
    BLEDevice::init("Tang-Synth-C3");server=BLEDevice::createServer();server->setCallbacks(new ServerCallbacks());
    BLEService *service=server->createService(SERVICE_UUID);
    txChar=service->createCharacteristic(TX_UUID,BLECharacteristic::PROPERTY_NOTIFY);
#if defined(CONFIG_BLUEDROID_ENABLED)
    txChar->addDescriptor(new BLE2902());
#endif
    txChar->setCallbacks(new NotifyCallbacks());
    BLECharacteristic *rxChar=service->createCharacteristic(RX_UUID,BLECharacteristic::PROPERTY_WRITE);
    rxChar->setCallbacks(new ReceiveCallbacks());
    diagChar=service->createCharacteristic(DIAG_UUID,BLECharacteristic::PROPERTY_READ);
    diagChar->setCallbacks(new DiagnosticCallbacks());
    service->start();BLEAdvertising *advertising=server->getAdvertising();
    advertising->addServiceUUID(SERVICE_UUID);advertising->setScanResponse(true);advertising->start();
    if(Serial)Serial.printf("Tang-Synth-C3 Zero bridge: UART 115200 8N1 RX%d / TX%d; no audio\n",FPGA_RX_GPIO,FPGA_TX_GPIO);
}
void loop(){
    static uint32_t activeSession=0;
    static bool wasConnected=false;
    static int previousLedState=-1;
    static uint32_t errorUntil=0;
    static Packet assembling;
    static unsigned used=0;
    static uint32_t lastByte=0,lastStats=0,reAdvertiseAt=0;
    const uint32_t now=millis();
    const uint32_t session=sessionGeneration;
    const bool isConnected=connected && session==sessionGeneration;
    const uint32_t failed=failedSession.exchange(0);
    if(failed && failed==session){
        errorUntil=now+2000;
        if(isConnected)server->disconnect(server->getConnId());
        if(Serial && Serial.availableForWrite()>=100)Serial.println("Bridge error: disconnected; FPGA source63 watchdog must release held notes");
    }
    if(session!=activeSession || isConnected!=wasConnected){
        // Queue consumers are owned by loop(). Never reset them from a BLE
        // callback or here: a new client's first write may already be queued.
        used=0;notifying=false;notifyResult=0;notifyAttempts=0;
        while(Serial1.available())Serial1.read();
        if(!isConnected)reAdvertiseAt=now+500;
        else {reAdvertiseAt=0;if(failed!=session)errorUntil=0;}
        activeSession=session;wasConnected=isConnected;
    }
    const int ledState=(errorUntil && (int32_t)(errorUntil-now)>0)?2:(isConnected?1:0);
    if(ledState!=previousLedState){
        rgbLedWrite(BRIDGE_RGB_GPIO,ledState==2?8:0,ledState==1?8:0,ledState==0?8:0);
        previousLedState=ledState;
    }
    // A connect/disconnect during this iteration invalidates its local state.
    if(sessionGeneration!=activeSession){delay(1);return;}
    Packet p;
    // Tagged stale frames can be discarded without clearing a newer session's
    // first command. Only loop() removes queue entries; callbacks only append.
    while(xQueuePeek(toUart,&p,0)==pdTRUE && p.session!=activeSession){
        if(sessionGeneration!=activeSession){delay(1);return;}
        xQueueReceive(toUart,&p,0);
    }
    while(xQueuePeek(toBle,&p,0)==pdTRUE && p.session!=activeSession){
        xQueueReceive(toBle,&p,0);
    }
    if(!isConnected){while(Serial1.available())Serial1.read();if(reAdvertiseAt&&(int32_t)(now-reAdvertiseAt)>=0){server->startAdvertising();reAdvertiseAt=0;}delay(1);return;}
    if(failed && failed==session){delay(1);return;}
    if(Serial1.availableForWrite()>=16 && xQueuePeek(toUart,&p,0)==pdTRUE && p.session==activeSession && sessionGeneration==activeSession){
        xQueueReceive(toUart,&p,0);
        if(sessionGeneration==activeSession && Serial1.write(p.bytes,16)!=16){uartErrors++;failedSession=activeSession;}
    }
    if(used&&now-lastByte>20){used=0;resyncCount++;}
    while(Serial1.available()){
        const uint8_t b=Serial1.read();lastByte=now;
        if(used==0){if(b==0xa5){assembling.bytes[used++]=b;assembling.session=activeSession;}else resyncCount++;}
        else if(used==1){if(b==0x5a)assembling.bytes[used++]=b;else if(b!=0xa5){used=0;resyncCount++;}}
        else {assembling.bytes[used++]=b;if(used==16){used=0;if(xQueueSend(toBle,&assembling,0)!=pdTRUE){uartErrors++;failedSession=activeSession;}}}
    }
    if(sessionGeneration!=activeSession){delay(1);return;}
    // Keep the queued response until the BLE host accepts notify; application
    // ACK retry still covers losses after the host accepts a notification.
    if(notifying && notifyResult==1){xQueueReceive(toBle,&p,0);notifying=false;notifyAttempts=0;notifyResult=0;}
    if(notifying && (notifyResult==-1 || now-notifyTime>500)){
        notifying=false;notifyResult=0;if(++notifyAttempts>=3){notifyErrors++;failedSession=activeSession;}
    }
    if(!notifying&&now-notifyTime>=15&&xQueuePeek(toBle,&p,0)==pdTRUE){notifying=true;notifyResult=0;notifyTime=now;txChar->setValue(p.bytes,16);txChar->notify();}
    if(now-lastStats>=5000){lastStats=now;if(Serial && Serial.availableForWrite()>=120)Serial.printf("bridge counters BLEwrite=%lu UART=%lu notify=%lu resync=%lu\n",(unsigned long)bleWriteErrors,(unsigned long)uartErrors,(unsigned long)notifyErrors,(unsigned long)resyncCount);}
    delay(1);
}
