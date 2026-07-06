-- MA3 MIDI Pickup by Shawn R
-- Polls a fixed bank of source executors assigned to pickup sequences
-- and forwards them to a target executor range with pickup behavior,
-- only after the dummy control crosses the current target value.
--
-- Changelog
-- v0.3.0 - Pickup no longer moves the target fader via Lua. Each lane
--          gets a second "gate" MIDI remote that is blocked (pointed at
--          the hidden dummy exec) until pickup, then re-pointed at the
--          real target so MIDI drives it directly.
-- v0.4.0 - Added support for multiple "wings" (separate physical MIDI
--          fader controllers). Each wing has its own MIDI channel,
--          source/target executor ranges, and sequence pool; add more
--          entries to the `Wings` table below to track additional wings.
--
-- How to use
-- On startup the plugin can create the configured pickup sequences,
-- assign them to the configured source executors on the fixed source page,
-- and create matching MIDI remotes if they are missing.
-- You will need to update the Midi CC notes in of the midi remotes to match your midi controller

local loop

-- Tuneables -----------------------------------------------------------
--
-- Each entry in Wings is one physical MIDI fader controller:
--   name            - short label used in remote names and debug prints
--   midiChannel     - the MIDI channel this wing's controller sends on
--   ccStart         - the first MIDI CC number for lane 1 on this wing
--                     (lane N uses ccStart + N - 1)
--   sourceExecStart - first hidden "dummy" executor number for this wing,
--                     on the shared PickupSourcePage. Must not overlap
--                     the sourceExecStart..sourceExecStart+maxLaneCount-1
--                     range of any other wing.
--   targetExecStart - first real executor number this wing controls, on
--                     whatever page is currently showing. Must not
--                     overlap the target range of any other wing.
--   laneCount       - number of faders on this wing actually being used
--   maxLaneCount    - headroom for laneCount to grow later without
--                     colliding with the next wing's numbers
--   sequenceEnd     - last pickup-sequence number reserved for this wing
--                     (sequences count down from here). Must not overlap
--                     the sequence range of any other wing.
local Wings = {
    {
        name = "Wing1",
        midiChannel = 1,
        ccStart = 1,
        sourceExecStart = 231,
        targetExecStart = 201,
        laneCount = 10,
        maxLaneCount = 15,
        sequenceEnd = 9999,
    },
    {
        name = "Wing2",
        midiChannel = 2,
        ccStart = 1,
        sourceExecStart = 261,
        targetExecStart = 216,
        laneCount = 10,
        maxLaneCount = 15,
        sequenceEnd = 9969,
    },
}

local PollRateSeconds = 0.1 -- Polling rate in seconds for checking source and target executor values

local ScriptVersion = "0.4.0"
local PickupTolerance = 1.0
local ExternalDirtyThreshold = 1
local PickupSourcePage = 9999
local PickupRemoteNamePrefix = "midi_faders_pickup_"
local PickupGateRemoteNamePrefix = "midi_faders_gate_"

local running = false
local debugMode = false
local currentPage = nil

local lanes = {}

local function DebugPrint(...)
    if debugMode then
        Printf(...)
    end
end

local function sourceExecEnd(wing)
    return wing.sourceExecStart + wing.laneCount - 1
end

local function sourceExecFloor(wing)
    return wing.sourceExecStart + wing.maxLaneCount - 1
end

local function targetExecEnd(wing)
    return wing.targetExecStart + wing.laneCount - 1
end

local function targetExecFloor(wing)
    return wing.targetExecStart + wing.maxLaneCount - 1
end

local function pickupSequenceStart(wing)
    return wing.sequenceEnd - wing.laneCount + 1
end

local function pickupSequenceFloor(wing)
    return wing.sequenceEnd - wing.maxLaneCount + 1
end

local function clearLaneState(lane)
    lane.latched = false
    lane.lastSourceValue = nil
    lane.lastTargetValue = nil
    lane.targetSignature = nil
    lane.lastPage = nil
    lane.lastDebugState = nil
end

local function safeObjectAddr(object)
    if object == nil then
        return nil
    end

    local ok, addr = pcall(function()
        return object:ToAddr()
    end)
    if ok then
        return addr
    end

    return tostring(object)
end

local function sameObject(left, right)
    if left == right then
        return true
    end

    local leftAddr = safeObjectAddr(left)
    local rightAddr = safeObjectAddr(right)
    return leftAddr ~= nil and leftAddr == rightAddr
end

local function resolveCurrentPageNo()
    local pageHandle = CurrentExecPage()
    if pageHandle and pageHandle.no then
        return pageHandle.no
    end

    return currentPage or 1
end

local function getFocusDisplayIndex()
    local focusDisplay = GetFocusDisplay()
    if focusDisplay and focusDisplay.index then
        return focusDisplay.index
    end
    return 1
end

local function getSequenceObject(seqNo)
    return ObjectList("Sequence " .. tostring(seqNo))[1]
end

local function getPageObject(pageNo)
    return ObjectList("Page " .. tostring(pageNo))[1]
end

local function getExecutorSlot(pageNo, execNo)
    return ObjectList("Page " .. tostring(pageNo) .. "." .. tostring(execNo))[1]
end

local function pageExists(pageNo)
    return getPageObject(pageNo) ~= nil
end

local function sequenceExists(seqNo)
    return getSequenceObject(seqNo) ~= nil
end

local function executorHasPickupSequence(pageNo, execNo, seqNo)
    local slot = getExecutorSlot(pageNo, execNo)
    if not slot or not slot.Object then
        return false
    end

    local sequenceObject = getSequenceObject(seqNo)
    if not sequenceObject then
        return false
    end

    return sameObject(slot.Object, sequenceObject)
end

local function executorPickupAssignmentMissing(pageNo, execNo)
    local slot = getExecutorSlot(pageNo, execNo)
    return slot == nil or slot.Object == nil
end

local function getMidiRemotePool()
    local showData = Root() and Root().ShowData or nil
    local remotes = showData and showData.Remotes or nil
    return remotes and remotes.MIDIRemotes or nil
end

local function findMidiRemoteByName(name)
    local midiPool = getMidiRemotePool()
    if not midiPool then
        return nil
    end

    for _, remote in pairs(midiPool:Children()) do
        if remote.name == name then
            return remote
        end
    end

    return nil
end

local function midiRemoteExists(name)
    return findMidiRemoteByName(name) ~= nil
end

local function deleteMidiRemote(remote)
    if remote == nil then
        return false
    end

    local ok, err = pcall(function()
        local parent = remote:Parent()
        if not parent then
            error("missing parent")
        end

        local childPosition = nil
        for position, child in ipairs(parent:Children()) do
            if child == remote or (child and remote.index ~= nil and child.index == remote.index) then
                childPosition = position
                break
            end
        end

        if childPosition == nil then
            error("could not locate MIDI remote in parent pool")
        end

        parent:Remove(childPosition)
    end)

    if not ok then
        Printf("[Pickup] failed to delete MIDI remote %s", tostring(remote.name or "unknown"))
        if err then
            Printf("[Pickup] %s", tostring(err))
        end
        return false
    end

    return true
end

local function runCmd(command)
    DebugPrint("[Pickup] cmd: %s", command)
    local ok, err = pcall(function()
        Cmd(command)
    end)
    if not ok then
        Printf("[Pickup] command failed: %s", command)
        if err then
            Printf("[Pickup] %s", tostring(err))
        end
        return false
    end
    return true
end

local function setRemoteProperty(remote, propName, value, isString)
    local addr = safeObjectAddr(remote)
    if not addr then
        return false
    end

    local encoded = isString and ('"' .. tostring(value) .. '"') or tostring(value)
    return runCmd('Set ' .. addr .. ' Property "' .. propName .. '" ' .. encoded)
end

local function pickupSequenceRangeText(wing)
    return string.format("%d-%d", pickupSequenceStart(wing), wing.sequenceEnd)
end

local function pickupSequenceManagedRangeText(wing)
    return string.format("%d-%d", pickupSequenceFloor(wing), wing.sequenceEnd)
end

local function sourceExecRangeText(wing)
    return string.format("%d-%d", wing.sourceExecStart, sourceExecEnd(wing))
end

local function targetExecRangeText(wing)
    return string.format("%d-%d", wing.targetExecStart, targetExecEnd(wing))
end

local function pickupSequenceName(wing, targetExecNo)
    return string.format("Midi Pickup %s to %d", wing.name, targetExecNo)
end

local function pickupRemoteName(wing, laneIndex)
    return PickupRemoteNamePrefix .. wing.name .. "_" .. tostring(laneIndex)
end

local function pickupGateRemoteName(wing, laneIndex)
    return PickupGateRemoteNamePrefix .. wing.name .. "_" .. tostring(laneIndex)
end

local function rangesOverlap(startA, endA, startB, endB)
    return startA <= endB and startB <= endA
end

local function validateConfiguration()
    if #Wings < 1 then
        return false, "At least one wing must be configured."
    end

    for _, wing in ipairs(Wings) do
        if wing.laneCount < 1 then
            return false, string.format("%s: laneCount must be at least 1.", wing.name)
        end

        if wing.laneCount > wing.maxLaneCount then
            return false, string.format(
                "%s: laneCount %d is too large. grandMA3 only shows up to %d faders on screen for this setup.",
                wing.name,
                wing.laneCount,
                wing.maxLaneCount
            )
        end

        if pickupSequenceStart(wing) < 1 then
            return false, string.format(
                "%s: laneCount %d is too large for ending sequence %d. Computed start would be %d.",
                wing.name,
                wing.laneCount,
                wing.sequenceEnd,
                pickupSequenceStart(wing)
            )
        end
    end

    for i = 1, #Wings do
        for j = i + 1, #Wings do
            local a = Wings[i]
            local b = Wings[j]

            if rangesOverlap(a.sourceExecStart, sourceExecFloor(a), b.sourceExecStart, sourceExecFloor(b)) then
                return false, string.format(
                    "%s and %s have overlapping source executor ranges on Page %d (%s vs %s).",
                    a.name, b.name, PickupSourcePage,
                    string.format("%d-%d", a.sourceExecStart, sourceExecFloor(a)),
                    string.format("%d-%d", b.sourceExecStart, sourceExecFloor(b))
                )
            end

            if rangesOverlap(a.targetExecStart, targetExecFloor(a), b.targetExecStart, targetExecFloor(b)) then
                return false, string.format(
                    "%s and %s have overlapping target executor ranges (%s vs %s).",
                    a.name, b.name,
                    string.format("%d-%d", a.targetExecStart, targetExecFloor(a)),
                    string.format("%d-%d", b.targetExecStart, targetExecFloor(b))
                )
            end

            if rangesOverlap(pickupSequenceFloor(a), a.sequenceEnd, pickupSequenceFloor(b), b.sequenceEnd) then
                return false, string.format(
                    "%s and %s have overlapping pickup sequence ranges (%s vs %s).",
                    a.name, b.name,
                    string.format("%d-%d", pickupSequenceFloor(a), a.sequenceEnd),
                    string.format("%d-%d", pickupSequenceFloor(b), b.sequenceEnd)
                )
            end

            if a.midiChannel == b.midiChannel and
               rangesOverlap(a.ccStart, a.ccStart + a.maxLaneCount - 1, b.ccStart, b.ccStart + b.maxLaneCount - 1) then
                return false, string.format(
                    "%s and %s share MIDI channel %d with overlapping CC ranges.",
                    a.name, b.name, a.midiChannel
                )
            end
        end
    end

    return true, nil
end

local function showConfigurationError(message)
    MessageBox({
        title = "MA3 MIDI Pickup",
        message = message,
        display = getFocusDisplayIndex(),
        commands = {
            {value = 1, name = "OK"},
        },
    })
end

local function createPickupSourcePage()
    if not pageExists(PickupSourcePage) then
        runCmd(string.format("Store Page %d /nc", PickupSourcePage))
    end
end

local function configureNewPickupSequence(wing, seqNo, targetExecNo)
    runCmd(string.format('Set Sequence %d Property "NAME" "%s"', seqNo, pickupSequenceName(wing, targetExecNo)))
    runCmd(string.format('Set Sequence %d Property "AUTOSTART" "No"', seqNo))
end

local function getObjectProperty(object, propName)
    if object == nil then
        return nil
    end

    local ok, value = pcall(function()
        return object[propName]
    end)
    if ok then
        return value
    end

    return nil
end

local function normalizePropertyString(value)
    local text = tostring(value or "")
    text = text:gsub('^%s*"', ""):gsub('"%s*$', "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function createMissingPickupSequencesForWing(wing)
    for laneIndex = 1, wing.laneCount do
        local seqNo = pickupSequenceStart(wing) + laneIndex - 1
        local targetExecNo = wing.targetExecStart + laneIndex - 1
        if not sequenceExists(seqNo) then
            runCmd(string.format("Store Sequence %d /nc", seqNo))
            configureNewPickupSequence(wing, seqNo, targetExecNo)
        end
    end
end

local function rebuildPickupSequencesForWing(wing)
    for seqNo = pickupSequenceFloor(wing), wing.sequenceEnd do
        if sequenceExists(seqNo) then
            runCmd(string.format("Delete Sequence %d /nc", seqNo))
        end
    end

    for laneIndex = 1, wing.laneCount do
        local seqNo = pickupSequenceStart(wing) + laneIndex - 1
        local targetExecNo = wing.targetExecStart + laneIndex - 1
        runCmd(string.format("Store Sequence %d /nc", seqNo))
        configureNewPickupSequence(wing, seqNo, targetExecNo)
    end
end

local function describeObject(object)
    if object == nil then
        return "nothing"
    end

    local ok, description = pcall(function()
        return tostring(object)
    end)
    if ok and description then
        return description
    end

    return "unknown object"
end

local function getPickupSetupReport()
    local report = {
        missingPage = not pageExists(PickupSourcePage),
        wings = {},
    }

    for _, wing in ipairs(Wings) do
        local wingReport = {
            wing = wing,
            missingSequences = {},
            misconfiguredSequences = {},
            staleSequences = {},
            assignmentIssues = {},
            missingRemotes = {},
            staleRemotes = {},
            missingGateRemotes = {},
            staleGateRemotes = {},
            sequenceRebuildRequired = false,
        }

        for laneIndex = 1, wing.laneCount do
            local seqNo = pickupSequenceStart(wing) + laneIndex - 1
            local targetExecNo = wing.targetExecStart + laneIndex - 1
            local execNo = wing.sourceExecStart + laneIndex - 1
            local remoteName = pickupRemoteName(wing, laneIndex)
            local sequenceObject = getSequenceObject(seqNo)
            local slot = getExecutorSlot(PickupSourcePage, execNo)

            if not sequenceObject then
                table.insert(wingReport.missingSequences, seqNo)
            else
                local expectedName = pickupSequenceName(wing, targetExecNo)
                local currentName = normalizePropertyString(getObjectProperty(sequenceObject, "NAME"))
                local normalizedExpectedName = normalizePropertyString(expectedName)

                if currentName ~= normalizedExpectedName then
                    table.insert(wingReport.misconfiguredSequences, {
                        seqNo = seqNo,
                        currentName = currentName,
                        expectedName = normalizedExpectedName,
                        nameWrong = currentName ~= normalizedExpectedName,
                    })
                end
            end

            if slot == nil or slot.Object == nil then
                table.insert(wingReport.assignmentIssues, {
                    execNo = execNo,
                    seqNo = seqNo,
                    kind = "missing",
                })
            elseif sequenceObject == nil or not sameObject(slot.Object, sequenceObject) then
                table.insert(wingReport.assignmentIssues, {
                    execNo = execNo,
                    seqNo = seqNo,
                    kind = "wrong",
                    current = describeObject(slot.Object),
                })
            end

            if not midiRemoteExists(remoteName) then
                table.insert(wingReport.missingRemotes, remoteName)
            end

            local gateRemoteName = pickupGateRemoteName(wing, laneIndex)
            if not midiRemoteExists(gateRemoteName) then
                table.insert(wingReport.missingGateRemotes, gateRemoteName)
            end
        end

        for laneIndex = wing.laneCount + 1, wing.maxLaneCount do
            local remoteName = pickupRemoteName(wing, laneIndex)
            if midiRemoteExists(remoteName) then
                table.insert(wingReport.staleRemotes, remoteName)
            end

            local gateRemoteName = pickupGateRemoteName(wing, laneIndex)
            if midiRemoteExists(gateRemoteName) then
                table.insert(wingReport.staleGateRemotes, gateRemoteName)
            end
        end

        for seqNo = pickupSequenceFloor(wing), pickupSequenceStart(wing) - 1 do
            if sequenceExists(seqNo) then
                table.insert(wingReport.staleSequences, seqNo)
            end
        end

        wingReport.sequenceRebuildRequired = #wingReport.missingSequences > 0 or
                                             #wingReport.misconfiguredSequences > 0 or
                                             #wingReport.staleSequences > 0

        report.wings[wing.name] = wingReport
    end

    return report
end

local function pickupSetupNeedsAttention(report)
    if report.missingPage then
        return true
    end

    for _, wing in ipairs(Wings) do
        local wingReport = report.wings[wing.name]
        if #wingReport.missingSequences > 0 or
           #wingReport.misconfiguredSequences > 0 or
           #wingReport.staleSequences > 0 or
           #wingReport.assignmentIssues > 0 or
           #wingReport.missingRemotes > 0 or
           #wingReport.staleRemotes > 0 or
           #wingReport.missingGateRemotes > 0 or
           #wingReport.staleGateRemotes > 0 then
            return true
        end
    end

    return false
end

local function buildPickupSetupWarningMessage(report)
    local lines = {
        "Pickup setup is missing or wrong:",
    }

    if report.missingPage then
        table.insert(lines, string.format("- Page %d is missing", PickupSourcePage))
    end

    for _, wing in ipairs(Wings) do
        local wingReport = report.wings[wing.name]

        for _, seqNo in ipairs(wingReport.missingSequences) do
            table.insert(lines, string.format("- [%s] Sequence %d is missing", wing.name, seqNo))
        end

        for _, issue in ipairs(wingReport.misconfiguredSequences) do
            if issue.nameWrong then
                table.insert(
                    lines,
                    string.format('- [%s] Sequence %d name is "%s"; expected "%s"',
                                  wing.name,
                                  issue.seqNo,
                                  issue.currentName,
                                  issue.expectedName)
                )
            end
        end

        for _, seqNo in ipairs(wingReport.staleSequences) do
            table.insert(lines, string.format("- [%s] Sequence %d is outside the current lane count and will be removed", wing.name, seqNo))
        end

        for _, issue in ipairs(wingReport.assignmentIssues) do
            if issue.kind == "missing" then
                table.insert(
                    lines,
                    string.format("- [%s] Page %d.%d is empty; expected Sequence %d",
                                  wing.name,
                                  PickupSourcePage,
                                  issue.execNo,
                                  issue.seqNo)
                )
            else
                table.insert(
                    lines,
                    string.format("- [%s] Page %d.%d is assigned to %s; expected Sequence %d",
                                  wing.name,
                                  PickupSourcePage,
                                  issue.execNo,
                                  issue.current,
                                  issue.seqNo)
                )
            end
        end

        for _, remoteName in ipairs(wingReport.missingRemotes) do
            table.insert(lines, string.format("- MIDI remote %s is missing", remoteName))
        end

        for _, remoteName in ipairs(wingReport.staleRemotes) do
            table.insert(lines, string.format("- MIDI remote %s is outside the current lane count and will be removed", remoteName))
        end

        for _, remoteName in ipairs(wingReport.missingGateRemotes) do
            table.insert(lines, string.format("- MIDI gate remote %s is missing", remoteName))
        end

        for _, remoteName in ipairs(wingReport.staleGateRemotes) do
            table.insert(lines, string.format("- MIDI gate remote %s is outside the current lane count and will be removed", remoteName))
        end

        if wingReport.sequenceRebuildRequired then
            table.insert(lines, "")
            table.insert(lines, string.format("- [%s] Pickup sequences in %s will be deleted, then %s will be recreated to match the current lane configuration",
                                              wing.name,
                                              pickupSequenceManagedRangeText(wing),
                                              pickupSequenceRangeText(wing)))
        end
    end

    table.insert(lines, "")
    local rangeSummaries = {}
    for _, wing in ipairs(Wings) do
        table.insert(rangeSummaries, string.format("%s: %s", wing.name, sourceExecRangeText(wing)))
    end
    table.insert(
        lines,
        string.format("Do you want to create missing items and replace wrong Page %d executor assignments for source executors (%s)?",
                      PickupSourcePage,
                      table.concat(rangeSummaries, ", "))
    )
    return table.concat(lines, "\n")
end

local function repairPickupExecutorAssignments(assignmentIssues)
    for _, issue in ipairs(assignmentIssues) do
        runCmd(string.format("Assign Sequence %d At Page %d.%d /nc",
                             issue.seqNo,
                             PickupSourcePage,
                             issue.execNo))
    end
end

local function repairAllPickupExecutorAssignmentsForWing(wing)
    for laneIndex = 1, wing.laneCount do
        local seqNo = pickupSequenceStart(wing) + laneIndex - 1
        local execNo = wing.sourceExecStart + laneIndex - 1
        runCmd(string.format("Assign Sequence %d At Page %d.%d /nc",
                             seqNo,
                             PickupSourcePage,
                             execNo))
    end
end

local function createRemoteBoundToSource(midiPool, wing, remoteName, laneIndex)
    local remote = midiPool:Append()
    if not remote then
        return nil
    end

    local execNo = wing.sourceExecStart + laneIndex - 1
    local slot = getExecutorSlot(PickupSourcePage, execNo)

    setRemoteProperty(remote, "Name", remoteName, true)
    setRemoteProperty(remote, "MIDICHANNEL", wing.midiChannel, false)
    setRemoteProperty(remote, "MIDITYPE", 3, false)
    setRemoteProperty(remote, "MIDIINDEX", wing.ccStart + laneIndex - 1, false)
    setRemoteProperty(remote, "KEY", "", true)
    if slot and slot.Object then
        remote.target = slot.Object
    end
    if slot and slot.fader then
        remote.fader = slot.fader
    else
        setRemoteProperty(remote, "FADER", "Master", true)
    end

    return remote
end

local function createMissingPickupMidiRemotesForWing(wing, missingRemotes)
    local missingLookup = {}
    for _, remoteName in ipairs(missingRemotes) do
        missingLookup[remoteName] = true
    end

    local midiPool = getMidiRemotePool()
    if not midiPool then
        Printf("[Pickup] MIDI remote pool unavailable")
        return
    end

    for laneIndex = 1, wing.laneCount do
        local remoteName = pickupRemoteName(wing, laneIndex)
        if missingLookup[remoteName] then
            createRemoteBoundToSource(midiPool, wing, remoteName, laneIndex)
        end
    end
end

local function createMissingPickupGateRemotesForWing(wing, missingGateRemotes)
    local missingLookup = {}
    for _, remoteName in ipairs(missingGateRemotes) do
        missingLookup[remoteName] = true
    end

    local midiPool = getMidiRemotePool()
    if not midiPool then
        Printf("[Pickup] MIDI remote pool unavailable")
        return
    end

    -- Gate remotes share the same MIDI channel/index as the matching shadow
    -- remote above, but their target gets redirected by the poll loop:
    -- pointed at the dummy source object (blocked / no-op) while a lane is
    -- unlatched, and re-pointed at the real target executor once the lane
    -- picks up, so the physical fader drives the target directly over MIDI
    -- instead of via a Lua-issued fader command.
    for laneIndex = 1, wing.laneCount do
        local remoteName = pickupGateRemoteName(wing, laneIndex)
        if missingLookup[remoteName] then
            createRemoteBoundToSource(midiPool, wing, remoteName, laneIndex)
        end
    end
end

local function deleteStalePickupMidiRemotes(staleRemotes)
    for _, remoteName in ipairs(staleRemotes) do
        local remote = findMidiRemoteByName(remoteName)
        if remote then
            deleteMidiRemote(remote)
        end
    end
end

local function deleteStalePickupGateRemotes(staleGateRemotes)
    for _, remoteName in ipairs(staleGateRemotes) do
        local remote = findMidiRemoteByName(remoteName)
        if remote then
            deleteMidiRemote(remote)
        end
    end
end

local function remapPickupMidiRemotesForWing(wing)
    for laneIndex = 1, wing.laneCount do
        local remoteName = pickupRemoteName(wing, laneIndex)
        local remote = findMidiRemoteByName(remoteName)
        local gateRemoteName = pickupGateRemoteName(wing, laneIndex)
        local gateRemote = findMidiRemoteByName(gateRemoteName)
        local execNo = wing.sourceExecStart + laneIndex - 1
        local slot = getExecutorSlot(PickupSourcePage, execNo)

        if remote and slot and slot.Object then
            if not sameObject(remote.target, slot.Object) then
                remote.target = slot.Object
            end
            if slot.fader and remote.fader ~= slot.fader then
                remote.fader = slot.fader
            end
        end

        -- Every lane starts unlatched, so the gate remote always starts
        -- blocked (pointed at the dummy source object) here. The poll loop
        -- is responsible for pointing it at the real target once a lane
        -- picks up.
        if gateRemote and slot and slot.Object then
            if not sameObject(gateRemote.target, slot.Object) then
                gateRemote.target = slot.Object
            end
            if slot.fader and gateRemote.fader ~= slot.fader then
                gateRemote.fader = slot.fader
            end
        end
    end
end

local function remapPickupMidiRemotes()
    for _, wing in ipairs(Wings) do
        remapPickupMidiRemotesForWing(wing)
    end
end

local function promptRepairPickupSetup(report)
    local result = MessageBox({
        title = "Create Missing or Incorrect Items?",
        message = buildPickupSetupWarningMessage(report),
        display = getFocusDisplayIndex(),
        commands = {
            {value = 1, name = "Yes"},
            {value = 0, name = "No"},
        },
    })

    return type(result) == "table" and result.success == true and result.result == 1
end

local function showPickupSetupReminder()
    local lines = {}
    for _, wing in ipairs(Wings) do
        table.insert(lines, string.format("%s: source executors %s (channel %d, CC %d+)",
                                          wing.name,
                                          sourceExecRangeText(wing),
                                          wing.midiChannel,
                                          wing.ccStart))
    end

    MessageBox({
        title = "MA3 MIDI Pickup",
        message = "Make sure to assign the correct Midi CCs to the created midi remotes:\n" .. table.concat(lines, "\n"),
        display = getFocusDisplayIndex(),
        commands = {
            {value = 1, name = "OK"},
        },
    })
end

local function ensurePickupSetup()
    local report = getPickupSetupReport()
    if not pickupSetupNeedsAttention(report) then
        return true
    end

    if not promptRepairPickupSetup(report) then
        return false
    end

    if report.missingPage then
        createPickupSourcePage()
    end

    for _, wing in ipairs(Wings) do
        local wingReport = report.wings[wing.name]

        if wingReport.sequenceRebuildRequired then
            rebuildPickupSequencesForWing(wing)
            repairAllPickupExecutorAssignmentsForWing(wing)
        elseif #wingReport.assignmentIssues > 0 then
            repairPickupExecutorAssignments(wingReport.assignmentIssues)
        end
        if #wingReport.staleRemotes > 0 then
            deleteStalePickupMidiRemotes(wingReport.staleRemotes)
        end
        if #wingReport.missingRemotes > 0 then
            createMissingPickupMidiRemotesForWing(wing, wingReport.missingRemotes)
        end
        if #wingReport.staleGateRemotes > 0 then
            deleteStalePickupGateRemotes(wingReport.staleGateRemotes)
        end
        if #wingReport.missingGateRemotes > 0 then
            createMissingPickupGateRemotesForWing(wing, wingReport.missingGateRemotes)
        end
    end

    showPickupSetupReminder()
    return true
end

local function getExecutorInfo(execId, pageOverride)
    local resolvedPage = pageOverride or currentPage or (CurrentExecPage() and CurrentExecPage().no) or 1
    local objectListExec = ObjectList("Page " .. tostring(resolvedPage) .. "." .. tostring(execId))[1]
    local handle = nil
    if pageOverride == nil then
        handle = select(1, GetExecutor(execId))
    end
    local executorRef = handle or objectListExec

    local faderValue = 0
    if executorRef then
        local ok, result = pcall(function()
            return executorRef:GetFader{token = "FaderMaster", faderDisabled = false} or 0
        end)
        if ok and result ~= nil then
            faderValue = result
        end
    end

    local object = nil
    if handle and handle.Object then
        object = handle.Object
    elseif objectListExec and objectListExec.Object then
        object = objectListExec.Object
    end
    local faderRef = objectListExec and objectListExec.fader or nil

    return {
        id = execId,
        page = resolvedPage,
        handle = executorRef,
        object = object,
        slot = objectListExec,
        faderRef = faderRef,
        isPopulated = object ~= nil or objectListExec ~= nil,
        faderValue = faderValue
    }
end

local function buildTargetSignature(execInfo, page)
    return table.concat({
        tostring(page or 0),
        tostring(execInfo.id or 0),
        tostring(execInfo.isPopulated and 1 or 0),
        tostring(execInfo.object or "nil"),
        tostring(execInfo.faderRef or "nil")
    }, "|")
end

local function shouldLatchPickup(previousValue, currentValue, targetValue)
    if math.abs(currentValue - targetValue) <= PickupTolerance then
        return true
    end

    if previousValue == nil then
        return false
    end

    local previousDelta = previousValue - targetValue
    local currentDelta = currentValue - targetValue

    if math.abs(previousDelta) <= PickupTolerance or math.abs(currentDelta) <= PickupTolerance then
        return true
    end

    return (previousDelta < 0 and currentDelta > 0) or
           (previousDelta > 0 and currentDelta < 0)
end

local function getGateRemote(lane)
    return findMidiRemoteByName(pickupGateRemoteName(lane.wing, lane.laneIndex))
end

-- Points a lane's gate remote at a given object/fader. This is the only
-- thing that ever changes which executor the physical MIDI fader drives:
-- no Lua code ever calls SetFader or Cmd on the target executor. When the
-- gate remote's target is the dummy source object, the physical fader is
-- effectively blocked from the real target (it just keeps moving the dummy
-- it was already moving anyway). When the gate remote's target is the real
-- target executor, MIDI drives it directly.
local function pointGateRemoteAt(lane, object, faderRef)
    local remote = getGateRemote(lane)
    if not remote or not object then
        return false
    end

    local ok = pcall(function()
        if not sameObject(remote.target, object) then
            remote.target = object
        end
        if faderRef then
            if remote.fader ~= faderRef then
                remote.fader = faderRef
            end
        else
            setRemoteProperty(remote, "FADER", "Master", true)
        end
    end)

    if not ok then
        Printf("[Pickup] %s Lane %d failed to repoint gate remote", lane.wing.name, lane.laneIndex)
    end

    return ok
end

local function blockGateRemote(lane, sourceInfo)
    if not sourceInfo or not sourceInfo.object then
        return false
    end
    return pointGateRemoteAt(lane, sourceInfo.object, sourceInfo.faderRef)
end

local function unblockGateRemote(lane, targetInfo)
    if not targetInfo or not targetInfo.object then
        return false
    end
    return pointGateRemoteAt(lane, targetInfo.object, targetInfo.faderRef)
end

local function shouldDirtyPickup(lane, sourceValue, targetValue)
    if not lane.latched then
        return false
    end

    -- While latched the gate remote drives the target directly from the
    -- same MIDI CC the source/dummy executor tracks, so the two should stay
    -- in lockstep. If they drift apart it means something other than the
    -- picked-up fader moved the target (on-screen drag, another remote,
    -- an effect, etc.), so the lane should drop back into pickup mode.
    return math.abs(targetValue - sourceValue) > ExternalDirtyThreshold
end

local function initializeLanes()
    lanes = {}
    for _, wing in ipairs(Wings) do
        for laneIndex = 1, wing.laneCount do
            local lane = {
                wing = wing,
                laneIndex = laneIndex,
                sourceExec = wing.sourceExecStart + laneIndex - 1,
                targetExec = wing.targetExecStart + laneIndex - 1,
            }
            clearLaneState(lane)
            table.insert(lanes, lane)
        end
    end

    for _, lane in ipairs(lanes) do
        local sourceInfo = getExecutorInfo(lane.sourceExec, PickupSourcePage)
        blockGateRemote(lane, sourceInfo)
    end
end

local function resetPickupState(reason)
    for _, lane in ipairs(lanes) do
        clearLaneState(lane)
        local sourceInfo = getExecutorInfo(lane.sourceExec, PickupSourcePage)
        blockGateRemote(lane, sourceInfo)
    end
    DebugPrint("[Pickup] reset all lanes (%s)", reason or "manual")
end

local function describeLane(lane)
    return string.format("%s Lane %d (src %d -> tgt %d)",
                         lane.wing.name,
                         lane.laneIndex,
                         lane.sourceExec,
                         lane.targetExec)
end

local function updateLaneDebugState(lane, stateKey, message, ...)
    if lane.lastDebugState == stateKey then
        return
    end
    lane.lastDebugState = stateKey
    DebugPrint(message, ...)
end

local function serviceLane(lane, page)
    local sourceInfo = getExecutorInfo(lane.sourceExec, PickupSourcePage)
    local targetInfo = getExecutorInfo(lane.targetExec, page)
    local sourceValue = sourceInfo.faderValue or 0
    local targetValue = targetInfo.faderValue or 0
    local targetSignature = buildTargetSignature(targetInfo, page)

    if lane.lastPage ~= page or lane.targetSignature ~= targetSignature then
        lane.latched = false
        lane.targetSignature = targetSignature
        lane.lastPage = page
        lane.lastDebugState = nil
        blockGateRemote(lane, sourceInfo)
        DebugPrint("[Pickup] %s relatched for page/assignment change", describeLane(lane))
    end

    if not sourceInfo.handle then
        updateLaneDebugState(lane,
                             "missing_source",
                             "[Pickup] %s missing source executor handle",
                             describeLane(lane))
        lane.lastSourceValue = sourceValue
        return
    end

    if not targetInfo.handle or not targetInfo.isPopulated then
        local stateKey = targetInfo.handle and "missing_target_object" or "missing_target_handle"
        local message = targetInfo.handle and
            "[Pickup] %s target executor has no assigned object" or
            "[Pickup] %s missing target executor handle"
        updateLaneDebugState(lane, stateKey, message, describeLane(lane))
        if lane.latched then
            blockGateRemote(lane, sourceInfo)
        end
        lane.latched = false
        lane.lastSourceValue = sourceValue
        lane.lastTargetValue = targetValue
        return
    end

    if shouldDirtyPickup(lane, sourceValue, targetValue) then
        DebugPrint("[Pickup] %s dirtied by external target move (src %.2f, tgt %.2f)",
                   describeLane(lane),
                   sourceValue,
                   targetValue)
        lane.latched = false
        lane.lastDebugState = nil
        blockGateRemote(lane, sourceInfo)
    end

    if not lane.latched and shouldLatchPickup(lane.lastSourceValue, sourceValue, targetValue) then
        lane.latched = true
        lane.lastDebugState = "latched"
        unblockGateRemote(lane, targetInfo)
        DebugPrint("[Pickup] %s latched at src %.2f / tgt %.2f -- gate remote now driving target directly",
                   describeLane(lane),
                   sourceValue,
                   targetValue)
    end

    if not lane.latched then
        local relation = "below"
        if sourceValue > targetValue then
            relation = "above"
        elseif math.abs(sourceValue - targetValue) <= PickupTolerance then
            relation = "near"
        end
        updateLaneDebugState(lane,
                             string.format("waiting_%s", relation),
                             "[Pickup] %s waiting for pickup: src %.2f is %s tgt %.2f",
                             describeLane(lane),
                             sourceValue,
                             relation,
                             targetValue)
    end

    lane.lastSourceValue = sourceValue
    lane.lastTargetValue = targetValue
end

local function servicePickup()
    local pageHandle = CurrentExecPage()
    local nextPage = pageHandle and pageHandle.no or nil
    if not nextPage then
        return
    end

    if currentPage ~= nextPage then
        currentPage = nextPage
        resetPickupState("page change")
        DebugPrint("[Pickup] now watching page %d", currentPage)
    end

    for _, lane in ipairs(lanes) do
        serviceLane(lane, currentPage)
    end
end

local function printStartupSummary()
    Printf("Starting -- MA3 MIDI Pickup v%s", ScriptVersion)
    Printf("Watching page %s", tostring(CurrentExecPage() and CurrentExecPage().no or "?"))
    for _, wing in ipairs(Wings) do
        Printf("%s: Source page %d executors %d-%d (channel %d, CC %d+) -> current page executors %d-%d",
               wing.name,
               PickupSourcePage,
               wing.sourceExecStart,
               sourceExecEnd(wing),
               wing.midiChannel,
               wing.ccStart,
               wing.targetExecStart,
               targetExecEnd(wing))
        Printf("%s: Pickup sequence range: %s", wing.name, pickupSequenceRangeText(wing))
    end
    Printf("Pickup tolerance: %s", string.format("%.2f", PickupTolerance))
    Printf("External dirty threshold: %s", string.format("%.2f", ExternalDirtyThreshold))
end

loop = function()
    while running do
        servicePickup()
        coroutine.yield(PollRateSeconds)
    end
end

function main()
    if running then
        running = false
        Printf("Stopping -- MA3 MIDI Pickup v%s", ScriptVersion)
        return
    end

    local configOk, configError = validateConfiguration()
    if not configOk then
        showConfigurationError(configError)
        return
    end

    if not ensurePickupSetup() then
        return
    end

    remapPickupMidiRemotes()
    initializeLanes()
    currentPage = nil
    running = true
    printStartupSummary()
    loop()
end

return main
