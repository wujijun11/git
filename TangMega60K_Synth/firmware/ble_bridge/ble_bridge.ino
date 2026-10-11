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

#ifndef FPGA_RX_GPIO
#define FPGA_RX_GPIO 6
#endif
#ifndef FPGA_TX_GPIO
#define FPGA_TX_GPIO 7
#endif
#define SERVICE_UUID "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define RX_UUID "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define TX_UUID "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
#define DIAG_UUID "6e400004-b5a3-f393-e0a9-e50e24dcca9e"
struct Packet { uint8_t bytes[16]; };
QueueHandle_t toUart, toBle;
BLEServer *server;
BLECharacteristic *txChar, *diagChar;
// BLE callbacks and the UART event task run outside loop(). Volatile alone
// does not synchronize these reads/writes or protect read-modify-write counters.
std::atomic<bool> connected{false}, forceDisconnect{false};
std::atomic<uint32_t> bleWriteErrors{0}, uartErrors{0}, notifyErrors{0}, resyncCount{0};
std::atomic<int> notifyResult{0}; // 0=pending, 1=host accepted, -1=failed
bool notifying=false;
unsigned notifyAttempts=0;
uint32_t notifyTime=0;

class ServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer *) override { connected=true; }
    void onDisconnect(BLEServer *) override { connected=false; }
};
class ReceiveCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *c) override {
        String value=c->getValue();
        if(!connected || value.length()!=16) { bleWriteErrors++;forceDisconnect=true;return; }
        Packet p;memcpy(p.bytes,value.c_str(),16);
        if(xQueueSend(toUart,&p,0)!=pdTRUE){bleWriteErrors++;forceDisconnect=true;}
    }
};
class NotifyCallbacks : public BLECharacteristicCallbacks {
    void onStatus(BLECharacteristic *,Status s,uint32_t) override {
        if(s==SUCCESS_NOTIFY)notifyResult=1;
        else {notifyErrors++;notifyResult=-1;}
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
    Serial.begin(115200);
    toUart=xQueueCreate(8,sizeof(Packet));toBle=xQueueCreate(32,sizeof(Packet));
    if(!toUart || !toBle){Serial.println("FATAL: bridge queue allocation");while(true)delay(1000);}
    Serial1.setRxBufferSize(1024);Serial1.setTxBufferSize(256);
    Serial1.begin(115200,SERIAL_8N1,FPGA_RX_GPIO,FPGA_TX_GPIO);
    Serial1.onReceiveError([](hardwareSerial_error_t){uartErrors++;forceDisconnect=true;});
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
    Serial.println("Tang-Synth-C3 bridge: UART 115200 8N1; no audio. RX6 / TX7 (override macros as needed)");
}
void loop(){
    static bool wasConnected=false;
    static Packet assembling;
    static unsigned used=0;
    static uint32_t lastByte=0,lastStats=0,reAdvertiseAt=0;
    const uint32_t now=millis();
    if(forceDisconnect.exchange(false)){if(connected)server->disconnect(server->getConnId());Serial.println("Bridge error: disconnected; FPGA source63 watchdog must release held notes");}
    if(connected!=wasConnected){
        xQueueReset(toUart);xQueueReset(toBle);used=0;notifying=false;notifyResult=0;notifyAttempts=0;
        while(Serial1.available())Serial1.read();
        if(!connected)reAdvertiseAt=now+500;
        wasConnected=connected;
    }
    if(!connected){while(Serial1.available())Serial1.read();if(reAdvertiseAt&&(int32_t)(now-reAdvertiseAt)>=0){server->startAdvertising();reAdvertiseAt=0;}delay(1);return;}
    Packet p;
    if(Serial1.availableForWrite()>=16&&xQueueReceive(toUart,&p,0)==pdTRUE){if(Serial1.write(p.bytes,16)!=16){uartErrors++;forceDisconnect=true;}}
    if(used&&now-lastByte>20){used=0;resyncCount++;}
    while(Serial1.available()){
        const uint8_t b=Serial1.read();lastByte=now;
        if(used==0){if(b==0xa5)assembling.bytes[used++]=b;else resyncCount++;}
        else if(used==1){if(b==0x5a)assembling.bytes[used++]=b;else if(b!=0xa5){used=0;resyncCount++;}}
        else {assembling.bytes[used++]=b;if(used==16){used=0;if(xQueueSend(toBle,&assembling,0)!=pdTRUE){uartErrors++;forceDisconnect=true;}}}
    }
    // Keep the queued response until the BLE host accepts notify; application
    // ACK retry still covers losses after the host accepts a notification.
    if(notifying && notifyResult==1){xQueueReceive(toBle,&p,0);notifying=false;notifyAttempts=0;notifyResult=0;}
    if(notifying && (notifyResult==-1 || now-notifyTime>500)){
        notifying=false;notifyResult=0;if(++notifyAttempts>=3){notifyErrors++;forceDisconnect=true;}
    }
    if(!notifying&&now-notifyTime>=15&&xQueuePeek(toBle,&p,0)==pdTRUE){notifying=true;notifyResult=0;notifyTime=now;txChar->setValue(p.bytes,16);txChar->notify();}
    if(now-lastStats>=5000){lastStats=now;Serial.printf("bridge counters BLEwrite=%lu UART=%lu notify=%lu resync=%lu\n",(unsigned long)bleWriteErrors,(unsigned long)uartErrors,(unsigned long)notifyErrors,(unsigned long)resyncCount);}
    delay(1);
}
