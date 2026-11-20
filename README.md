# CastCounter

A WoW 1.12 (Interface 11200) addon that counts how many times you cast each of your spells. It shows the counts in a damage-meter-style window and can report them to chat. It was made for Azeroth Survivors and works in any 1.12 client.

## Features

- Counts **your own** casts per spell from the combat log. The several hits from one AoE cast count as a single cast.
- Meter window with bars in your class colour, showing each spell's count and its share of the total. Hovering a row shows its casts, hits and hits per cast.
- Uses Azeroth FieldKit's look when FieldKit is installed, and a matching built-in style otherwise.
- Report panel: send the top spells to Say, Party, Raid, Guild, Officer or a whisper, choosing how many lines to send.
- Counts are saved between sessions, separately for each character.

## Install

Copy the `CastCounter` folder into your `AddOns` folder (for Azeroth Survivors, `benilla-config\AddOns`) and reload the UI.

## Commands

| Command | What it does |
|---|---|
| `/cc` | Show or hide the window |
| `/cc reset` | Clear your counts |
| `/cc report [say\|party\|raid\|guild\|officer\|whisper <name>\|channel <n>] [lines]` | Report the top spells to chat |
| `/cc window <seconds>` | How close together hits can be and still count as one cast (default 0.4) |
| `/cc rows <n>` | How many rows the window shows |

`/castcounter` works too.
