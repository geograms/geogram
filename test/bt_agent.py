#!/usr/bin/env python3
"""
Bluetooth NoInputNoOutput Agent for automated pairing.

This agent auto-accepts all pairing requests without user interaction.
Perfect for headless Linux devices or automated testing.

Usage:
    python3 bt_agent.py                  # Run agent and make device discoverable
    python3 bt_agent.py --pair MAC       # Pair with specific device
    python3 bt_agent.py --scan           # Scan for devices
"""

import sys
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

AGENT_PATH = "/org/bluez/geogram/agent"
AGENT_INTERFACE = "org.bluez.Agent1"
ADAPTER_INTERFACE = "org.bluez.Adapter1"
DEVICE_INTERFACE = "org.bluez.Device1"

# Agent capabilities
CAPABILITY = "NoInputNoOutput"  # Auto-accept, no user interaction


class AutoAcceptAgent(dbus.service.Object):
    """Bluetooth agent that auto-accepts all pairing requests."""

    exit_on_release = True

    def set_exit_on_release(self, exit_on_release):
        self.exit_on_release = exit_on_release

    @dbus.service.method(AGENT_INTERFACE, in_signature="", out_signature="")
    def Release(self):
        print("[Agent] Released")
        if self.exit_on_release:
            mainloop.quit()

    @dbus.service.method(AGENT_INTERFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        print(f"[Agent] AuthorizeService: {device} -> {uuid}")
        # Auto-authorize all services
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        print(f"[Agent] RequestPinCode: {device}")
        # Return fixed PIN for legacy pairing
        return "0000"

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        print(f"[Agent] RequestPasskey: {device}")
        # Return fixed passkey
        return dbus.UInt32(0)

    @dbus.service.method(AGENT_INTERFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        print(f"[Agent] DisplayPasskey: {device} passkey={passkey} entered={entered}")

    @dbus.service.method(AGENT_INTERFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        print(f"[Agent] DisplayPinCode: {device} pin={pincode}")

    @dbus.service.method(AGENT_INTERFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        print(f"[Agent] RequestConfirmation: {device} passkey={passkey}")
        print("[Agent] Auto-confirming (NoInputNoOutput)")
        # Auto-confirm
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        print(f"[Agent] RequestAuthorization: {device}")
        print("[Agent] Auto-authorizing (NoInputNoOutput)")
        # Auto-authorize
        return

    @dbus.service.method(AGENT_INTERFACE, in_signature="", out_signature="")
    def Cancel(self):
        print("[Agent] Pairing cancelled")


def get_adapter(bus):
    """Get the default Bluetooth adapter."""
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/"),
        "org.freedesktop.DBus.ObjectManager"
    )

    objects = manager.GetManagedObjects()
    for path, interfaces in objects.items():
        if ADAPTER_INTERFACE in interfaces:
            return dbus.Interface(
                bus.get_object("org.bluez", path),
                ADAPTER_INTERFACE
            ), path

    raise Exception("No Bluetooth adapter found")


def get_adapter_properties(bus, path):
    """Get adapter properties interface."""
    return dbus.Interface(
        bus.get_object("org.bluez", path),
        "org.freedesktop.DBus.Properties"
    )


def find_device(bus, mac_address):
    """Find a device by MAC address."""
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/"),
        "org.freedesktop.DBus.ObjectManager"
    )

    objects = manager.GetManagedObjects()
    for path, interfaces in objects.items():
        if DEVICE_INTERFACE in interfaces:
            props = interfaces[DEVICE_INTERFACE]
            if props.get("Address", "").upper() == mac_address.upper():
                return path

    return None


def pair_device(bus, mac_address):
    """Initiate pairing with a device."""
    device_path = find_device(bus, mac_address)

    if not device_path:
        # Need to discover the device first
        print(f"Device {mac_address} not found in cache, scanning...")
        adapter, adapter_path = get_adapter(bus)
        adapter.StartDiscovery()

        import time
        for i in range(10):
            time.sleep(1)
            device_path = find_device(bus, mac_address)
            if device_path:
                break
            print(".", end="", flush=True)
        print()

        adapter.StopDiscovery()

        if not device_path:
            print(f"Device {mac_address} not found")
            return False

    print(f"Found device at {device_path}")

    device = dbus.Interface(
        bus.get_object("org.bluez", device_path),
        DEVICE_INTERFACE
    )

    device_props = dbus.Interface(
        bus.get_object("org.bluez", device_path),
        "org.freedesktop.DBus.Properties"
    )

    # Check if already paired
    paired = device_props.Get(DEVICE_INTERFACE, "Paired")
    if paired:
        print("Device already paired")
        return True

    print("Initiating pairing...")
    try:
        device.Pair()
        print("Pairing successful!")

        # Trust the device
        device_props.Set(DEVICE_INTERFACE, "Trusted", dbus.Boolean(True))
        print("Device trusted for auto-reconnect")
        return True
    except dbus.exceptions.DBusException as e:
        print(f"Pairing failed: {e}")
        return False


def scan_devices(bus, duration=10):
    """Scan for nearby Bluetooth devices."""
    adapter, adapter_path = get_adapter(bus)
    props = get_adapter_properties(bus, adapter_path)

    print(f"Scanning for {duration} seconds...")
    adapter.StartDiscovery()

    import time
    time.sleep(duration)

    adapter.StopDiscovery()

    # List discovered devices
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/"),
        "org.freedesktop.DBus.ObjectManager"
    )

    objects = manager.GetManagedObjects()
    print("\nDiscovered devices:")
    for path, interfaces in objects.items():
        if DEVICE_INTERFACE in interfaces:
            device = interfaces[DEVICE_INTERFACE]
            name = device.get("Name", "(unknown)")
            address = device.get("Address", "(unknown)")
            paired = "paired" if device.get("Paired", False) else ""
            print(f"  {address}  {name}  {paired}")


def setup_agent_and_server(bus):
    """Set up the agent and make device discoverable."""
    adapter, adapter_path = get_adapter(bus)
    props = get_adapter_properties(bus, adapter_path)

    # Get current info
    name = props.Get(ADAPTER_INTERFACE, "Name")
    address = props.Get(ADAPTER_INTERFACE, "Address")
    print(f"Adapter: {name} ({address})")

    # Power on
    props.Set(ADAPTER_INTERFACE, "Powered", dbus.Boolean(True))
    print("Adapter powered on")

    # Register agent
    agent = AutoAcceptAgent(bus, AGENT_PATH)
    agent.set_exit_on_release(False)

    agent_manager = dbus.Interface(
        bus.get_object("org.bluez", "/org/bluez"),
        "org.bluez.AgentManager1"
    )

    try:
        agent_manager.RegisterAgent(AGENT_PATH, CAPABILITY)
        print(f"Agent registered with capability: {CAPABILITY}")

        agent_manager.RequestDefaultAgent(AGENT_PATH)
        print("Agent set as default")
    except dbus.exceptions.DBusException as e:
        print(f"Warning: Could not register agent: {e}")
        print("Pairing may require manual confirmation")

    # Make discoverable and pairable
    props.Set(ADAPTER_INTERFACE, "Discoverable", dbus.Boolean(True))
    props.Set(ADAPTER_INTERFACE, "Pairable", dbus.Boolean(True))
    props.Set(ADAPTER_INTERFACE, "DiscoverableTimeout", dbus.UInt32(0))  # Never timeout

    print("Device is now:")
    print(f"  - Discoverable: {props.Get(ADAPTER_INTERFACE, 'Discoverable')}")
    print(f"  - Pairable: {props.Get(ADAPTER_INTERFACE, 'Pairable')}")
    print()
    print("Waiting for connections... (Ctrl+C to exit)")
    print("Other devices can now discover and pair with this device")
    print(f"To pair from another device: bt_agent.py --pair {address}")

    return agent


def main():
    global mainloop

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    if len(sys.argv) > 1:
        if sys.argv[1] == "--scan":
            scan_devices(bus)
            return

        if sys.argv[1] == "--pair" and len(sys.argv) > 2:
            # Need to set up agent first for auto-accept
            agent = AutoAcceptAgent(bus, AGENT_PATH)

            agent_manager = dbus.Interface(
                bus.get_object("org.bluez", "/org/bluez"),
                "org.bluez.AgentManager1"
            )

            try:
                agent_manager.RegisterAgent(AGENT_PATH, CAPABILITY)
                agent_manager.RequestDefaultAgent(AGENT_PATH)
            except:
                pass

            pair_device(bus, sys.argv[2])
            return

        if sys.argv[1] == "--help":
            print(__doc__)
            return

    # Default: run as server
    agent = setup_agent_and_server(bus)

    mainloop = GLib.MainLoop()
    try:
        mainloop.run()
    except KeyboardInterrupt:
        print("\nShutting down...")

    # Cleanup
    adapter, adapter_path = get_adapter(bus)
    props = get_adapter_properties(bus, adapter_path)
    props.Set(ADAPTER_INTERFACE, "Discoverable", dbus.Boolean(False))
    print("Discoverable disabled")


if __name__ == "__main__":
    main()
