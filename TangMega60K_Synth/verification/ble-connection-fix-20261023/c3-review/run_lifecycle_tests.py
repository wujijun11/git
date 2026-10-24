"""Reproduce current-sketch connection-close scheduling boundaries.

Runs the actual production .ino with deterministic host stubs. No COM device,
BLE radio, target board or installed SDK is changed. getConnId is a modeled
scheduling boundary; this proves lifetime logic, not occurrence on hardware.
"""
import importlib.util
from pathlib import Path
import shutil
import sys

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]
SOURCE_RUNNER = PROJECT / "verification/c3-diagnostic-20261022/host-tests/run_diagnostic_host_tests.py"
spec = importlib.util.spec_from_file_location("prior_runner", SOURCE_RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

BASE = HERE / "harness"
BASE.mkdir(exist_ok=True)
shutil.copytree(runner.ORIGINAL / "stubs", BASE / "stubs", dirs_exist_ok=True)
shutil.copyfile(runner.ORIGINAL / "run-bridge-tests.py", BASE / "run-bridge-tests.py")
shutil.copyfile(runner.ORIGINAL / "bridge_transport_test.cpp", BASE / "bridge_transport_test.cpp")
ble = BASE / "stubs/BLEDevice.h"
text = ble.read_text(encoding="utf-8")
text = text.replace("unsigned disconnectRequests=0;", "unsigned disconnectRequests=0;\n    unsigned currentConnId=7;\n    unsigned lastDisconnect=0;\n    std::function<void()> beforeGetConnId;")
text = text.replace("unsigned getConnId(){return 7;}", "unsigned getConnId(){if(beforeGetConnId){auto hook=std::move(beforeGetConnId);beforeGetConnId=nullptr;hook();}return currentConnId;}")
text = text.replace("void disconnect(unsigned){++disconnectRequests;}", "void disconnect(unsigned id){++disconnectRequests;lastDisconnect=id;}")
ble.write_text(text, encoding="utf-8")

runner.HERE = HERE
runner.ORIGINAL = BASE
runner.EXTRA_CASES = ("failed_close_reconnect", "queued_uart_error_reconnect")
runner.EXTRA_BRANCHES = r'''
    }else if(name=="failed_close_reconnect"){
        loop();
        const uint32_t oldSession=sessionGeneration();
        badWrite();
        server->beforeGetConnId=[&](){
            disconnect();
            server->currentConnId=9;
            connect();
            writePacket(9);
        };
        loop();
        check(sessionGeneration()!=oldSession && healthySession(sessionGeneration()),"replacement session was not established by controlled interleave");
        check(server->lastDisconnect!=9,"old failed-session cleanup disconnected the replacement connection");
        loop();
        check(Serial1.writes.size()==1,"replacement first command was lost");
    }else if(name=="queued_uart_error_reconnect"){
        loop();
        const uint32_t oldSession=sessionGeneration();
        // HardwareSerial::_uartEventTask has already dequeued an old UART
        // error, but is preempted before invoking its installed callback.
        auto delayedOldError=Serial1.error;
        disconnect();connect();writePacket(9);
        check(sessionGeneration()!=oldSession && healthySession(sessionGeneration()),"replacement session was not live before old UART callback");
        delayedOldError(UART_TEST_ERROR);
        check(healthySession(sessionGeneration()),"delayed old UART error poisoned the replacement session");
        loop();
        check(Serial1.writes.size()==1 && server->disconnectRequests==0,"replacement handshake was blocked by old UART event");
'''

if __name__ == "__main__":
    sys.exit(runner.main())
