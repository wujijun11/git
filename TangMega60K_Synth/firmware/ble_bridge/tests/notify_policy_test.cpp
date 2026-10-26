#include "../bridge_notify_policy.h"
#include "../bridge_link_policy.h"
#include <cassert>
#include <iostream>

// 检查成功吞吐、失败退避和32位毫秒回绕；不是C3无线吞吐实测。
int main() {
    assert(BRIDGE_INTERVAL_MIN==6 && BRIDGE_INTERVAL_MAX==12);
    assert(BRIDGE_SLAVE_LATENCY==0 && BRIDGE_SUPERVISION_TIMEOUT==400);
    assert(!bridgeNotifyDue(100,100,0));
    assert(bridgeNotifyDue(101,100,0));
    assert(!bridgeNotifyDue(114,100,1));
    assert(bridgeNotifyDue(115,100,1));
    assert(bridgeNotifyDue(115,100,2));
    assert(bridgeNotifyDue(0,UINT32_MAX,0));
    assert(!bridgeNotifyDue(3,UINT32_MAX-2,1));
    unsigned count=0;
    uint32_t previous=0;
    for(uint32_t now=1;now<=300;now++)if(bridgeNotifyDue(now,previous,0)){previous=now;count++;}
    assert(count==300);
    std::cout<<"NOTIFY POLICY PASS: successful notifications have no forced 15ms gap; retry backoff and wrap retained; no radio tested\n";
}
