# MIDI Faders Pickup

This is a small grandMA3 plugin I put together to make MIDI faders behave like pickup faders instead of jumping right to the incoming value.

The basic idea is:

- MIDI remotes drive a fixed set of source executors on `Page 9999`
- those source executors feed the plugin
- the plugin watches the current page and applies pickup behavior to a target executor range

So you can leave the MIDI side parked on one stable page, then change pages in MA3 and still have the same physical faders control the current page with pickup logic.

## What it sets up

If the setup is missing, the plugin can create:

- `Page 9999`
- pickup sequence ranges for each active controller, based on that controller's `laneCount` and `sequenceEnd`
- source executor assignments on the configured source executor range
- MIDI remotes named like `midi_faders_pickup_Wing1_1` and `midi_faders_gate_Wing1_1` upward for however many lanes are configured

The remotes point at the fixed source on page `9999`. If your CCs are not just sequential from `ccStart`, you still need to go in and change them manually to match your controller.

## How to use it

1. Import or copy the full `midi_faders_pickup` plugin folder into the MA3 plugins directory.
2. Edit the `main.lua`
 - You can set how many controller banks are active by editing `WingCount` default of `2`
 - Edit the `midiChannel` for each controller
 - You can also edit the starting CC note by editing `ccStart`
 - You can edit the number of faders per controller up to a max of 15 by editing `laneCount`
3. Run the plugin once.
4. If MA3 says anything is missing or wrong, approve the repair.
5. Set the MIDI remote CC numbers the way you want if they are not sequential

## Notes

- Source executors are created on `Page 9999` but you can edit `PickupSourcePage` to change this location
- Target side is the current page
- The ranges come from the values at the top of `main.lua`
- Each active controller has its own `laneCount`, and each one should stay between `1` and `15` default is `10`
- The plugin will ask to repair the installation if anything is missing at startup

## Contact
 - stagehandshawn@gmail.com

## Donations - if I've made your life a little easier
 - Cashapp: $stagehandshawn
