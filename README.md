# DrSbaitsoUi

<p align="center">
  <img src="DrSbaitsoRebornBanner.png" width="512"/>
</p>

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

## How it works

1. When running in default mode, the game loads up a `.json` definition file of responses
2. These responses were harvested from the original's binary and should be nearly accurate.
3. Like the original, the app announces the `Creative Labs` banner, asks for the user's name and
   yields an introduction.
4. At this point, the user can type any questions or statements to kick off the conversation.
5. Upon submitting a statement or question, the app will attempt to match the user's input with
   an appropriate response. Responses are not random by round-robin like the original. This simple
   idea mitigates the end-user from having to hear too many repeated responses.
6. If the user repeats what they types in, a special response category is used taunting the user
   about saying the same thing twice. There are actually two categories for this.
7. If the user enters garbage like: @als398$#$#%, a response category for garbage input is used.
   Detecting garbage is not as straightforward as you would think, so this isn't done yet.
8. If the user curses (bad words), the app will chastise the user or potentially go into parity
   error mode much like the original Dr. Sbaitso app did. Parity mode is when the Dr. goes berserk.
9. If still no response is found, a category of *generic* responses will be used to move the
   conversation along.

## Enhancements
- [ ] Modernized, newer canned responses to make Dr. Sbaitso aware of current times
    He will know about new things like: Tik-Tok, Harry Styles and [Domingo](https://www.youtube.com/watch?v=RLn5qNngGn4)
- [ ] Ability to change background color, font color, font style
- [ ] Ability to enable/disable CRT shader, or enable/disable CRT monitor border
- [ ] Ability to swap speech-synthesis backend
- [ ] Ability to adjust prosody and or tone, volume, pitch, speed of speech engine.
- [ ] Ability to plugin in an AI brain like ChatGPT, or other systems
- [ ] Various easter-eggs, some hidden.