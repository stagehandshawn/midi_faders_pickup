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
- sequences ending at `9999`, with the start derived from `LaneCount`
- source executor assignments on the configured source executor range
- MIDI remotes named `midi_faders_pickup_1` upward for however many lanes are configured

The remotes point at the fixed source on page `9999`. After they are created, You still need to set the MIDI CCs to match whatever controller you are using.

## How to use it

1. Import or copy the full `midi_faders_pickup` plugin folder into the MA3 plugins directory.
2. Run the plugin once.
3. If MA3 says anything is missing or wrong, approve the repair.
4. Set the MIDI remote CC numbers the way you want.

## Notes

- Source side is fixed on `Page 9999`
- Target side is the current page
- The ranges come from the variables at the top of `main.lua`
- `LaneCount` should stay between `1` and `15` default is `10`
- Existing sequences are left alone if they already exist
- The plugin will remap the existing pickup remotes back to the fixed source executors each time it starts
