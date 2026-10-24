#pragma once
#include "Arduino.h"
class BLECharacteristic;
class BLEServer;
class BLECharacteristicCallbacks {
public:
    enum Status { SUCCESS_NOTIFY,ERROR_GATT,ERROR_NO_CLIENT,ERROR_NOTIFY_DISABLED };
    virtual ~BLECharacteristicCallbacks()=default;
    virtual void onRead(BLECharacteristic*){}
    virtual void onWrite(BLECharacteristic*){}
    virtual void onStatus(BLECharacteristic*,Status,uint32_t){}
};
class BLEServerCallbacks {
public:
    virtual ~BLEServerCallbacks()=default;
    virtual void onConnect(BLEServer*){}
    virtual void onDisconnect(BLEServer*){}
};
class BLECharacteristic {
public:
    static constexpr int PROPERTY_NOTIFY=1,PROPERTY_WRITE=2,PROPERTY_READ=4;
    BLECharacteristicCallbacks *callbacks=nullptr;
    std::string value;
    std::vector<std::string> notifications;
    BLECharacteristicCallbacks::Status nextStatus=BLECharacteristicCallbacks::SUCCESS_NOTIFY;
    bool suppressStatus=false;
    String getValue(){return value;}
    void setValue(const uint8_t*p,size_t n){value.assign(reinterpret_cast<const char*>(p),n);}
    template<class T>void addDescriptor(T*){}
    void setCallbacks(BLECharacteristicCallbacks*c){callbacks=c;}
    void notify(){notifications.push_back(value);if(!suppressStatus)callbacks->onStatus(this,nextStatus,0);}
};
class BLEAdvertising {
public:
    unsigned starts=0;
    void addServiceUUID(const char*){}
    void setScanResponse(bool){}
    void start(){++starts;}
};
class BLEService {
public:
    std::vector<BLECharacteristic*> chars;
    BLECharacteristic *createCharacteristic(const char*,int){auto c=new BLECharacteristic;chars.push_back(c);return c;}
    void start(){}
};
class BLEServer {
public:
    BLEServerCallbacks *callbacks=nullptr;
    BLEAdvertising advertising;
    BLEService service;
    unsigned disconnectRequests=0;
    unsigned currentConnId=7;
    unsigned lastDisconnect=0;
    std::function<void()> beforeGetConnId;
    void setCallbacks(BLEServerCallbacks*c){callbacks=c;}
    BLEService*createService(const char*){return &service;}
    BLEAdvertising*getAdvertising(){return &advertising;}
    unsigned getConnId(){if(beforeGetConnId){auto hook=std::move(beforeGetConnId);beforeGetConnId=nullptr;hook();}return currentConnId;}
    // Intentional asynchronous stub: requesting close does not complete it.
    void disconnect(unsigned id){++disconnectRequests;lastDisconnect=id;}
    void startAdvertising(){advertising.start();}
};
class BLEDevice {
public:
    static void init(const char*){}
    static BLEServer*createServer(){return new BLEServer;}
};
