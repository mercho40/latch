import Foundation
import LatchAgentServer

// First, while this is the only thread: every thread created later inherits the mask.
LatchServerMain.prepareSignals()
exit(LatchServerMain.run(Array(CommandLine.arguments.dropFirst())))
