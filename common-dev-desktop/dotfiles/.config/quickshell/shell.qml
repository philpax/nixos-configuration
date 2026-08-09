//@ pragma UseQApplication

import QtQuick
import Quickshell

ShellRoot {
    // One bar per screen. NiriIPC and Theme are singletons resolved by qmldir,
    // so individual modules access them directly.
    Variants {
        model: Quickshell.screens
        delegate: Bar {}
    }
}
