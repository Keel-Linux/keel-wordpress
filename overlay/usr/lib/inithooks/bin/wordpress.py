#!/usr/bin/python3
"""Ask for the WordPress values that the inithooks conf did not provide.

Called by firstboot.d/40wordpress only when a terminal is attached and a value
is absent; prints one KEY=value line per requested name on stdout so the hook
keeps the decisions and this file keeps the dialogs. On a headless first boot
the hook fails instead of calling this, because the values it needs are
declared: secrets.app_password and secrets.db_password of the instance
description.

Syntax: wordpress.py NAME [NAME ...]     NAME is APP_PASS or DB_PASS
"""

import sys

from libinithooks.dialog_wrapper import Dialog

TITLE = "Keel - First boot configuration"

PROMPTS = {
    "APP_PASS": (
        "WordPress password",
        "Enter the password for the WordPress administrator account.",
    ),
    "DB_PASS": (
        "WordPress database password",
        "Enter the password for the WordPress database account.",
    ),
}


def ask(name: str, dialog: Dialog) -> str:
    """Ask for one value, by the name the hook uses for it."""
    try:
        title, text = PROMPTS[name]
    except KeyError:
        raise SystemExit(f"wordpress.py: unknown value name {name!r}") from None
    return dialog.get_password(title, text)


def main(names: list[str]) -> int:
    """Print one KEY=value line per requested name."""
    if not names:
        print(__doc__, file=sys.stderr)
        return 1
    dialog = Dialog(TITLE)
    for name in names:
        print(f"{name}={ask(name, dialog)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
