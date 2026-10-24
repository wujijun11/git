#pragma once
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <string>
#include <vector>
#include <cstdarg>
using String = std::string;
inline uint32_t testMillis=100;
inline void *testTask=reinterpret_cast<void *>(1);
inline uint32_t millis(){return testMillis;}
inline void delay(unsigned n){testMillis+=n;}
inline void rgbLedWrite(int,int,int,int){}
enum hardwareSerial_error_t { UART_TEST_ERROR };
constexpr int SERIAL_8N1=0;
struct TestSerial {
    std::deque<uint8_t> rx;
    std::vector<std::vector<uint8_t>> writes;
    std::function<void(hardwareSerial_error_t)> error;
    int writeSpace=256;
    size_t nextWriteSize=16;
    void begin(int,int=0,int=0,int=0){}
    void setTxTimeoutMs(int){}
    void setRxBufferSize(int){}
    void setTxBufferSize(int){}
    void onReceiveError(std::function<void(hardwareSerial_error_t)> f){error=f;}
    explicit operator bool()const{return false;}
    void println(const char*){}
    void printf(const char*,...){}
    int availableForWrite()const{return writeSpace;}
    int available()const{return static_cast<int>(rx.size());}
    int read(){if(rx.empty())return -1;auto b=rx.front();rx.pop_front();return b;}
    size_t write(const uint8_t *p,size_t n){auto count=nextWriteSize<n?nextWriteSize:n;writes.emplace_back(p,p+count);nextWriteSize=16;return count;}
};
inline TestSerial Serial,Serial1;
