package android.net;

import android.os.Binder;
import android.os.IBinder;
import android.os.IInterface;
import android.os.RemoteException;

public interface IConnectivityManager extends IInterface {

    // Chains: FIREWALL_CHAIN_METERED = 1, FIREWALL_CHAIN_DOZABLE = 2, FIREWALL_CHAIN_STANDBY = 3
    void setFirewallChainEnabled(int chain, boolean enable) throws RemoteException;

    // Rules: FIREWALL_RULE_DEFAULT = 0, FIREWALL_RULE_ALLOW = 1, FIREWALL_RULE_DENY = 2
    void setUidFirewallRule(int chain, int uid, int rule) throws RemoteException;

    int getUidFirewallRule(int chain, int uid) throws RemoteException;

    abstract class Stub extends Binder implements IConnectivityManager {

        public static IConnectivityManager asInterface(IBinder obj) {
            throw new UnsupportedOperationException();
        }
    }
}