# DrSbaitsoUi
A front-end for Dr. Sbaitso done in Zig and Raylib: For modern Desktops as a standalone application.

This will not run without the backend-system which I have not made public yet as it needs more work.
This version of Dr. Sbaitso is intended to build just enough of this version that it is nearly
indistinguishable from the original however it will not support everything.

Additionally, I will eventually build a plugin system for swapping out the voice synthesis with other
systems. And furthermore a plugin system for having a true AI powered backend (such as ChatGPT) to control 
the good Dr.'s mind.

While I don't antcipate this project to be terribly complex it should offer a good example of how to use true
native OS threading in a GUI-based application such as Raylib. All cross-thread communication happens via
the use of thread-safe queues. Anything that potentially blocks the Raylib event loop will occur in an auxillary
thread. Additionally, should an auxillary thread need to communicate back to the main Raylib thread there is
a dispatcher that can do this.