"""Actual .ino regression with a deterministic NimBLE default host event queue.

No target device, BLE radio or SDK write. Host-only compiler execution.
"""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]
DIAG = PROJECT / "verification/c3-diagnostic-20261022/host-tests/run_diagnostic_host_tests.py"
SDK_RUNNER = PROJECT / "verification/code-hardening-20261023/c3-deferred-write/run_sdk_write_tests.py"

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

NPL = r'''
#pragma once
struct ble_npl_event;
using ble_npl_event_fn=void(struct ble_npl_event *);
struct ble_npl_event { ble_npl_event_fn *function=nullptr;void *argument=nullptr;bool queued=false; };
struct ble_npl_eventq { std::deque<ble_npl_event *> events; };
inline ble_npl_eventq testHostQueue;
inline bool testAutoHostEvents=true,testDispatchingHost=false;
inline unsigned testHostPosts=0,testHostCallbacks=0;
inline std::function<void()> testBeforeHostDispatch;
inline ble_npl_eventq *nimble_port_get_dflt_eventq(){return &testHostQueue;}
inline void ble_npl_event_init(ble_npl_event *event,ble_npl_event_fn *function,void *argument){
    event->function=function;event->argument=argument;event->queued=false;
}
inline void *ble_npl_event_get_arg(ble_npl_event *event){return event->argument;}
inline void ble_npl_eventq_put(ble_npl_eventq *queue,ble_npl_event *event){
    if(!event->function)throw std::runtime_error("NPL event posted before init");
    if(!event->queued){event->queued=true;queue->events.push_back(event);++testHostPosts;}
}
inline void testRunHostEvents(){
    if(testDispatchingHost)return;
    testDispatchingHost=true;
    auto previous=testTask;testTask=reinterpret_cast<void*>(2);
    if(testBeforeHostDispatch){auto hook=std::move(testBeforeHostDispatch);testBeforeHostDispatch=nullptr;hook();}
    while(!testHostQueue.events.empty()){
        auto event=testHostQueue.events.front();testHostQueue.events.pop_front();event->queued=false;
        ++testHostCallbacks;event->function(event);
    }
    testTask=previous;testDispatchingHost=false;
}
'''

CLOSE_CASES = ("failed_close_reconnect", "failed_close_reused_handle", "close_on_host_once",
               "duplicate_close_requests", "host_close_then_reconnect", "new_failure_replaces_old_close")
CLOSE_BRANCHES = r'''
    }else if(name=="failed_close_reconnect" || name=="failed_close_reused_handle"){
        loop();
        const uint32_t oldSession=sessionGeneration();
        bool replaced=false;
        auto replace=[&](){
            if(replaced)return;
            replaced=true;disconnect();
            if(name=="failed_close_reconnect")server->currentConnId=9;
            connect();writePacket(9);
        };
        badWrite();
        // Old implementation uses getConnId on loop(). New implementation
        // posts an event, letting queued GAP lifecycle callbacks run first.
        server->beforeGetConnId=replace;
        testBeforeHostDispatch=replace;
        loop();
        check(replaced && sessionGeneration()!=oldSession && healthySession(sessionGeneration()),"replacement session was not established by the controlled schedule");
        check(server->disconnectRequests==0,"old failed-session cleanup disconnected replacement connection");
        loop();
        check(Serial1.writes.size()==1,"replacement first command was lost");
    }else if(name=="close_on_host_once"){
        loop();badWrite();loop();loops(40);
        check(server->disconnectRequests==1,"normal failed session did not request exactly one close");
        check(server->lastDisconnect==7,"normal close selected wrong connection");
        check(server->lastDisconnectTask==reinterpret_cast<void*>(2),"close did not execute on the BLE host task");
        check(testHostPosts==1 && testHostCallbacks==1,"persistent close event was missing or repeated");
        writePacket(4);failUntilDisconnect("failed transport resumed before actual disconnect");
    }else if(name=="duplicate_close_requests"){
        loop();testAutoHostEvents=false;badWrite();
#if TEST_HAS_HOST_CLOSE
        const auto failedState=sessionState.load();
        requestSessionClose(failedState);requestSessionClose(failedState);requestSessionClose(failedState);
        check(testHostQueue.events.size()==1 && testHostPosts==1,"NPL duplicated an already queued persistent event");
        check(server->disconnectRequests==0,"close bypassed the host queue");
        testRunHostEvents();
        check(server->disconnectRequests==1 && testHostCallbacks==1,"coalesced close executed more than once");
#endif
    }else if(name=="host_close_then_reconnect"){
        loop();badWrite();
        const auto oldFailed=sessionState.load();
        loop();check(server->disconnectRequests==1,"old failed session was not closed");
        disconnect();connect();writePacket(9);
#if TEST_HAS_HOST_CLOSE
        requestSessionClose(oldFailed);testRunHostEvents();
#endif
        check(healthySession(sessionGeneration()),"replacement session was poisoned");
        check(server->disconnectRequests==1,"late old host event closed replacement session");
        loop();check(Serial1.writes.size()==1,"first replacement command was lost after host close");
    }else if(name=="new_failure_replaces_old_close"){
        loop();testAutoHostEvents=false;badWrite();loop();
        disconnect();connect();badWrite();loop();
#if TEST_HAS_HOST_CLOSE
        check(testHostQueue.events.size()==1,"queued persistent close was not coalesced");
        testRunHostEvents();
        check(server->disconnectRequests==1,"new generation failure did not replace stale close request");
        check(server->lastDisconnectTask==reinterpret_cast<void*>(2),"replacement failure close escaped host task");
#endif
'''

def prepare_base(output, has_close):
    prior = load(DIAG, "diag_for_base")
    base = output / "harness"
    shutil.copytree(prior.ORIGINAL / "stubs", base / "stubs")
    for name in ("run-bridge-tests.py", "bridge_transport_test.cpp"):
        shutil.copyfile(prior.ORIGINAL / name, base / name)
    npl = base / "stubs/nimble/nimble_port.h"
    npl.parent.mkdir(parents=True)
    npl.write_text(NPL, encoding="utf-8")
    arduino = base / "stubs/Arduino.h"
    text = arduino.read_text(encoding="utf-8").replace("#include <cstdint>", "#include <cstdint>\n#include <stdexcept>")
    text = text.replace("inline void delay(unsigned n){testMillis+=n;}", '#include "nimble/nimble_port.h"\ninline void delay(unsigned n){testMillis+=n;if(testAutoHostEvents)testRunHostEvents();}')
    arduino.write_text(text, encoding="utf-8")
    ble = base / "stubs/BLEDevice.h"
    text = ble.read_text(encoding="utf-8")
    text = text.replace("unsigned disconnectRequests=0;", "unsigned disconnectRequests=0;\n    unsigned currentConnId=7,lastDisconnect=0;\n    void *lastDisconnectTask=nullptr;\n    std::function<void()> beforeGetConnId;")
    text = text.replace("unsigned getConnId(){return 7;}", "unsigned getConnId(){if(beforeGetConnId && testTask==reinterpret_cast<void*>(1)){auto hook=std::move(beforeGetConnId);beforeGetConnId=nullptr;hook();}return currentConnId;}")
    text = text.replace("void disconnect(unsigned){++disconnectRequests;}", "void disconnect(unsigned id){++disconnectRequests;lastDisconnect=id;lastDisconnectTask=testTask;}")
    ble.write_text(text, encoding="utf-8")
    harness = base / "bridge_transport_test.cpp"
    text = harness.read_text(encoding="utf-8")
    text = text.replace("static void connect(){testTask=", "static void connect(){auto previous=testTask;testTask=")
    text = text.replace("server->callbacks->onConnect(server);testTask=reinterpret_cast<void*>(1);", "server->callbacks->onConnect(server);testTask=previous;")
    text = text.replace("static void disconnect(){testTask=", "static void disconnect(){auto previous=testTask;testTask=")
    text = text.replace("server->callbacks->onDisconnect(server);testTask=reinterpret_cast<void*>(1);", "server->callbacks->onDisconnect(server);testTask=previous;")
    text = "#define TEST_HAS_HOST_CLOSE " + ("1" if has_close else "0") + "\n" + text
    harness.write_text(text, encoding="utf-8")
    return base

def execute_variant(output, label, source, add_sdk=False):
    target = output / label
    target.mkdir()
    work = PROJECT / "tmp/cclose" / output.name.removeprefix("host-close_") / label
    work.mkdir(parents=True)
    base = prepare_base(work, "void requestSessionClose(" in source.read_text(encoding="utf-8"))
    module = load(DIAG, "diag_"+label)
    module.HERE = work
    module.ORIGINAL = base
    module.SOURCE = source
    module.UART_HELPER = source.with_name("bridge_uart_io.h")
    if not add_sdk:
        module.EXTRA_CASES += CLOSE_CASES
        module.EXTRA_BRANCHES += CLOSE_BRANCHES
    else:
        sdk = load(SDK_RUNNER, "sdk_functions")
        ble = base / "stubs/BLEDevice.h"
        text = ble.read_text(encoding="utf-8")
        text = text.replace('#include "Arduino.h"', '#include "Arduino.h"\n'+sdk.SDK_STUBS)
        text = text.replace("virtual void onWrite(BLECharacteristic*){}", "virtual void onWrite(BLECharacteristic*){}\n    virtual void onWrite(BLECharacteristic *c,ble_gap_conn_desc *){onWrite(c);}")
        text = text.replace("virtual void onRead(BLECharacteristic*){}", "virtual void onRead(BLECharacteristic*){}\n    virtual void onRead(BLECharacteristic *c,ble_gap_conn_desc *){onRead(c);}")
        text = text.replace("class BLECharacteristic {\npublic:", "class BLECharacteristic {\npublic:\n"+sdk.MEMBERS)
        text = text.replace("void setCallbacks(BLECharacteristicCallbacks*c){callbacks=c;}", "void setCallbacks(BLECharacteristicCallbacks*c){callbacks=c;m_pCallbacks=c;}")
        ble.write_text(text, encoding="utf-8")
        vendor = sdk.VENDOR.read_text(encoding="utf-8")
        functions = sdk.function(vendor, "void BLECharacteristic::processDeferredWriteCallback(void *pvParameters)") + "\n" + sdk.function(vendor, "int BLECharacteristic::handleGATTServerEvent(uint16_t conn_handle,")
        (target / "actual_sdk_functions.cpp").write_text(functions, encoding="utf-8")
        module.HELPERS += "\n"+functions+"\n"+sdk.SDK_HELPERS
        module.EXTRA_CASES += sdk.CASES
        module.EXTRA_BRANCHES += sdk.BRANCHES
    code = module.main()
    summary = next(work.glob("run_*/summary.json"))
    shutil.copyfile(summary, target / "summary.json")
    for log in summary.parent.glob("*.log"):
        shutil.copyfile(log, target / log.name)
    return {"exitCode": code, "summary": str(summary), **json.loads(summary.read_text(encoding="utf-8"))}

def main():
    output = HERE / ("host-close_"+datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
    output.mkdir()
    source = PROJECT / "firmware/ble_bridge/ble_bridge.ino"
    results = {
        "before": execute_variant(output, "before", HERE / "before/ble_bridge.ino"),
        "after": execute_variant(output, "after", source),
        "sdk_after": execute_variant(output, "sdk-after", source, add_sdk=True),
    }
    critical = {c["name"]:c["passed"] for c in results["before"]["cases"] if c["name"] in CLOSE_CASES[:2]}
    accepted = (len(critical)==2 and not any(critical.values()) and
                results["before"]["compileExit"]==0 and results["before"]["inputsUnchanged"] and
                results["after"]["accepted"] and results["sdk_after"]["accepted"])
    report = {"kind":"actual .ino + deterministic host event queue, no hardware", "accepted":accepted,
              "knownUnchangedLimitation":"UART error callbacks carry no origin session tag; fail-close policy is unchanged",
              "runnerSha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "results":results}
    (output / "result.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    print("Result:", output / "result.json", flush=True)
    return 0 if accepted else 1

if __name__ == "__main__":
    sys.exit(main())
