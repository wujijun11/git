package cn.tangsynth.remote;

import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCharacteristic;

/** 蓝牙链路策略：只申请连接优先级和选择写类型，不改变应用协议及确认。 */
final class BlePerformanceLink {
    private BlePerformanceLink() { }

    // 应用层仍等待FPGA ACK。旧设备未声明无响应写时必须回退原写法。
    static int writeTypeFor(int properties) {
        return (properties & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
                ? BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                : BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;
    }

    // 返回值只表示系统接受了申请，不表示7.5ms或某个实际延迟已经实现。
    static boolean requestHighPriority(BluetoothGatt gatt) {
        return gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);
    }
}
