-- MA3 MIDI Pickup by Shawn R
-- Polls a fixed bank of source executors assigned to pickup sequences
-- and forwards them to a target executor range with pickup behavior.
-- only after the dummy control crosses the current target value.

-- How to use
-- On startup the plugin can create the configured pickup sequences,
-- assign them to the configured source executors on the fixed source page,
-- and create matching MIDI remotes if they are missing.
-- You will need to update the Midi CC notes in of the midi remotes to match your midi controller

local loop

-- Tuneables
local LaneCount = 10 -- Number of faders to track

local PollRateSeconds = 0.1 -- Polling rate in seconds for checking source and target executor values

local ScriptVersion = "0.2.0"
local PickupTolerance = 1.0
local ExternalDirtyThreshold = 1
local SourceExecStart = 231
local TargetExecStart = 201
local PickupSourcePage = 9999
local PickupSequenceEnd = 9999
local PickupRemoteNamePrefix = "midi_faders_pickup_"
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

local function clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

local function clearLaneState(lane)
    lane.latched = false
    lane.lastSourceValue = nil
    lane.lastTargetValue = nil
    lane.lastForwardedValue = nil
    lane.targetSignature = nil
    lane.lastPage = nil
    lane.lastDebugState = nil
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

local function sourceExecRangeText()
    return string.format("%d-%d", SourceExecStart, sourceExecEnd())
end

local function targetExecRangeText()
    return string.format("%d-%d", TargetExecStart, targetExecEnd())
end

local function validateConfiguration()
    if LaneCount < 1 then
        return false, "LaneCount must be at least 1."
    end

    if LaneCount > 15 then
        return false, string.format("LaneCount %d is too large. grandMA3 only shows up to 15 faders on screen for this setup.", LaneCount)
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

local function createMissingPickupSequences()
    for laneIndex = 1, LaneCount do
        local seqNo = pickupSequenceStart() + laneIndex - 1
        if not sequenceExists(seqNo) then
            runCmd(string.format("Store Sequence %d /nc", seqNo))
        end
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
        assignmentIssues = {},
        missingRemotes = {},
    }

    for laneIndex = 1, LaneCount do
        local seqNo = pickupSequenceStart() + laneIndex - 1
        local execNo = SourceExecStart + laneIndex - 1
        local remoteName = PickupRemoteNamePrefix .. tostring(laneIndex)
        local sequenceObject = getSequenceObject(seqNo)
        local slot = getExecutorSlot(PickupSourcePage, execNo)

        if not sequenceObject then
            table.insert(report.missingSequences, seqNo)
        end

        if slot == nil or slot.Object == nil then
            table.insert(report.assignmentIssues, {
                execNo = execNo,
                seqNo = seqNo,
                kind = "missing",
            })
        elseif sequenceObject ~= nil and not sameObject(slot.Object, sequenceObject) then
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
    end

    return report
end

local function pickupSetupNeedsAttention(report)
    return report.missingPage or
           #report.missingSequences > 0 or
           #report.assignmentIssues > 0 or
           #report.missingRemotes > 0
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
        local remoteName = PickupRemoteNamePrefix .. tostring(laneIndex)
        if missingLookup[remoteName] then
            local remote = midiPool:Append()
            if remote then
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
            end
        end
    end
end

local function remapPickupMidiRemotes()
    for laneIndex = 1, LaneCount do
        local remoteName = PickupRemoteNamePrefix .. tostring(laneIndex)
        local remote = findMidiRemoteByName(remoteName)
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
    end
end

local function promptRepairPickupSetup(report)
    local result = MessageBox({
        title = "MA3 MIDI Pickup",
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
    if #report.missingSequences > 0 then
        createMissingPickupSequences()
    end
    if #report.assignmentIssues > 0 then
        repairPickupExecutorAssignments(report.assignmentIssues)
    end
    if #report.missingRemotes > 0 then
        createMissingPickupMidiRemotes(report.missingRemotes)
    end

    showPickupSetupReminder()
    return true
end

local function resetPickupState(reason)
    for _, lane in ipairs(lanes) do
        clearLaneState(lane)
    end
    DebugPrint("[Pickup] reset all lanes (%s)", reason or "manual")
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

local function applyTargetFader(execInfo, value)
    local clampedValue = clamp(value, 0, 100)

    if execInfo.handle then
        local ok = pcall(function()
            execInfo.handle:SetFader{token = "FaderMaster", value = clampedValue, faderDisabled = false}
        end)
        if ok then
            return true
        end
    end

    local page = execInfo.page or currentPage or CurrentExecPage().no
    local command = string.format("FaderMaster Page %d.%d At %.3f", page, execInfo.id, clampedValue)
    local ok = pcall(function()
        Cmd(command)
    end)

    if not ok then
        Printf("[Pickup] failed to drive target exec %d", execInfo.id)
        return false
    end

    return true
end

local function shouldDirtyPickup(lane, targetValue)
    if not lane.latched or lane.lastForwardedValue == nil then
        return false
    end

    return math.abs(targetValue - lane.lastForwardedValue) > ExternalDirtyThreshold
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
        lane.lastForwardedValue = nil
        lane.targetSignature = targetSignature
        lane.lastPage = page
        lane.lastDebugState = nil
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
        lane.latched = false
        lane.lastSourceValue = sourceValue
        lane.lastTargetValue = targetValue
        return
    end

    if shouldDirtyPickup(lane, targetValue) then
        DebugPrint("[Pickup] %s dirtied by external target move (last %.2f, now %.2f)",
                   describeLane(lane),
                   lane.lastForwardedValue,
                   targetValue)
        lane.latched = false
        lane.lastForwardedValue = nil
        lane.lastDebugState = nil
    end

    if not lane.latched and shouldLatchPickup(lane.lastSourceValue, sourceValue, targetValue) then
        lane.latched = true
        lane.lastForwardedValue = nil
        lane.lastDebugState = "latched"
        DebugPrint("[Pickup] %s latched at src %.2f / tgt %.2f",
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

    if lane.latched then
        local shouldForward = lane.lastForwardedValue == nil or
                              math.abs(sourceValue - lane.lastForwardedValue) > 0.01
        if shouldForward and applyTargetFader(targetInfo, sourceValue) then
            lane.lastForwardedValue = sourceValue
        end
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
