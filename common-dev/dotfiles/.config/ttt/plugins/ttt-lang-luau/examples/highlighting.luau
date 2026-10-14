--!strict

export type Result<T> = { value: T?, error: string? }
type Callback = (value: number, ...string) -> boolean
type State = "idle" | "running"
type Position = { x: number, y: number } & { name: string }

type Choice =
    | string
    | number

local function identity<T>(value: T): T
    return value
end

local total: number = 1_000 + 0xFF + 0b1010 + 1.5e2
local greeting = "hello\nworld"
local literal = 'single-quoted string'
local enabled = true
local missing = nil
local items = { 1, 2, 3 }

for index, value in items do
    if index == 2 then
        continue
    end
    total += value
end

total //= 2
local label = if total > 0 then "positive" else "zero"
local cast = total :: number
local message = `Total: {math.floor(total)}; label: {label}`
local nested = `Nested: {`Value: {total}`}`
local escaped = `Literal \{brace and \`backtick`
local tableInterpolation = `Table: {({ key = total }).key}`

local block = [==[
This is a multiline string.
A shorter closing delimiter ]] does not end it.
]==]

--[=[
This is a multiline comment.
A shorter closing delimiter ]] does not end it.
]=]

--- @param value A value to inspect.
print(message, label, cast, block, identity(total))

@native
local function square(value: number): number
    return value * value
end

export type function optional(ty)
    return types.unionof(ty, types.singleton(nil))
end

local specialized = identity<<number>>(total)
