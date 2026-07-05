-- MA3 MIDI Pickup by Shawn R
-- Polls a fixed bank of source executors assigned to pickup sequences
-- and forwards them to a target executor range with pickup behavior.
-- only after the dummy control crosses the current target value.
--
-- v0.3.0 change: the target fader is no longer moved by Lua.
-- Every lane now has two MIDI remotes listening to the same physical
-- fader's MIDI CC:
--   1. Changed from Lua controlling fader to midi input. Using a new gate remote to compare and block midi till both pickup and gate are the same.
--
-- How to use
-- On startup the plugin can create the configured pickup sequences for pickup and gate midi remotes,
-- assign them to the configured source executors on the fixed source page,
-- and create matching MIDI remotes if they are missing.
-- You will need to update the Midi CC notes in of the midi remotes to match your midi controller

local loop

-- Tuneables
local LaneCount = 10 -- Number of faders to track
local MaxLaneCount = 15

local PollRateSeconds = 0.1 -- Polling rate in seconds for checking source and target executor values

local ScriptVersion = "0.3.0"
local PickupTolerance = 1.0
local ExternalDirtyThreshold = 1
local SourceExecStart = 231
local TargetExecStart = 201
local PickupSourcePage = 9999
local PickupSequenceEnd = 9999
local PickupRemoteNamePrefix = "midi_faders_pickup_"
local PickupGateRemoteNamePrefix = "midi_faders_gate_"
local PickupMidiChannel = 1
local PickupMidiCcStart = 1

local running = false
local debugMode = false
local currentPage = nil

local lanes = {}

local function DebugPrint(...)
    if debugMode then
        Printf(...)
    end
end

local function sourceExecEnd()
    return SourceExecStart + LaneCount - 1
end

local function targetExecEnd()
    return TargetExecStart + LaneCount - 1
end

local function pickupSequenceStart()
    return PickupSequenceEnd - LaneCount + 1
end

local function pickupSequenceFloor()
    return PickupSequenceEnd - MaxLaneCount + 1
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

local function pickupSequenceRangeText()
    return string.format("%d-%d", pickupSequenceStart(), PickupSequenceEnd)
end

local function pickupSequenceManagedRangeText()
    return string.format("%d-%d", pickupSequenceFloor(), PickupSequenceEnd)
end

local function sourceExecRangeText()
    return string.format("%d-%d", SourceExecStart, sourceExecEnd())
end

local function targetExecRangeText()
    return string.format("%d-%d", TargetExecStart, targetExecEnd())
end

local function pickupSequenceName(targetExecNo)
    return string.format("Midi Pickup to %d", targetExecNo)
end

local function pickupRemoteName(laneIndex)
    return PickupRemoteNamePrefix .. tostring(laneIndex)
end

local function pickupGateRemoteName(laneIndex)
    return PickupGateRemoteNamePrefix .. tostring(laneIndex)
end

local function validateConfiguration()
    if LaneCount < 1 then
        return false, "LaneCount must be at least 1."
    end

    if LaneCount > MaxLaneCount then
        return false, string.format("LaneCount %d is too large. grandMA3 only shows up to %d faders on screen for this setup.", LaneCount, MaxLaneCount)
    end

    if pickupSequenceStart() < 1 then
        return false, string.format("LaneCount %d is too large for ending sequence %d. Computed start would be %d.",
                                    LaneCount,
                                    PickupSequenceEnd,
                                    pickupSequenceStart())
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

local function configureNewPickupSequence(seqNo, targetExecNo)
    runCmd(string.format('Set Sequence %d Property "NAME" "%s"', seqNo, pickupSequenceName(targetExecNo)))
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

local function createMissingPickupSequences()
    for laneIndex = 1, LaneCount do
        local seqNo = pickupSequenceStart() + laneIndex - 1
        local targetExecNo = TargetExecStart + laneIndex - 1
        if not sequenceExists(seqNo) then
            runCmd(string.format("Store Sequence %d /nc", seqNo))
            configureNewPickupSequence(seqNo, targetExecNo)
        end
    end
end

local function rebuildPickupSequences()
    for seqNo = pickupSequenceFloor(), PickupSequenceEnd do
        if sequenceExists(seqNo) then
            runCmd(string.format("Delete Sequence %d /nc", seqNo))
        end
    end

    for laneIndex = 1, LaneCount do
        local seqNo = pickupSequenceStart() + laneIndex - 1
        local targetExecNo = TargetExecStart + laneIndex - 1
        runCmd(string.format("Store Sequence %d /nc", seqNo))
        configureNewPickupSequence(seqNo, targetExecNo)
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

    for laneIndex = 1, LaneCount do
        local seqNo = pickupSequenceStart() + laneIndex - 1
        local targetExecNo = TargetExecStart + laneIndex - 1
        local execNo = SourceExecStart + laneIndex - 1
        local remoteName = pickupRemoteName(laneIndex)
        local sequenceObject = getSequenceObject(seqNo)
        local slot = getExecutorSlot(PickupSourcePage, execNo)

        if not sequenceObject then
            table.insert(report.missingSequences, seqNo)
        else
            local expectedName = pickupSequenceName(targetExecNo)
            local currentName = normalizePropertyString(getObjectProperty(sequenceObject, "NAME"))
            local normalizedExpectedName = normalizePropertyString(expectedName)

            if currentName ~= normalizedExpectedName then
                table.insert(report.misconfiguredSequences, {
                    seqNo = seqNo,
                    currentName = currentName,
                    expectedName = normalizedExpectedName,
                    nameWrong = currentName ~= normalizedExpectedName,
                })
            end
        end

        if slot == nil or slot.Object == nil then
            table.insert(report.assignmentIssues, {
                execNo = execNo,
                seqNo = seqNo,
                kind = "missing",
            })
        elseif sequenceObject == nil or not sameObject(slot.Object, sequenceObject) then
            table.insert(report.assignmentIssues, {
                execNo = execNo,
                seqNo = seqNo,
                kind = "wrong",
                current = describeObject(slot.Object),
            })
        end

        if not midiRemoteExists(remoteName) then
            table.insert(report.missingRemotes, remoteName)
        end

        local gateRemoteName = pickupGateRemoteName(laneIndex)
        if not midiRemoteExists(gateRemoteName) then
            table.insert(report.missingGateRemotes, gateRemoteName)
        end
    end

    for laneIndex = LaneCount + 1, MaxLaneCount do
        local remoteName = pickupRemoteName(laneIndex)
        if midiRemoteExists(remoteName) then
            table.insert(report.staleRemotes, remoteName)
        end

        local gateRemoteName = pickupGateRemoteName(laneIndex)
        if midiRemoteExists(gateRemoteName) then
            table.insert(report.staleGateRemotes, gateRemoteName)
        end
    end

    for seqNo = pickupSequenceFloor(), pickupSequenceStart() - 1 do
        if sequenceExists(seqNo) then
            table.insert(report.staleSequences, seqNo)
        end
    end

    report.sequenceRebuildRequired = #report.missingSequences > 0 or
                                     #report.misconfiguredSequences > 0 or
                                     #report.staleSequences > 0

    return report
end

local function pickupSetupNeedsAttention(report)
    return report.missingPage or
           #report.missingSequences > 0 or
           #report.misconfiguredSequences > 0 or
           #report.staleSequences > 0 or
           #report.assignmentIssues > 0 or
           #report.missingRemotes > 0 or
           #report.staleRemotes > 0 or
           #report.missingGateRemotes > 0 or
           #report.staleGateRemotes > 0
end

local function buildPickupSetupWarningMessage(report)
    local lines = {
        "Pickup setup is missing or wrong:",
    }

    if report.missingPage then
        table.insert(lines, string.format("- Page %d is missing", PickupSourcePage))
    end

    for _, seqNo in ipairs(report.missingSequences) do
        table.insert(lines, string.format("- Sequence %d is missing", seqNo))
    end

    for _, issue in ipairs(report.misconfiguredSequences) do
        if issue.nameWrong then
            table.insert(
                lines,
                string.format('- Sequence %d name is "%s"; expected "%s"',
                              issue.seqNo,
                              issue.currentName,
                              issue.expectedName)
            )
        end
    end

    for _, seqNo in ipairs(report.staleSequences) do
        table.insert(lines, string.format("- Sequence %d is outside the current lane count and will be removed", seqNo))
    end

    for _, issue in ipairs(report.assignmentIssues) do
        if issue.kind == "missing" then
            table.insert(
                lines,
                string.format("- Page %d.%d is empty; expected Sequence %d",
                              PickupSourcePage,
                              issue.execNo,
                              issue.seqNo)
            )
        else
            table.insert(
                lines,
                string.format("- Page %d.%d is assigned to %s; expected Sequence %d",
                              PickupSourcePage,
                              issue.execNo,
                              issue.current,
                              issue.seqNo)
            )
        end
    end

    for _, remoteName in ipairs(report.missingRemotes) do
        table.insert(lines, string.format("- MIDI remote %s is missing", remoteName))
    end

    for _, remoteName in ipairs(report.staleRemotes) do
        table.insert(lines, string.format("- MIDI remote %s is outside the current lane count and will be removed", remoteName))
    end

    for _, remoteName in ipairs(report.missingGateRemotes) do
        table.insert(lines, string.format("- MIDI gate remote %s is missing", remoteName))
    end

    for _, remoteName in ipairs(report.staleGateRemotes) do
        table.insert(lines, string.format("- MIDI gate remote %s is outside the current lane count and will be removed", remoteName))
    end

    if report.sequenceRebuildRequired then
        table.insert(lines, "")
        table.insert(lines, string.format("- Pickup sequences in %s will be deleted, then %s will be recreated to match the current lane configuration",
                                          pickupSequenceManagedRangeText(),
                                          pickupSequenceRangeText()))
    end

    table.insert(lines, "")
    table.insert(
        lines,
        string.format("Do you want to create missing items and replace wrong Page %d executor assignments for source executors %s?",
                      PickupSourcePage,
                      sourceExecRangeText())
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

local function repairAllPickupExecutorAssignments()
    for laneIndex = 1, LaneCount do
        local seqNo = pickupSequenceStart() + laneIndex - 1
        local execNo = SourceExecStart + laneIndex - 1
        runCmd(string.format("Assign Sequence %d At Page %d.%d /nc",
                             seqNo,
                             PickupSourcePage,
                             execNo))
    end
end

local function createRemoteBoundToSource(midiPool, remoteName, laneIndex)
    local remote = midiPool:Append()
    if not remote then
        return nil
    end

    local execNo = SourceExecStart + laneIndex - 1
    local slot = getExecutorSlot(PickupSourcePage, execNo)

    setRemoteProperty(remote, "Name", remoteName, true)
    setRemoteProperty(remote, "MIDICHANNEL", PickupMidiChannel, false)
    setRemoteProperty(remote, "MIDITYPE", 3, false)
    setRemoteProperty(remote, "MIDIINDEX", PickupMidiCcStart + laneIndex - 1, false)
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

local function createMissingPickupMidiRemotes(missingRemotes)
    local missingLookup = {}
    for _, remoteName in ipairs(missingRemotes) do
        missingLookup[remoteName] = true
    end

    local midiPool = getMidiRemotePool()
    if not midiPool then
        Printf("[Pickup] MIDI remote pool unavailable")
        return
    end

    for laneIndex = 1, LaneCount do
        local remoteName = pickupRemoteName(laneIndex)
        if missingLookup[remoteName] then
            createRemoteBoundToSource(midiPool, remoteName, laneIndex)
        end
    end
end

local function createMissingPickupGateRemotes(missingGateRemotes)
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
    for laneIndex = 1, LaneCount do
        local remoteName = pickupGateRemoteName(laneIndex)
        if missingLookup[remoteName] then
            createRemoteBoundToSource(midiPool, remoteName, laneIndex)
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

local function remapPickupMidiRemotes()
    for laneIndex = 1, LaneCount do
        local remoteName = pickupRemoteName(laneIndex)
        local remote = findMidiRemoteByName(remoteName)
        local gateRemoteName = pickupGateRemoteName(laneIndex)
        local gateRemote = findMidiRemoteByName(gateRemoteName)
        local execNo = SourceExecStart + laneIndex - 1
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
    MessageBox({
        title = "MA3 MIDI Pickup",
        message = string.format("Make sure to assign the correct Midi CCs to the created midi remotes for source executors %s",
                                sourceExecRangeText()),
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
    if report.sequenceRebuildRequired then
        rebuildPickupSequences()
        repairAllPickupExecutorAssignments()
    elseif #report.assignmentIssues > 0 then
        repairPickupExecutorAssignments(report.assignmentIssues)
    end
    if #report.staleRemotes > 0 then
        deleteStalePickupMidiRemotes(report.staleRemotes)
    end
    if #report.missingRemotes > 0 then
        createMissingPickupMidiRemotes(report.missingRemotes)
    end
    if #report.staleGateRemotes > 0 then
        deleteStalePickupGateRemotes(report.staleGateRemotes)
    end
    if #report.missingGateRemotes > 0 then
        createMissingPickupGateRemotes(report.missingGateRemotes)
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
    return findMidiRemoteByName(pickupGateRemoteName(lane.laneIndex))
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
        Printf("[Pickup] Lane %d failed to repoint gate remote", lane.laneIndex)
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
    for laneIndex = 1, LaneCount do
        local lane = {
            laneIndex = laneIndex,
            sourceExec = SourceExecStart + laneIndex - 1,
            targetExec = TargetExecStart + laneIndex - 1,
        }
        clearLaneState(lane)
        lanes[laneIndex] = lane
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
    return string.format("Lane %d (src %d -> tgt %d)",
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
    Printf("Source page %d executors %d-%d -> current page executors %d-%d",
           PickupSourcePage,
           SourceExecStart,
           sourceExecEnd(),
           TargetExecStart,
           targetExecEnd())
    Printf("Pickup sequence range: %s", pickupSequenceRangeText())
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
