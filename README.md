# Dr. Sbaitso: Reborn
**Welcome to 2024 Dr. Sbaitso. We've been waiting for you.** <br/>
An unofficial, fan-made modern recreation for retro-computing enthusiasts.

<p align="center">
  <img src="DrSbaitsoRebornBanner.png" width="512"/>
</p>

#
HELLO `<GITHUB-USER>`, MY NAME IS DOCTOR SBAITSO.

I AM HERE TO HELP YOU.<br/>
SAY WHATEVER IS IN YOUR MIND FREELY,<br/>
OUR CONVERSATION WILL BE KEPT IN STRICT CONFIDENCE.<br/>
MEMORY CONTENTS WILL BE WIPED OFF AFTER YOU LEAVE,<br/>

SO, TELL ME ABOUT YOUR PROBLEMS.

#

A front-end for Dr. Sbaitso created in `Zig` and `Raylib 5.5`: For modern Desktops as a standalone application.

For historical context on what Dr. Sbaitso is [read the wikipedia article](https://en.wikipedia.org/wiki/Dr._Sbaitso).

This will not run without the backend-system which I have not made public yet as it needs more work.
This version of Dr. Sbaitso is intended to build just enough of this version that it is nearly
indistinguishable from the original however it will never be an exact clone.

Additionally, I will eventually build a plugin system for swapping out the voice synthesis with other
systems. And furthermore a plugin system for having a true AI powered backend (such as ChatGPT) to control 
the good Dr.'s mind.

While I don't antcipate this project to be terribly complex it should offer a good example of how to use true
native OS threading in a GUI-based application such as Raylib. All cross-thread communication happens via
the use of thread-safe queues. Anything that potentially blocks the Raylib event loop will occur in an auxillary
thread. Additionally, should an auxillary thread need to communicate back to the main Raylib thread there is
a "main thread" dispatcher to handle this.

## Current Features
1. The Dr.'s **original** voice
2. A native app: No DosBox, DosBox-X, DosBox-Staging, FreeDOS, VirtualBox or x86-Box required!
2. Faithful recreation of the Dr.'s Turbo C DOS environment
3. All of the Dr.s original text-to-speech responses
4. Ability to change background color, font, forground color
5. More to come...

## How it works

1. When running in default mode, the game loads up a `.json` definition file of responses
2. These responses were harvested from the original's binary and should be nearly accurate.
3. Like the original, the app announces the `Creative Labs` banner, asks for the user's name and
   greets the user with the canonical introduction.
4. At this point, the user can type any questions or statements to kick off the conversation.
5. Upon submitting a statement or question, the app will attempt to match the user's input with
   an appropriate response. Responses are not random by round-robin like the original. This simple
   idea mitigates the end-user from having to hear too many repeated responses.
6. If the user repeats what they types in, a special response category is used taunting the user
   about saying the same thing twice. There are actually two categories for this.
7. If the user enters garbage like: `@als398$#$#%`, a response category for garbage input is used.
   Detecting garbage is not as straightforward as you would think, so this isn't done yet.
8. If the user curses; (bad words), the app will chastise the user or potentially go into `parity`
   error like the original Dr. Sbaitso app did. Parity mode is what happens when the Dr. refuses
   to process your filth!
9. If still no response is found, a category of *generic* responses will be used to move the
   conversation along.
10. Finally, when a valid response is selected the app will dispatch the text to the speech-synthesis
   engine in a dedicated thread where it will immediately be heard by the end user and rendered to 
   the screen.

## Enhancements
- [ ] Modernized, newer canned responses to make Dr. Sbaitso aware of current times.
    He will know about new things like: Tik-Tok, Harry Styles and [Domingo](https://www.youtube.com/watch?v=RLn5qNngGn4)
- [ ] Ability to change background color, font color, font style
- [ ] Ability to enable/disable CRT shader, or enable/disable CRT monitor border
- [ ] Ability to swap speech-synthesis backends
- [ ] Ability to adjust prosody and or tone, volume, pitch, speed of speech engine
- [ ] Ability to plugin in an AI brain like ChatGPT, or other systems
- [ ] Various easter-eggs, retro-computing references, etc
- [ ] The Dr. may become impatient if you don't say anything after awhile.

## Credits
* [CRT Monitor Graphic - by Halfingr](https://www.deviantart.com/halfingr/art/Vectorized-CRT-Monitor-Stock-PNG-292314284)

## Observations
1. If he asks for an age: "ARE YOU SERIOUS? HOW OLD ARE YOU?", any user repsponse will be followed up with
   something like: "WAIT A FEW MORE YEARS, KID" even you type anything. If you type an age: 77 you'll get "I PREFER SOMEONE YOUNGER"
2. In the strings dump of sbaitso.exe some responses are pre-quoted like: "`2TOO LITTLE DATA, SO I MAKE BIG" this causes
   them to follow up with something special like:
   * 1 => Give user ability to <C>ontinue <N>ew patient <Q>uit ....
   * 2 => Adjust screen to 40 characters per line instead of the normal 80
   * 3 => Change the color
   * 4 => Do an age challenge
   * Parity is not included in this list, but that's the only other easter egg.