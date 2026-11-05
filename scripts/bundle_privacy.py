"""Privacy declarations required by Chromium in the macOS host application."""

BLUETOOTH_USAGE_DESCRIPTION = (
    'Chromel uses Bluetooth to discover nearby phones and security keys '
    'when signing in to websites with passkeys.'
)


def with_bluetooth_usage(info):
    """Add a usable Bluetooth purpose string, preserving existing declarations."""
    updated = dict(info)
    key = 'NSBluetoothAlwaysUsageDescription'
    value = updated.get(key)
    if not isinstance(value, str) or not value.strip():
        updated[key] = BLUETOOTH_USAGE_DESCRIPTION
    return updated
