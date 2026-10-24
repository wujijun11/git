// Executes the real sketch with deterministic Arduino/FreeRTOS/BLE stubs.
// It tests scheduling boundaries, not RF latency or ESP32 ISR/thread behavior.
#include <iostream>
#include <stdexcept>
#include <array>
#ifndef BRIDGE_SKETCH
#define BRIDGE_SKETCH "../../firmware/ble_bridge/ble_bridge.ino"
#endif
#include BRIDGE_SKETCH
static void check(bool value,const char*message){if(!value)throw std::runtime_error(message);}
static uint8_t crc(const std::array<uint8_t,16>&p){unsigned c=0;for(unsigned i=2;i<15;++i){c^=p[i];for(unsigned bit=0;bit<8;++bit)c=((c&128)?(c<<1)^7:c<<1)&255;}return static_cast<uint8_t>(c);}
static std::array<uint8_t,16> packet(unsigned id){std::array<uint8_t,16> p={0xa5,0x5a,1,static_cast<uint8_t>(id),0x80};for(unsigned i=5;i<15;++i)p[i]=static_cast<uint8_t>(id+i);p[15]=crc(p);return p;}
static std::array<uint8_t,16> nestedPacket(unsigned id){auto p=packet(id);p[8]=0xa5;p[9]=0x5a;p[15]=crc(p);return p;}
static BLECharacteristic *rx(){return server->service.chars.at(1);}
static void writePacket(unsigned id){auto p=packet(id);rx()->setValue(p.data(),p.size());testTask=reinterpret_cast<void*>(2);rx()->callbacks->onWrite(rx());testTask=reinterpret_cast<void*>(1);}
static void badWrite(){uint8_t b=0;rx()->setValue(&b,1);testTask=reinterpret_cast<void*>(2);rx()->callbacks->onWrite(rx());testTask=reinterpret_cast<void*>(1);}
static void connect(){testTask=reinterpret_cast<void*>(2);server->callbacks->onConnect(server);testTask=reinterpret_cast<void*>(1);}
static void disconnect(){testTask=reinterpret_cast<void*>(2);server->callbacks->onDisconnect(server);testTask=reinterpret_cast<void*>(1);}
static void uartPacket(unsigned id){for(auto b:packet(id))Serial1.rx.push_back(b);}
static void loops(unsigned count){for(unsigned i=0;i<count;++i)loop();}
static void feed(const std::array<uint8_t,16>&p){for(auto b:p)Serial1.rx.push_back(b);}
static std::string wire(const std::array<uint8_t,16>&p){return std::string(reinterpret_cast<const char*>(p.data()),16);}
static void drain(){loops(550);check(server->disconnectRequests==0,"parser recovery unexpectedly disconnected session");}
static void failUntilDisconnect(const char *reason){
    const auto writes=Serial1.writes.size(),notifications=txChar->notifications.size();
    loops(40);
    check(Serial1.writes.size()==writes,reason);
    check(txChar->notifications.size()==notifications,"failed session notified after asynchronous disconnect request");
    check(server->disconnectRequests==1,"disconnect request was not bounded to once per failed session");
}
int main(int argc,char **argv){
 try {
    check(argc==2,"provide one test name");setup();connect();
    const std::string name=argv[1];
    if(name=="first_write"){
        writePacket(1);loop();check(Serial1.writes.size()==1,"first command lost before first loop");auto expected=packet(1);check(Serial1.writes[0]==std::vector<uint8_t>(expected.begin(),expected.end()),"wire bytes changed");
    }else if(name=="malformed_close"){
        writePacket(1);badWrite();loop();failUntilDisconnect("queued command escaped malformed-write failure");
    }else if(name=="late_write_close"){
        badWrite();loop();writePacket(2);failUntilDisconnect("new command escaped while disconnect callback delayed");
    }else if(name=="queue_full_close"){
        for(unsigned i=0;i<9;++i)writePacket(i);loop();failUntilDisconnect("queued command escaped queue-full failure");
    }else if(name=="uart_error_close"){
        writePacket(1);Serial1.error(UART_TEST_ERROR);loop();failUntilDisconnect("queued command escaped UART error");
    }else if(name=="short_uart_close"){
        loop();Serial1.nextWriteSize=7;writePacket(1);loop();loop();writePacket(2);failUntilDisconnect("new command escaped short-UART-write failure");
    }else if(name=="same_loop_uart_error"){
        loop();for(unsigned i=0;i<33;++i)uartPacket(i);loop();check(txChar->notifications.empty(),"response notified in same loop as queue overflow");loop();failUntilDisconnect("response overflow did not close transport");
    }else if(name=="notify_retry_close"){
        loop();uartPacket(1);txChar->nextStatus=BLECharacteristicCallbacks::ERROR_GATT;
        for(unsigned i=0;i<80 && server->disconnectRequests==0;++i)loop();
        check(server->disconnectRequests==1,"three notify failures did not close connection");
        check(txChar->notifications.size()==3,"notify retry exceeded three attempts");
        writePacket(3);failUntilDisconnect("failed notify session resumed forwarding");
    }else if(name=="notify_accept"){
        loop();uartPacket(2);loop();check(txChar->notifications.size()==1,"response not notified");loop();check(toBle->values.empty(),"accepted response not consumed");
    }else if(name=="late_notify_status"){
        loop();uartPacket(2);txChar->nextStatus=BLECharacteristicCallbacks::ERROR_GATT;loop();
        testTask=reinterpret_cast<void*>(2);txChar->callbacks->onStatus(txChar,BLECharacteristicCallbacks::SUCCESS_NOTIFY,0);testTask=reinterpret_cast<void*>(1);
        check(notifyResult.load()==-1,"late host callback overwrote failed current attempt");loop();check(toBle->values.size()==1,"late callback dequeued response");
    }else if(name=="reconnect_first_write"){
        writePacket(1);badWrite();loop();disconnect();connect();writePacket(2);loop();check(Serial1.writes.size()==1,"reconnect first command lost or stale command sent");auto expected=packet(2);check(Serial1.writes[0]==std::vector<uint8_t>(expected.begin(),expected.end()),"reconnect forwarded old command");
    }else if(name=="reconnect_between_loops"){
        writePacket(1);disconnect();connect();writePacket(3);loop();check(Serial1.writes.size()==1,"rapid reconnect lost first command");auto expected=packet(3);check(Serial1.writes[0]==std::vector<uint8_t>(expected.begin(),expected.end()),"rapid reconnect leaked stale packet");
    }else if(name=="partial_uart_timeout"){
        loop();Serial1.rx.push_back(0xa5);Serial1.rx.push_back(0x5a);loop();testMillis+=21;uartPacket(8);loop();check(txChar->notifications.size()==1,"parser failed to recover partial timeout");auto expected=packet(8);check(txChar->notifications[0]==std::string(reinterpret_cast<char*>(expected.data()),16),"recovered UART frame changed");
    }else if(name=="old_failure_new_session"){
        loop();
        auto old=sessionGeneration();disconnect();connect();failSession(old);
        writePacket(4);loop();check(Serial1.writes.size()==1,"old error closed replacement session");check(server->disconnectRequests==0,"old error disconnected replacement client");
    }else if(name=="stale_failure_cannot_unpoison"){
        auto old=sessionGeneration();disconnect();connect();writePacket(4);badWrite();failSession(old);
        loop();check(Serial1.writes.empty(),"stale error replaced current failed-session marker");failUntilDisconnect("new failure cleared by old callback");
    }else if(name=="failed_writes_do_not_fill_queue"){
        badWrite();for(unsigned i=0;i<9;++i)writePacket(i);check(toUart->values.empty(),"writes filled queue after session was poisoned");loop();failUntilDisconnect("failed writes escaped to UART");
    }else if(name=="valid_nested_header"){
        loop();auto expected=nestedPacket(7);feed(expected);loop();drain();check(txChar->notifications.size()==1 && txChar->notifications[0]==wire(expected),"valid payload header altered or split frame");
    }else if(name=="crc_error_recovery"){
        loop();auto bad=packet(1);bad[12]^=0x40;feed(bad);auto expected=packet(2);feed(expected);loop();drain();check(txChar->notifications.size()==1 && txChar->notifications[0]==wire(expected),"CRC-corrupt frame forwarded or subsequent ACK lost");check(resyncCount.load()>0,"CRC loss absent from diagnostics");
    }else if(name=="deleted_byte_nested_recovery"){
        loop();auto first=nestedPacket(0);for(unsigned i=0;i<16;++i)if(i!=7)Serial1.rx.push_back(first[i]);for(unsigned id=1;id<=8;++id)feed(nestedPacket(id));loop();drain();check(txChar->notifications.size()==8,"deleted UART byte locked parser onto nested payload headers");for(unsigned id=1;id<=8;++id)check(txChar->notifications[id-1]==wire(nestedPacket(id)),"resync changed later valid frame");
    }else if(name=="inserted_byte_nested_recovery"){
        loop();auto first=nestedPacket(0);for(unsigned i=0;i<16;++i){if(i==7)Serial1.rx.push_back(0x77);Serial1.rx.push_back(first[i]);}for(unsigned id=1;id<=8;++id)feed(nestedPacket(id));loop();drain();check(txChar->notifications.size()==8,"inserted UART byte prevented recovery");for(unsigned id=1;id<=8;++id)check(txChar->notifications[id-1]==wire(nestedPacket(id)),"insertion recovery changed valid frame");
    }else if(name=="overlapping_header_recovery"){
        loop();Serial1.rx.push_back(0xa5);feed(packet(3));loop();drain();check(txChar->notifications.size()==1 && txChar->notifications[0]==wire(packet(3)),"overlapping A5 A5 5A lost valid frame");
    }else if(name=="fragmented_all_boundaries"){
        loop();for(unsigned split=1;split<16;++split){auto p=nestedPacket(split);for(unsigned i=0;i<split;++i)Serial1.rx.push_back(p[i]);loop();testMillis+=5;for(unsigned i=split;i<16;++i)Serial1.rx.push_back(p[i]);loop();loops(18);}drain();check(txChar->notifications.size()==15,"fragmented frames lost");for(unsigned i=0;i<15;++i)check(txChar->notifications[i]==wire(nestedPacket(i+1)),"fragmented bytes changed");
    }else if(name=="noise_then_fragmented_header"){
        loop();for(unsigned i=0;i<96;++i)Serial1.rx.push_back(static_cast<uint8_t>(i));Serial1.rx.push_back(0xa5);loop();testMillis+=5;auto p=packet(4);for(unsigned i=1;i<16;++i)Serial1.rx.push_back(p[i]);loop();drain();check(txChar->notifications.size()==1 && txChar->notifications[0]==wire(p),"noise or split header blocked recovery");
    }else if(name=="consecutive_crc_errors"){
        loop();for(unsigned id=0;id<20;++id){auto p=nestedPacket(id);p[15]^=1;feed(p);}auto expected=nestedPacket(90);feed(expected);loop();drain();check(txChar->notifications.size()==1 && txChar->notifications[0]==wire(expected),"consecutive CRC errors forwarded junk or lost final ACK");
    }else if(name=="reconnect_partial_response"){
        loop();auto old=packet(7);for(unsigned i=0;i<8;++i)Serial1.rx.push_back(old[i]);loop();disconnect();connect();loop();for(unsigned i=8;i<16;++i)Serial1.rx.push_back(old[i]);auto expected=nestedPacket(8);feed(expected);loop();drain();check(txChar->notifications.size()==1 && txChar->notifications[0]==wire(expected),"partial old response crossed session boundary");
    }else if(name=="reconnect_queued_response"){
        loop();uartPacket(7);loop();disconnect();connect();loop();auto start=txChar->notifications.size();feed(packet(8));loop();drain();check(txChar->notifications.size()==start+1 && txChar->notifications.back()==wire(packet(8)),"old queued response leaked into new session");
    }else if(name=="ble_crc_left_for_fpga"){
        auto invalid=packet(9);invalid[15]^=1;rx()->setValue(invalid.data(),16);rx()->callbacks->onWrite(rx());loop();check(Serial1.writes.size()==1 && Serial1.writes[0]==std::vector<uint8_t>(invalid.begin(),invalid.end()),"bridge rewrote or interpreted BLE request CRC");
    }else if(name=="crc_valid_future_version_transparent"){
        loop();auto p=packet(10);p[2]=2;p[15]=crc(p);feed(p);loop();drain();check(txChar->notifications.size()==1 && txChar->notifications[0]==wire(p),"bridge interpreted UART protocol version instead of CRC framing");
    }else if(name=="diagnostic_endianness"){
        bleWriteErrors=0x12345678;uartErrors=0x90abcdef;notifyErrors=0x01020304;resyncCount=0;
        diagChar->callbacks->onRead(diagChar);auto v=diagChar->getValue();check(v.size()==16,"wrong diagnostic length");check(static_cast<uint8_t>(v[0])==0x78 && static_cast<uint8_t>(v[3])==0x12 && static_cast<uint8_t>(v[4])==0xef,"diagnostic endian mismatch");
    }else throw std::runtime_error("unknown test");
    std::cout<<"PASS "<<name<<"\n";return 0;
 }catch(const std::exception&e){std::cerr<<"FAIL "<<argv[1]<<": "<<e.what()<<"\n";return 1;}
}
