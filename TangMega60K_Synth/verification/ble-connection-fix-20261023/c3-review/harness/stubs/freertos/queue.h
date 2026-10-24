#pragma once
#include "FreeRTOS.h"
#include <deque>
#include <vector>
#include <cstring>
struct TestQueue { unsigned capacity,bytes;std::deque<std::vector<uint8_t>> values; };
using QueueHandle_t=TestQueue *;
inline QueueHandle_t xQueueCreate(unsigned n,unsigned bytes){return new TestQueue{n,bytes,{}};}
inline int xQueueSend(QueueHandle_t q,const void *v,unsigned){if(q->values.size()==q->capacity)return pdFALSE;auto p=static_cast<const uint8_t *>(v);q->values.emplace_back(p,p+q->bytes);return pdTRUE;}
inline int xQueuePeek(QueueHandle_t q,void *v,unsigned){if(q->values.empty())return pdFALSE;memcpy(v,q->values.front().data(),q->bytes);return pdTRUE;}
inline int xQueueReceive(QueueHandle_t q,void *v,unsigned wait){if(xQueuePeek(q,v,wait)!=pdTRUE)return pdFALSE;q->values.pop_front();return pdTRUE;}
