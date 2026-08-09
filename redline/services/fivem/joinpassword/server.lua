-- FiveM has no server password convar. The closest thing is holding the
-- connection open with the deferral API and asking for one before letting the
-- player through, which is what every "password plugin" for FiveM does.
--
-- This is a soft gate: it keeps strangers out, but the secret is shared with
-- everyone who joins and is only ever checked server-side. It is not a
-- substitute for an identifier allowlist if you actually care.
--
-- The password comes from the `sandbox_join_password` convar, set with plain
-- `set` in server.cfg. It must never be `sets` — that would replicate it to
-- every connected client, which rather defeats the purpose.

local MAX_ATTEMPTS = 3

local function passwordCard(message)
    return {
        type = 'AdaptiveCard',
        version = '1.0',
        body = {
            {
                type = 'TextBlock',
                text = GetConvar('sv_projectName', 'This server'),
                size = 'Large',
                weight = 'Bolder',
            },
            {
                type = 'TextBlock',
                text = message,
                wrap = true,
            },
            {
                type = 'Input.Text',
                id = 'password',
                placeholder = 'Password',
                style = 'Password',
            },
        },
        actions = {
            {
                type = 'Action.Submit',
                title = 'Connect',
            },
        },
    }
end

AddEventHandler('playerConnecting', function(name, _, deferrals)
    local expected = GetConvar('sandbox_join_password', '')

    -- An unset password means an open server. Deliberate: locking everyone out
    -- because a secret went missing is a worse failure than not having one.
    if expected == '' then
        return
    end

    deferrals.defer()

    -- The deferral API requires a tick between defer() and anything else.
    Wait(0)

    local attempts = 0
    local settled = false

    local function ask(message)
        deferrals.presentCard(passwordCard(message), function(data)
            if settled then
                return
            end

            attempts = attempts + 1
            local given = (data and data.password) or ''

            if given == expected then
                settled = true
                deferrals.done()
                return
            end

            print(('[joinpassword] wrong password from %s (attempt %d/%d)'):format(name, attempts, MAX_ATTEMPTS))

            if attempts >= MAX_ATTEMPTS then
                settled = true
                deferrals.done('Too many incorrect password attempts.')
            else
                ask(('Incorrect password — %d attempt(s) left.'):format(MAX_ATTEMPTS - attempts))
            end
        end)
    end

    ask('This server requires a password.')
end)
