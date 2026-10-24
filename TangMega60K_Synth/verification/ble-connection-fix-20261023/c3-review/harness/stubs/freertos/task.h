#pragma once
#include "Arduino.h"
using TaskHandle_t=void *;
inline TaskHandle_t xTaskGetCurrentTaskHandle(){return testTask;}
