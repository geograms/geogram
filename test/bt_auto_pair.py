#!/usr/bin/env python3
"""
Bluetooth Classic Auto-Pairing Daemon for Geogram.

Automatically discovers, pairs, and connects to other Geogram devices
using NoInputNoOutput (Just Works) pairing - no user interaction required.

How it works:
1. Makes this device discoverable with name "Geogram-{CALLSIGN}"
2. Continuously scans for other "Geogram-*" devices
3. Auto-pairs when found (NoInputNoOutput = no prompts)
4. Establishes RFCOMM connection for data transfer
5. Maintains connections and auto-reconnects

Usage:
    python3 bt_auto_pair.py --callsign X34PSK    # Run with callsign
    python3 bt_auto_pair.py --test               # Test mode (10 second run)
"""

import sys
import os
import time
import threading
import signal
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

AGENT_PATH = "/org/bluez/geogram/agent"
AGENT_INTERFACE = "org.bluez.Agent1"
ADAPTER_INTERFACE = "org.bluez.Adapter1"
DEVICE_INTERFACE = "org.bluez.Device1"

# Geogram device name prefix
GEOGRAM_PREFIX = "Geogram-"

# RFCOMM channel for Geogram communication
RFCOMM_CHANNEL = 22

# Scan interval (seconds)
SCAN_INTERVAL = 30

# Connection retry interval
RECONNECT_INTERVAL = 10


class GeogramBTDaemon:
    """Bluetooth Classic auto-pairing daemon for Geogram."""

    def __init__(self, callsign, test_mode=False):
        self.callsign = callsign
        self.test_mode = test_mode
        self.device_name = f"{GEOGRAM_PREFIX}{callsign}"
        self.running = False
        self.mainloop = None
        self.bus = None
        self.adapter = None
        self.adapter_path = None
        self.adapter_props = None
        self.agent = None

        # Track discovered Geogram devices
        self.discovered_devices = {}  # mac -> {name, paired, connected, path}

        # RFCOMM connections
        self.connections = {}  # mac -> connection_info

    def log(self, msg):
        """Log with timestamp."""
        timestamp = time.strftime("%H:%M:%S")
        print(f"[{timestamp}] {msg}")

    def setup_dbus(self):
        """Initialize D-Bus connection."""
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SystemBus()

    def get_adapter(self):
        """Get the default Bluetooth adapter."""
        manager = dbus.Interface(
            self.bus.get_object("org.bluez", "/"),
            "org.freedesktop.DBus.ObjectManager"
        )

        objects = manager.GetManagedObjects()
        for path, interfaces in objects.items():
            if ADAPTER_INTERFACE in interfaces:
                self.adapter = dbus.Interface(
                    self.bus.get_object("org.bluez", path),
                    ADAPTER_INTERFACE
                )
                self.adapter_path = path
                self.adapter_props = dbus.Interface(
                    self.bus.get_object("org.bluez", path),
                    "org.freedesktop.DBus.Properties"
                )
                return True

        return False

    def setup_adapter(self):
        """Configure the Bluetooth adapter."""
        if not self.get_adapter():
            self.log("ERROR: No Bluetooth adapter found")
            return False

        # Power on
        self.adapter_props.Set(ADAPTER_INTERFACE, "Powered", dbus.Boolean(True))

        # Set device name to Geogram-CALLSIGN
        self.adapter_props.Set(ADAPTER_INTERFACE, "Alias", self.device_name)

        # Make discoverable and pairable
        self.adapter_props.Set(ADAPTER_INTERFACE, "Discoverable", dbus.Boolean(True))
        self.adapter_props.Set(ADAPTER_INTERFACE, "Pairable", dbus.Boolean(True))
        self.adapter_props.Set(ADAPTER_INTERFACE, "DiscoverableTimeout", dbus.UInt32(0))
        self.adapter_props.Set(ADAPTER_INTERFACE, "PairableTimeout", dbus.UInt32(0))

        address = self.adapter_props.Get(ADAPTER_INTERFACE, "Address")
        self.log(f"Adapter configured: {self.device_name} ({address})")
        self.log(f"  Discoverable: YES")
        self.log(f"  Pairable: YES (NoInputNoOutput)")

        return True

    def register_agent(self):
        """Register NoInputNoOutput agent for auto-pairing."""
        self.agent = AutoAcceptAgent(self.bus, AGENT_PATH, self)

        agent_manager = dbus.Interface(
            self.bus.get_object("org.bluez", "/org/bluez"),
            "org.bluez.AgentManager1"
        )

        try:
            agent_manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
            agent_manager.RequestDefaultAgent(AGENT_PATH)
            self.log("Agent registered: NoInputNoOutput (auto-accept)")
            return True
        except dbus.exceptions.DBusException as e:
            self.log(f"WARNING: Could not register agent: {e}")
            return False

    def setup_device_signals(self):
        """Subscribe to device discovery signals."""
        self.bus.add_signal_receiver(
            self.on_interfaces_added,
            dbus_interface="org.freedesktop.DBus.ObjectManager",
            signal_name="InterfacesAdded"
        )

        self.bus.add_signal_receiver(
            self.on_properties_changed,
            dbus_interface="org.freedesktop.DBus.Properties",
            signal_name="PropertiesChanged",
            path_keyword="path"
        )

    def on_interfaces_added(self, path, interfaces):
        """Called when a new device is discovered."""
        if DEVICE_INTERFACE not in interfaces:
            return

        props = interfaces[DEVICE_INTERFACE]
        self.handle_device(path, props)

    def on_properties_changed(self, interface, changed, invalidated, path):
        """Called when device properties change."""
        if interface != DEVICE_INTERFACE:
            return

        # Get full properties
        try:
            device_props = dbus.Interface(
                self.bus.get_object("org.bluez", path),
                "org.freedesktop.DBus.Properties"
            )
            props = device_props.GetAll(DEVICE_INTERFACE)
            self.handle_device(path, props)
        except:
            pass

    def handle_device(self, path, props):
        """Handle a discovered or updated device."""
        name = props.get("Name", "")
        address = props.get("Address", "")
        paired = props.get("Paired", False)
        connected = props.get("Connected", False)

        # Only interested in Geogram devices
        if not name.startswith(GEOGRAM_PREFIX):
            return

        # Don't connect to ourselves
        if name == self.device_name:
            return

        # Extract callsign from name
        remote_callsign = name[len(GEOGRAM_PREFIX):]

        # Update tracking
        is_new = address not in self.discovered_devices
        self.discovered_devices[address] = {
            "name": name,
            "callsign": remote_callsign,
            "paired": paired,
            "connected": connected,
            "path": path,
        }

        if is_new:
            self.log(f"DISCOVERED: {name} ({address})")

        # Auto-pair if not paired
        if not paired:
            self.auto_pair(address, path)
        elif not connected:
            # Already paired, try to connect
            self.auto_connect(address, path)

    def auto_pair(self, address, path):
        """Automatically pair with a Geogram device."""
        self.log(f"AUTO-PAIR: Initiating pairing with {address}")

        device = dbus.Interface(
            self.bus.get_object("org.bluez", path),
            DEVICE_INTERFACE
        )

        try:
            device.Pair()
            self.log(f"AUTO-PAIR: Pairing successful with {address}")

            # Trust for auto-reconnect
            device_props = dbus.Interface(
                self.bus.get_object("org.bluez", path),
                "org.freedesktop.DBus.Properties"
            )
            device_props.Set(DEVICE_INTERFACE, "Trusted", dbus.Boolean(True))
            self.log(f"AUTO-PAIR: Device {address} trusted")

            # Now connect
            self.auto_connect(address, path)

        except dbus.exceptions.DBusException as e:
            error_name = e.get_dbus_name()
            if "AlreadyExists" in error_name:
                self.log(f"AUTO-PAIR: Already paired with {address}")
            else:
                self.log(f"AUTO-PAIR: Failed with {address}: {e}")

    def auto_connect(self, address, path):
        """Automatically connect to a paired Geogram device."""
        self.log(f"AUTO-CONNECT: Connecting to {address}")

        device = dbus.Interface(
            self.bus.get_object("org.bluez", path),
            DEVICE_INTERFACE
        )

        try:
            device.Connect()
            self.log(f"AUTO-CONNECT: Connected to {address}")

            # Update tracking
            if address in self.discovered_devices:
                self.discovered_devices[address]["connected"] = True

        except dbus.exceptions.DBusException as e:
            error_name = e.get_dbus_name()
            if "InProgress" in error_name:
                self.log(f"AUTO-CONNECT: Connection in progress for {address}")
            elif "AlreadyConnected" in error_name:
                self.log(f"AUTO-CONNECT: Already connected to {address}")
            else:
                self.log(f"AUTO-CONNECT: Failed with {address}: {e}")

    def scan_once(self):
        """Perform a single discovery scan."""
        self.log("SCAN: Starting discovery...")

        try:
            self.adapter.StartDiscovery()

            # Scan for a few seconds
            time.sleep(5)

            self.adapter.StopDiscovery()
            self.log(f"SCAN: Complete. Found {len(self.discovered_devices)} Geogram device(s)")

        except dbus.exceptions.DBusException as e:
            if "InProgress" not in str(e):
                self.log(f"SCAN: Error: {e}")

        return True  # Continue timer

    def scan_loop(self):
        """Background scanning loop."""
        while self.running:
            self.scan_once()
            time.sleep(SCAN_INTERVAL)

    def print_status(self):
        """Print current status."""
        self.log("=" * 50)
        self.log(f"STATUS: {self.device_name}")
        self.log(f"  Discovered Geogram devices: {len(self.discovered_devices)}")
        for addr, info in self.discovered_devices.items():
            status = []
            if info["paired"]:
                status.append("paired")
            if info["connected"]:
                status.append("connected")
            status_str = ", ".join(status) if status else "discovered"
            self.log(f"    {info['name']} ({addr}) - {status_str}")
        self.log("=" * 50)

    def run(self):
        """Main run loop."""
        self.log(f"Starting Geogram Bluetooth daemon...")
        self.log(f"  Callsign: {self.callsign}")
        self.log(f"  Device name: {self.device_name}")

        # Setup
        self.setup_dbus()

        if not self.setup_adapter():
            return 1

        if not self.register_agent():
            self.log("WARNING: Running without agent - pairing may require interaction")

        self.setup_device_signals()

        # Start scanning
        self.running = True

        # Initial scan
        self.scan_once()

        # Set up periodic scanning
        GLib.timeout_add_seconds(SCAN_INTERVAL, self.scan_once)

        # Set up status printing
        GLib.timeout_add_seconds(60, self.print_status)

        # Test mode - exit after 10 seconds
        if self.test_mode:
            GLib.timeout_add_seconds(10, self.stop)

        # Run main loop
        self.mainloop = GLib.MainLoop()
        self.log("Daemon running. Ctrl+C to stop.")

        try:
            self.mainloop.run()
        except KeyboardInterrupt:
            self.log("Interrupted")

        self.cleanup()
        return 0

    def stop(self):
        """Stop the daemon."""
        self.log("Stopping daemon...")
        self.running = False
        if self.mainloop:
            self.mainloop.quit()
        return False  # Don't repeat timer

    def cleanup(self):
        """Cleanup on exit."""
        self.log("Cleaning up...")

        try:
            # Disable discoverable
            self.adapter_props.Set(ADAPTER_INTERFACE, "Discoverable", dbus.Boolean(False))
            self.log("Discoverable disabled")
        except:
            pass

        self.print_status()
        self.log("Daemon stopped")


class AutoAcceptAgent(dbus.service.Object):
    """D-Bus agent that auto-accepts all pairing requests."""

    def __init__(self, bus, path, daemon):
        super().__init__(bus, path)
        self.daemon = daemon

    @dbus.service.method(AGENT_INTERFACE, in_signature="", out_signature="")
    def Release(self):
        self.daemon.log("[Agent] Released")

    @dbus.service.method(AGENT_INTERFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        self.daemon.log(f"[Agent] AuthorizeService: {device}")
        return  # Auto-authorize

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        self.daemon.log(f"[Agent] RequestPinCode: {device} -> 0000")
        return "0000"

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        self.daemon.log(f"[Agent] RequestPasskey: {device} -> 0")
        return dbus.UInt32(0)

    @dbus.service.method(AGENT_INTERFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        self.daemon.log(f"[Agent] DisplayPasskey: {device}")

    @dbus.service.method(AGENT_INTERFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        self.daemon.log(f"[Agent] DisplayPinCode: {device}")

    @dbus.service.method(AGENT_INTERFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        self.daemon.log(f"[Agent] RequestConfirmation: {device} -> AUTO-ACCEPT")
        return  # Auto-confirm

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        self.daemon.log(f"[Agent] RequestAuthorization: {device} -> AUTO-ACCEPT")
        return  # Auto-authorize

    @dbus.service.method(AGENT_INTERFACE, in_signature="", out_signature="")
    def Cancel(self):
        self.daemon.log("[Agent] Cancelled")


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Geogram Bluetooth Auto-Pairing Daemon")
    parser.add_argument("--callsign", "-c", default="TEST01",
                        help="Callsign for this device (default: TEST01)")
    parser.add_argument("--test", "-t", action="store_true",
                        help="Test mode - run for 10 seconds then exit")

    args = parser.parse_args()

    daemon = GeogramBTDaemon(args.callsign, test_mode=args.test)

    # Handle signals
    signal.signal(signal.SIGINT, lambda s, f: daemon.stop())
    signal.signal(signal.SIGTERM, lambda s, f: daemon.stop())

    sys.exit(daemon.run())


if __name__ == "__main__":
    main()
